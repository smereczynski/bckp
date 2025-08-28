import Foundation

// MARK: - BackupManager
// This class contains the main logic for creating and restoring backups.
// It uses FileManager (Apple's file API) to read/copy files on disk.

public final class BackupManager {
    // Default place where we create the backup repository if the user doesn't pass --repo.
    public static let defaultRepoURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Backups/bckp", isDirectory: true)
    }()

    private let fm = FileManager.default

    public init() {}

    // MARK: Repo
    // Create the repository folders and write a tiny JSON config so we know it's initialized.
    public func initRepo(at repoURL: URL = defaultRepoURL) throws {
        Logger.shared.info("initRepo at \(repoURL.path)", subsystem: "core.repo")
        if fm.fileExists(atPath: repoURL.path) {
            // If exists but missing config, treat as uninitialized
            let configURL = repoURL.appendingPathComponent("config.json")
            if fm.fileExists(atPath: configURL.path) { throw BackupError.repoAlreadyExists(repoURL) }
        }
        try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: repoURL.appendingPathComponent("snapshots", isDirectory: true), withIntermediateDirectories: true)
        let cfg = RepoConfig(version: 1, createdAt: Date())
        let data = try JSON.encoder.encode(cfg)
        try data.write(to: repoURL.appendingPathComponent("config.json"), options: [.atomic])
    }

    /// Quick guard to ensure the repo folder looks initialized.
    public func ensureRepoInitialized(_ repoURL: URL) throws {
        let configURL = repoURL.appendingPathComponent("config.json")
        if !fm.fileExists(atPath: configURL.path) {
            throw BackupError.repoNotInitialized(repoURL)
        }
    }

    // MARK: Backup
    /// Create a snapshot by copying files from the given source folders into the repository.
    ///
    /// This runs in two phases:
    /// 1) Plan: enumerate each source, apply filtering (include/exclude and .bckpignore), create needed folders,
    ///    and build a list of WorkItems (files/symlinks) to process. We also compute total counts/sizes for progress.
    /// 2) Execute: process WorkItems concurrently on an OperationQueue, with an optional progress callback.
    ///
    /// - Parameters:
    ///   - sources: Directories to include in the snapshot. Hidden files are skipped by the enumerator.
    ///   - repoURL: Repository root directory.
    ///   - options: Filters (include/exclude), optional concurrency limit, etc.
    ///   - progress: Optional callback invoked periodically with cumulative progress (thread-safe).
    /// - Returns: A Snapshot object that describes what we stored.
    public func backup(
        sources: [URL],
        to repoURL: URL = defaultRepoURL,
        options: BackupOptions = BackupOptions(),
        progress: ((BackupProgress) -> Void)? = nil
    ) throws -> Snapshot {
        try ensureRepoInitialized(repoURL)
        let validSources = try sources.map { src -> URL in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue else {
                throw BackupError.notADirectory(src)
            }
            return src
        }

    let snapshotId = Self.makeSnapshotId()
    Logger.shared.info("backup starting id=\(snapshotId) sources=\(validSources.count)", subsystem: "core.backup", context: ["repo": repoURL.path])

    // We'll size the sparse image to the estimated required size with a safety margin.
    // First, plan work and compute totalBytes below, then create the image accordingly.
    let snapsDir = repoURL.appendingPathComponent("snapshots", isDirectory: true)
    try fm.createDirectory(at: snapsDir, withIntermediateDirectories: true)
    let imageURL = snapsDir.appendingPathComponent("\(snapshotId).sparseimage")
    // Note: snapshotDir is no longer used as a mount target; we mount under ~/Backups instead.

        // Load per-source .bckpignore patterns
        // Per-source filter set. If a source has a .bckpignore file, it overrides CLI include/exclude for that source.
        struct SourceFilter { let include: [String]; let exclude: [String]; let reincludes: [String] }
        var perSource: [URL: SourceFilter] = [:]
        for src in validSources {
            let ignoreURL = src.appendingPathComponent(".bckpignore")
            let parsed = parseBckpIgnore(at: ignoreURL)
            // Merge global options with per-source file; per-source takes precedence when present
            let inc = parsed.includes.isEmpty ? options.include : parsed.includes
            let exc = parsed.excludes.isEmpty ? options.exclude : parsed.excludes
            perSource[src] = SourceFilter(include: inc, exclude: exc, reincludes: parsed.reincludes)
        }

        // Work item represents a copy or symlink recreation
        enum WorkKind { case file(size: Int64), symlink }
    struct WorkItem { let src: URL; let top: String; let relPath: String; let kind: WorkKind }

    var tasks: [WorkItem] = []
    var totalFiles = 0 // regular files only
    var totalBytes: Int64 = 0

        // Phase 1: Enumerate and plan work; create directories as needed so phase 2 can run safely in parallel.
    for src in validSources {
            let enumerator = fm.enumerator(at: src, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])

            while let item = enumerator?.nextObject() as? URL {
                let rv = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
                let relPath = Self.relativePath(of: item, under: src)
                let filter = perSource[src] ?? SourceFilter(include: options.include, exclude: options.exclude, reincludes: [])

                if rv.isDirectory == true {
                    // Optimization: if a directory is excluded and not re-included, skip descending into it.
                    if anyMatch(filter.exclude, path: relPath) && !anyMatch(filter.reincludes, path: relPath) {
                        enumerator?.skipDescendants()
                        continue
                    }
            // No-op during planning
                } else if rv.isRegularFile == true {
                    if !Self.isIncluded(relPath: relPath, include: filter.include, exclude: filter.exclude, reincludes: filter.reincludes) { continue }
                    let size = Int64(rv.fileSize ?? 0)
            tasks.append(WorkItem(src: item, top: src.lastPathComponent, relPath: relPath, kind: .file(size: size)))
                    totalFiles += 1
                    totalBytes += size
                } else if rv.isSymbolicLink == true {
                    if !Self.isIncluded(relPath: relPath, include: filter.include, exclude: filter.exclude, reincludes: filter.reincludes) { continue }
            tasks.append(WorkItem(src: item, top: src.lastPathComponent, relPath: relPath, kind: .symlink))
                }
            }
        }

    // Now that we know totalBytes, create and mount the sparse image sized to fit with headroom.
    // Use 1.2x headroom and minimum 1 MiB.
    let headroomBytes = max(Int64(64 * 1024 * 1024), Int64(Double(totalBytes) * 0.5))
    var capacity = max(Int64(1 * 1024 * 1024), totalBytes + headroomBytes)
    // Round up to nearest 8 MiB to reduce APFS overhead issues
    let eightMiB: Int64 = 8 * 1024 * 1024
    capacity = ((capacity + eightMiB - 1) / eightMiB) * eightMiB
    let mib = (capacity + 1024 * 1024 - 1) / (1024 * 1024)
    let sizeArg = "\(mib)m"
    try DiskImage.createSparseImage(at: imageURL, size: sizeArg, volumeName: "bckp-\(snapshotId)", encryption: options.encryption)
    // Mount under ~/Backups instead of system temp to keep paths predictable
    let home = FileManager.default.homeDirectoryForCurrentUser
    let backupsRoot = home.appendingPathComponent("Backups", isDirectory: true)
    try fm.createDirectory(at: backupsRoot, withIntermediateDirectories: true)
    let mountPoint = backupsRoot.appendingPathComponent("bckp-local-\(snapshotId)", isDirectory: true)
    let (device, _) = try DiskImage.attach(imageURL: imageURL, mountpoint: mountPoint)
    defer { try? DiskImage.detach(device: device, mountPoint: mountPoint) }
    let dataRoot = mountPoint.appendingPathComponent("data", isDirectory: true)
    try fm.createDirectory(at: dataRoot, withIntermediateDirectories: true)

    // Phase 2: Execute work concurrently with progress reporting.
        if let cb = progress {
            cb(BackupProgress(processedFiles: 0, totalFiles: totalFiles, processedBytes: 0, totalBytes: totalBytes, currentPath: "[data] copying data..."))
        }
        let maxConcurrency = max(1, options.concurrency ?? ProcessInfo.processInfo.activeProcessorCount)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = maxConcurrency
        queue.qualityOfService = .userInitiated

        // Progress aggregation must be thread-safe, so we guard with a serial queue.
        let progressSync = DispatchQueue(label: "bckp.progress.sync")
        var processedFiles = 0
        var processedBytes: Int64 = 0
        // We capture only the first error (if any) and surface it after all ops complete.
        var firstError: Error?

    for t in tasks {
            queue.addOperation {
                // Use a dedicated FileManager per op for thread-safety
                let localFM = FileManager()
                do {
                    switch t.kind {
                    case .file(let size):
                        let dst = dataRoot.appendingPathComponent(t.top, isDirectory: true).appendingPathComponent(t.relPath)
                        let parent = dst.deletingLastPathComponent()
                        try? localFM.createDirectory(at: parent, withIntermediateDirectories: true)
                        if localFM.fileExists(atPath: dst.path) { try? localFM.removeItem(at: dst) }
                        try localFM.copyItem(at: t.src, to: dst)
                        progressSync.sync {
                            processedFiles += 1
                            processedBytes += size
                            if let cb = progress {
                                cb(BackupProgress(processedFiles: processedFiles, totalFiles: totalFiles, processedBytes: processedBytes, totalBytes: totalBytes, currentPath: t.relPath))
                            }
                        }
                    case .symlink:
            let dst = dataRoot.appendingPathComponent(t.top, isDirectory: true).appendingPathComponent(t.relPath)
            let parent = dst.deletingLastPathComponent()
                        try? localFM.createDirectory(at: parent, withIntermediateDirectories: true)
                        do {
                            let destPath = try localFM.destinationOfSymbolicLink(atPath: t.src.path)
                try localFM.createSymbolicLink(atPath: dst.path, withDestinationPath: destPath)
                        } catch {
                            // Fallback to copying contents
                try localFM.copyItem(at: t.src, to: dst)
                        }
                        // Symlinks do not affect file counters in Snapshot; we still can emit progress without changing counts
                        if let cb = progress {
                            progressSync.sync {
                                cb(BackupProgress(processedFiles: processedFiles, totalFiles: totalFiles, processedBytes: processedBytes, totalBytes: totalBytes, currentPath: t.relPath))
                            }
                        }
                    }
                } catch {
            Logger.shared.error("copy failed: \(t.relPath): \(error)", subsystem: "core.backup")
                    progressSync.sync { if firstError == nil { firstError = error } }
                }
            }
        }

        queue.waitUntilAllOperationsAreFinished()
        if let err = firstError { Logger.shared.error("backup failed: \(err)", subsystem: "core.backup"); throw err }

        if let cb = progress {
            cb(BackupProgress(processedFiles: processedFiles, totalFiles: totalFiles, processedBytes: processedBytes, totalBytes: totalBytes, currentPath: "[data] staging complete"))
        }

        let snapshot = Snapshot(
            id: snapshotId,
            createdAt: Date(),
            sources: validSources.map { $0.path },
            totalFiles: totalFiles,
            totalBytes: totalBytes,
            relativePath: "snapshots/\(snapshotId)"
        )

        // Write manifest (JSON) so we can list and inspect this snapshot later. Store it inside the mounted image.
    let manifestURL = mountPoint.appendingPathComponent("manifest.json")
        let data = try JSON.encoder.encode(snapshot)
        try data.write(to: manifestURL, options: [.atomic])

        // Optional: emit MD5 of the sparse image for visibility when a progress callback was provided by callers (e.g., CLI)
        if let cb = progress {
            if let md5 = try? BackupManager.fileMD5Base64(of: imageURL) {
                cb(BackupProgress(processedFiles: totalFiles, totalFiles: totalFiles, processedBytes: totalBytes, totalBytes: totalBytes, currentPath: "MD5 " + md5))
            }
        }

        Logger.shared.info("backup finished id=\(snapshotId) files=\(totalFiles) bytes=\(totalBytes)", subsystem: "core.backup")
        return snapshot
    }

    // MARK: Prune
    /// Remove old snapshots according to a policy. Always keeps at least the most recent snapshot.
    public func prune(in repoURL: URL = defaultRepoURL, policy: PrunePolicy) throws -> PruneResult {
        try ensureRepoInitialized(repoURL)
        let items = try listSnapshots(in: repoURL) // ascending by createdAt
        if items.isEmpty { Logger.shared.info("prune: no snapshots", subsystem: "core.prune"); return PruneResult(deleted: [], kept: []) }

        let snapsDir = repoURL.appendingPathComponent("snapshots", isDirectory: true)
        var keep = Set<String>()

        // Keep last N
        if let n = policy.keepLast, n > 0 {
            for it in items.suffix(n) { keep.insert(it.id) }
        }
        // Keep within last D days
        if let d = policy.keepDays, d > 0 {
            let cutoff = Date().addingTimeInterval(-TimeInterval(d * 24 * 60 * 60))
            for it in items where it.createdAt >= cutoff { keep.insert(it.id) }
        }
        // Always keep at least the newest snapshot
        if keep.isEmpty, let newest = items.last { keep.insert(newest.id) }

        var deleted: [String] = []
        var kept: [String] = []
        for it in items {
            if keep.contains(it.id) {
                kept.append(it.id)
                continue
            }
            let dir = snapsDir.appendingPathComponent(it.id, isDirectory: true)
            if FileManager.default.fileExists(atPath: dir.path) {
                try? FileManager.default.removeItem(at: dir)
            }
            let img = snapsDir.appendingPathComponent("\(it.id).sparseimage")
            if FileManager.default.fileExists(atPath: img.path) {
                try? FileManager.default.removeItem(at: img)
            }
            deleted.append(it.id)
        }
        Logger.shared.info("prune finished deleted=\(deleted.count) kept=\(kept.count)", subsystem: "core.prune")
        return PruneResult(deleted: deleted, kept: kept)
    }

    // MARK: Restore
    /// Restore a snapshot by copying its files to the destination folder.
    public func restore(snapshotId: String, from repoURL: URL = defaultRepoURL, to destination: URL) throws {
        try ensureRepoInitialized(repoURL)
        let snapsDir = repoURL.appendingPathComponent("snapshots", isDirectory: true)
        let imageURL = snapsDir.appendingPathComponent("\(snapshotId).sparseimage")
        var dataRoot: URL
        var mountDev: String?
        var mountPoint: URL?
        if fm.fileExists(atPath: imageURL.path) {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let backupsRoot = home.appendingPathComponent("Backups", isDirectory: true)
            try fm.createDirectory(at: backupsRoot, withIntermediateDirectories: true)
            let mp = backupsRoot.appendingPathComponent("bckp-restore-local-\(snapshotId)", isDirectory: true)
            let res = try DiskImage.attach(imageURL: imageURL, mountpoint: mp)
            mountDev = res.device
            mountPoint = mp
            let manifestURL = mp.appendingPathComponent("manifest.json")
            guard fm.fileExists(atPath: manifestURL.path) else { throw BackupError.snapshotNotFound(snapshotId) }
            dataRoot = mp.appendingPathComponent("data", isDirectory: true)
        } else {
            let snapshotDir = snapsDir.appendingPathComponent("\(snapshotId)", isDirectory: true)
            let manifestURL = snapshotDir.appendingPathComponent("manifest.json")
            guard fm.fileExists(atPath: manifestURL.path) else { throw BackupError.snapshotNotFound(snapshotId) }
            dataRoot = snapshotDir.appendingPathComponent("data", isDirectory: true)
        }
        defer {
            if let dev = mountDev, let mp = mountPoint {
                try? DiskImage.detach(device: dev, mountPoint: mp)
                try? fm.removeItem(at: mp)
            }
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        // Copy back contents of dataRoot to destination
        let enumerator = fm.enumerator(at: dataRoot, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: [])
        while let item = enumerator?.nextObject() as? URL {
            let relPath = Self.relativePath(of: item, under: dataRoot)
            let destURL = destination.appendingPathComponent(relPath)
            let rv = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if rv.isDirectory == true {
                try fm.createDirectory(at: destURL, withIntermediateDirectories: true)
            } else if rv.isRegularFile == true {
                let parent = destURL.deletingLastPathComponent()
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                if fm.fileExists(atPath: destURL.path) {
                    try fm.removeItem(at: destURL)
                }
                do { try fm.copyItem(at: item, to: destURL) } catch { Logger.shared.error("restore copy failed: \(relPath): \(error)", subsystem: "core.restore"); throw error }
            } else if rv.isSymbolicLink == true {
                let parent = destURL.deletingLastPathComponent()
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                if fm.fileExists(atPath: destURL.path) {
                    try fm.removeItem(at: destURL)
                }
                let destPath = try fm.destinationOfSymbolicLink(atPath: item.path)
                try fm.createSymbolicLink(atPath: destURL.path, withDestinationPath: destPath)
            }
        }
        Logger.shared.info("restore finished snapshot=\(snapshotId) to=\(destination.path)", subsystem: "core.restore")
    }

    // MARK: List
    public func listSnapshots(in repoURL: URL = defaultRepoURL) throws -> [SnapshotListItem] {
        try ensureRepoInitialized(repoURL)
        let snapsDir = repoURL.appendingPathComponent("snapshots", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(at: snapsDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var itemsById: [String: SnapshotListItem] = [:]
        // Mounted directories (if any)
        for dir in entries where dir.hasDirectoryPath {
            let id = dir.lastPathComponent
            let manifest = dir.appendingPathComponent("manifest.json")
            if let data = try? Data(contentsOf: manifest), let snap = try? JSON.decoder.decode(Snapshot.self, from: data) {
                // Use full source paths in listings
                itemsById[id] = SnapshotListItem(id: snap.id, createdAt: snap.createdAt, totalFiles: snap.totalFiles, totalBytes: snap.totalBytes, sources: snap.sources)
            }
        }
        // Sparse images (mount temporarily under ~/Backups to read manifest)
        for img in entries where img.pathExtension == "sparseimage" {
            let id = img.deletingPathExtension().lastPathComponent
            if itemsById[id] != nil { continue }
            let home = FileManager.default.homeDirectoryForCurrentUser
            let backupsRoot = home.appendingPathComponent("Backups", isDirectory: true)
            try? fm.createDirectory(at: backupsRoot, withIntermediateDirectories: true)
            let mount = backupsRoot.appendingPathComponent("bckp-list-\(id)", isDirectory: true)
            do {
                let (dev, _) = try DiskImage.attach(imageURL: img, mountpoint: mount)
                defer {
                    try? DiskImage.detach(device: dev, mountPoint: mount)
                    try? fm.removeItem(at: mount)
                }
                let manifest = mount.appendingPathComponent("manifest.json")
                if let data = try? Data(contentsOf: manifest), let snap = try? JSON.decoder.decode(Snapshot.self, from: data) {
                    itemsById[id] = SnapshotListItem(id: snap.id, createdAt: snap.createdAt, totalFiles: snap.totalFiles, totalBytes: snap.totalBytes, sources: snap.sources)
                }
            } catch {
                continue
            }
        }
        return itemsById.values.sorted { $0.createdAt < $1.createdAt }
    }

    // Helpers
    /// Create a human-sortable ID using the current timestamp and a short random suffix.
    static func makeSnapshotId() -> String {
        let ts = ISO8601DateFormatter()
        ts.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let stamp = ts.string(from: Date()).replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ".", with: "")
        let short = UUID().uuidString.prefix(8)
        return "\(stamp)-\(short)"
    }

    /// Compute a safe relative path of `child` under `base`, accounting for symlinks in parent components (e.g., /var vs /private/var).
    static func relativePath(of child: URL, under base: URL) -> String {
        let childPath = child.standardizedFileURL.path
        let basePath = base.standardizedFileURL.path
        if childPath == basePath { return "" }
        if childPath.hasPrefix(basePath + "/") {
            return String(childPath.dropFirst(basePath.count + 1))
        }
        // Fallback: if standardization still doesn't align (rare), use lastPathComponent to avoid absolute paths in archive
        return child.lastPathComponent
    }

    // MARK: Filtering
    static func isIncluded(relPath: String, options: BackupOptions) -> Bool {
        // Directories: always include so we can traverse; filtering applies to files/symlinks only.
        // Callers should use this only for non-directories.
        if !options.include.isEmpty {
            if !anyMatch(options.include, path: relPath) { return false }
        }
        if anyMatch(options.exclude, path: relPath) { return false }
        return true
    }

    static func isIncluded(relPath: String, include: [String], exclude: [String], reincludes: [String]) -> Bool {
        // Apply include first (if present)
        if !include.isEmpty && !anyMatch(include, path: relPath) { return false }
        // Apply exclude unless re-included
        if anyMatch(exclude, path: relPath) && !anyMatch(reincludes, path: relPath) { return false }
        return true
    }
}
