import Foundation
import ArgumentParser
import BackupCore

// MARK: - Command Line Interface (CLI)
// We use Swift ArgumentParser to define commands like:
//   bckp init-repo
//   bckp backup --source <path> --repo <path>
// Each subcommand is a small struct with options/arguments and a run() method.

struct Bckp: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "bckp",
        abstract: "Simple macOS backup tool",
        version: BckpVersion.string,
    subcommands: [InitRepo.self, Backup.self, Restore.self, List.self, Prune.self, InitAzure.self, BackupAzure.self, ListAzure.self, RestoreAzure.self, PruneAzure.self, Encryption.self, Repos.self, Logs.self, Drives.self],
        defaultSubcommand: nil
    )
}

extension Bckp {
    /// Initialize the repository folder on disk.
    struct InitRepo: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Initialize a backup repository")

            @Option(name: .shortAndLong, help: "Path to the repository root (default ~/Backups/bckp; can be set in config)")
        var repo: String?

        @Option(name: .long, help: "External volume UUID (macOS). If provided, creates the repo under this mounted volume.")
        var externalUUID: String?

        @Option(name: .long, help: "Subpath under the external volume where the repo will be created (default: Backups/bckp)")
        var externalSubpath: String?

        func run() throws {
            let manager = BackupManager()
                let cfg = AppConfigIO.load(from: AppConfig.defaultRepoConfigURL)

            // Resolve repo URL: explicit --repo wins; else allow --external-uuid on macOS; else config/default
            let repoURL: URL
            if let explicit = repo {
                repoURL = URL(fileURLWithPath: explicit)
            } else if let uuid = externalUUID {
                let disks = listExternalDiskIdentities()
                guard let match = disks.first(where: { ($0.volumeUUID?.lowercased() ?? "") == uuid.lowercased() }) else {
                    throw ValidationError("External volume with UUID \(uuid) not found or not mounted")
                }
                let sub = (externalSubpath?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) ?? "Backups/bckp"
                repoURL = match.volumeURL.appendingPathComponent(sub, isDirectory: true)
            } else {
                repoURL = URL(fileURLWithPath: cfg.repoPath ?? BackupManager.defaultRepoURL.path)
            }
            try manager.initRepo(at: repoURL)
            RepositoriesConfigStore.shared.recordRepoUsedLocal(repoURL: repoURL)
            print("Initialized repository at \(repoURL.path)")
        }
    }

    // MARK: - Encryption utilities
    struct Encryption: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Encryption utilities",
            subcommands: [Init.self]
        )

        struct Init: ParsableCommand {
            static var configuration = CommandConfiguration(abstract: "Initialize encryption: generate RSA-4096 key with ACL and self-signed certificate")

            @Option(name: .long, help: "Common Name for the certificate (e.g., 'Recipient Name (bckp)')")
            var cn: String

            @Flag(name: .long, help: "Attempt to sync key and certificate to iCloud Keychain (best-effort)")
            var icloudSync: Bool = false

            func run() throws {
                let fp = try EncryptionInitializer.generateSelfSignedRSA(commonName: cn, icloudSync: icloudSync)
                print("[encryption] generated RSA-4096 key + self-signed cert in login keychain")
                print("[encryption] CN=\(cn) sha1:\(fp)")
                if icloudSync { print("[encryption] iCloud sync requested (best-effort)") }
            }
        }
    }

    /// Create a snapshot from one or more source folders.
    struct Backup: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Create a snapshot from source directories")

        @Option(name: .shortAndLong, parsing: .upToNextOption, help: "One or more source directories to back up")
        var source: [String]

            @Option(name: .shortAndLong, help: "Path to the repository root (default ~/Backups/bckp; can be set in config)")
        var repo: String?

    @Option(name: [.customShort("I"), .customLong("include")], parsing: .upToNextOption, help: "Include glob patterns (relative to each source), e.g. '**/*.swift'")
    var include: [String] = []

    @Option(name: [.customShort("E"), .customLong("exclude")], parsing: .upToNextOption, help: "Exclude glob patterns (relative to each source), e.g. '**/.git/**'")
    var exclude: [String] = []

    @Option(name: .long, help: "Max concurrent copy operations (default: number of CPUs)")
    var concurrency: Int?

    @Flag(name: .long, help: "Print progress while copying")
    var progress: Bool = false

    @Option(name: .long, help: "Staging encryption mode: none | certificate")
    var encryptionMode: String?

    @Option(name: .long, parsing: .upToNextOption, help: "Recipients for certificate mode (selectors: sha1:HEX, cn:Name, label:Label)")
    var recipient: [String] = []

        func run() throws {
            guard !source.isEmpty else {
                throw ValidationError("Provide at least one --source path")
            }
            let manager = BackupManager()
                let cfg = AppConfigIO.load(from: AppConfig.defaultRepoConfigURL)
                let repoURL = URL(fileURLWithPath: repo ?? cfg.repoPath ?? BackupManager.defaultRepoURL.path)
            let sources = source.map { URL(fileURLWithPath: $0) }
                let encModeStr = (encryptionMode ?? cfg.encryptionMode ?? "none").lowercased()
                let encMode: EncryptionMode = (encModeStr == "certificate" ? .certificate : .none)
                let recipients = recipient.isEmpty ? cfg.encryptionRecipients : recipient
                let enc = EncryptionSettings(mode: encMode, recipients: recipients)
                let opts = BackupOptions(include: include.isEmpty ? cfg.include : include,
                                         exclude: exclude.isEmpty ? cfg.exclude : exclude,
                                         concurrency: concurrency ?? cfg.concurrency,
                                         encryption: encMode == .none ? nil : enc)
            RepositoriesConfigStore.shared.updateConfiguredSourcesLocal(repoURL: repoURL, sources: sources)
            var lastMD5: String?
            let snap = try manager.backup(sources: sources, to: repoURL, options: opts, progress: progress ? { p in
                let cur = p.currentPath ?? ""
                if cur.hasPrefix("MD5 ") { lastMD5 = String(cur.dropFirst(4)) }
                // Show only known summary tags and the final MD5 line
                if cur.hasPrefix("[plan]") || cur.hasPrefix("[disk]") || cur.hasPrefix("[data]") || cur.hasPrefix("[hash]") || cur.hasPrefix("[azure]") || cur.hasPrefix("[cleanup]") || cur.hasPrefix("MD5 ") {
                    print(cur)
                }
            } : nil)
            RepositoriesConfigStore.shared.recordBackupLocal(repoURL: repoURL, sourcePaths: sources)
            if let md5 = lastMD5 { print("Created snapshot: \(snap.id) | files: \(snap.totalFiles) | size: \(snap.totalBytes) | md5: \(md5)") }
            else { print("Created snapshot: \(snap.id) | files: \(snap.totalFiles) | size: \(snap.totalBytes)") }
        }
    }

    /// Restore a snapshot's files into a destination folder.
    struct Restore: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Restore a snapshot to a destination directory")

        @Argument(help: "Snapshot ID to restore")
        var id: String

            @Option(name: .shortAndLong, help: "Path to the repository root (default ~/Backups/bckp; can be set in config)")
        var repo: String?

        @Option(name: .shortAndLong, help: "Destination path")
        var destination: String

        func run() throws {
            let manager = BackupManager()
                let cfg = AppConfigIO.load(from: AppConfig.defaultRepoConfigURL)
                let repoURL = URL(fileURLWithPath: repo ?? cfg.repoPath ?? BackupManager.defaultRepoURL.path)
            try manager.restore(snapshotId: id, from: repoURL, to: URL(fileURLWithPath: destination))
            RepositoriesConfigStore.shared.recordRepoUsedLocal(repoURL: repoURL)
            print("Restored snapshot \(id) to \(destination)")
        }
    }

    /// Print a list of snapshots in the repository.
    struct List: ParsableCommand {
    static var configuration = CommandConfiguration(abstract: "List snapshots in a repository. Columns: ID<TAB>ISO8601 Date<TAB>Files<TAB>Size (bytes)<TAB>Sources (comma-separated full paths)")

        @Option(name: .shortAndLong, help: "Path to the repository root (default ~/Backups/bckp)")
        var repo: String?

        func run() throws {
            let manager = BackupManager()
                let cfg = AppConfigIO.load(from: AppConfig.defaultRepoConfigURL)
                let repoURL = URL(fileURLWithPath: repo ?? cfg.repoPath ?? BackupManager.defaultRepoURL.path)
            let items = try manager.listSnapshots(in: repoURL)
            if items.isEmpty {
                print("No snapshots found")
            } else {
                for it in items {
                    let sources = it.sources.joined(separator: ",")
                    print("\(it.id)\t\(ISO8601DateFormatter().string(from: it.createdAt))\t\(it.totalFiles)\t\(it.totalBytes)\t\(sources)")
                }
            }
        }
    }

    /// Prune old snapshots per a retention policy.
    struct Prune: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Delete old snapshots using a retention policy")

        @Option(name: .shortAndLong, help: "Path to the repository root (default ~/Backups/bckp)")
        var repo: String?

        @Option(name: .long, help: "Keep the N most recent snapshots")
        var keepLast: Int?

        @Option(name: .long, help: "Keep snapshots from the last D days")
        var keepDays: Int?

        @Flag(name: .long, help: "Delete ALL snapshots (dangerous). This bypasses safety and removes the newest as well.")
        var forceAll: Bool = false

        func run() throws {
            let manager = BackupManager()
                let cfg = AppConfigIO.load(from: AppConfig.defaultRepoConfigURL)
                let repoURL = URL(fileURLWithPath: repo ?? cfg.repoPath ?? BackupManager.defaultRepoURL.path)
            if forceAll {
                try manager.ensureRepoInitialized(repoURL)
                let items = try manager.listSnapshots(in: repoURL)
                if items.isEmpty { print("Pruned. Deleted: 0 | Kept: 0"); return }
                let snapsDir = repoURL.appendingPathComponent("snapshots", isDirectory: true)
                var deleted: [String] = []
                for it in items {
                    let dir = snapsDir.appendingPathComponent(it.id, isDirectory: true)
                    let img = snapsDir.appendingPathComponent("\(it.id).sparseimage")
                    if FileManager.default.fileExists(atPath: dir.path) { try? FileManager.default.removeItem(at: dir) }
                    if FileManager.default.fileExists(atPath: img.path) { try? FileManager.default.removeItem(at: img) }
                    deleted.append(it.id)
                }
                print("Pruned. Deleted: \(deleted.count) | Kept: 0")
                if !deleted.isEmpty { print("Deleted IDs: \(deleted.joined(separator: ", "))") }
            } else {
                let policy = PrunePolicy(keepLast: keepLast, keepDays: keepDays)
                let result = try manager.prune(in: repoURL, policy: policy)
                print("Pruned. Deleted: \(result.deleted.count) | Kept: \(result.kept.count)")
                if !result.deleted.isEmpty {
                    print("Deleted IDs: \(result.deleted.joined(separator: ", "))")
                }
            }
        }
    }

    // MARK: - Azure Blob (SAS) subcommands
    /// Initialize a cloud repository in an Azure Blob container using a SAS URL.
    struct InitAzure: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Initialize Azure Blob container as a bckp repository (SAS)")

    @Option(name: .long, help: "Azure container SAS URL (can be set in config; e.g. https://acct.blob.core.windows.net/container?sv=...&sig=...)")
    var sas: String?

        func run() throws {
            let manager = BackupManager()
            let cfg = AppConfigIO.load(from: AppConfig.defaultRepoConfigURL)
            let sasURL = URL(string: sas ?? cfg.azureSAS ?? "")
            guard let sasURL else { throw ValidationError("Provide --sas or set [azure] sas in config") }
            try manager.initAzureRepo(containerSASURL: sasURL)
            RepositoriesConfigStore.shared.recordRepoUsedAzure(containerSASURL: sasURL)
            print("Initialized Azure repo at container SAS")
        }
    }

    /// Backup to Azure using a SAS container URL.
    struct BackupAzure: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Create a cloud snapshot in Azure Blob (SAS)")

        @Option(name: .shortAndLong, parsing: .upToNextOption, help: "One or more source directories to back up")
        var source: [String]

            @Option(name: .long, help: "Azure container SAS URL (can be set in config)")
            var sas: String?

        @Option(name: [.customShort("I"), .customLong("include")], parsing: .upToNextOption, help: "Include glob patterns")
        var include: [String] = []

        @Option(name: [.customShort("E"), .customLong("exclude")], parsing: .upToNextOption, help: "Exclude glob patterns")
        var exclude: [String] = []

        @Option(name: .long, help: "Max concurrent uploads (default: number of CPUs)")
        var concurrency: Int?

        @Flag(name: .long, help: "Print progress while uploading")
        var progress: Bool = false

    @Option(name: .long, help: "Staging encryption mode: none | certificate")
    var encryptionMode: String?

    @Option(name: .long, parsing: .upToNextOption, help: "Recipients for certificate mode (selectors: sha1:HEX, cn:Name, label:Label)")
    var recipient: [String] = []

        func run() throws {
            guard !source.isEmpty else { throw ValidationError("Provide at least one --source path") }
            let manager = BackupManager()
            let cfg = AppConfigIO.load(from: AppConfig.defaultRepoConfigURL)
            let sources = source.map { URL(fileURLWithPath: $0) }
                let encModeStr = (encryptionMode ?? cfg.encryptionMode ?? "none").lowercased()
                let encMode: EncryptionMode = (encModeStr == "certificate" ? .certificate : .none)
                let recipients = recipient.isEmpty ? cfg.encryptionRecipients : recipient
                let enc = EncryptionSettings(mode: encMode, recipients: recipients)
                let opts = BackupOptions(include: include.isEmpty ? cfg.include : include,
                                         exclude: exclude.isEmpty ? cfg.exclude : exclude,
                                         concurrency: concurrency ?? cfg.concurrency,
                                         encryption: encMode == .none ? nil : enc)
                let sasURL = URL(string: sas ?? cfg.azureSAS ?? "")
                guard let sasURL else { throw ValidationError("Provide --sas or set [azure] sas in config") }
                RepositoriesConfigStore.shared.updateConfiguredSourcesAzure(containerSASURL: sasURL, sources: sources)
                var lastMD5: String?
                let snap = try manager.backupToAzure(sources: sources, containerSASURL: sasURL, options: opts, progress: progress ? { p in
                let cur = p.currentPath ?? ""
                if cur.hasPrefix("MD5 ") { lastMD5 = String(cur.dropFirst(4)) }
                // Show only known summary tags and the final MD5 line
                if cur.hasPrefix("[plan]") || cur.hasPrefix("[disk]") || cur.hasPrefix("[data]") || cur.hasPrefix("[hash]") || cur.hasPrefix("[azure]") || cur.hasPrefix("[cleanup]") || cur.hasPrefix("MD5 ") {
                    print(cur)
                }
            } : nil)
            RepositoriesConfigStore.shared.recordBackupAzure(containerSASURL: sasURL, sourcePaths: sources)
            if let md5 = lastMD5 { print("Created cloud snapshot: \(snap.id) | files: \(snap.totalFiles) | size: \(snap.totalBytes) | md5: \(md5)") }
            else { print("Created cloud snapshot: \(snap.id) | files: \(snap.totalFiles) | size: \(snap.totalBytes)") }
        }
    }

    struct ListAzure: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "List snapshots in an Azure Blob repo (SAS). Columns: ID<TAB>ISO8601 Date<TAB>Files<TAB>Size (bytes)<TAB>Sources (comma-separated full paths)")

        @Option(name: .long, help: "Azure container SAS URL (can be set in config)")
        var sas: String?

        func run() throws {
            let manager = BackupManager()
            let cfg = AppConfigIO.load(from: AppConfig.defaultRepoConfigURL)
            let sasURL = URL(string: sas ?? cfg.azureSAS ?? "")
            guard let sasURL else { throw ValidationError("Provide --sas or set [azure] sas in config") }
            let items = try manager.listSnapshotsInAzure(containerSASURL: sasURL)
            if items.isEmpty { print("No snapshots found") }
            else {
                for it in items {
                    let sources = it.sources.joined(separator: ",")
                    print("\(it.id)\t\(ISO8601DateFormatter().string(from: it.createdAt))\t\(it.totalFiles)\t\(it.totalBytes)\t\(sources)")
                }
            }
        }
    }

    struct RestoreAzure: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Restore a cloud snapshot from Azure Blob (SAS)")

        @Argument(help: "Snapshot ID to restore")
        var id: String

        @Option(name: .long, help: "Azure container SAS URL (can be set in config)")
        var sas: String?

        @Option(name: .shortAndLong, help: "Destination path")
        var destination: String

        @Option(name: .long, help: "Max concurrent downloads (default: number of CPUs)")
        var concurrency: Int?

        func run() throws {
            let manager = BackupManager()
            let cfg = AppConfigIO.load(from: AppConfig.defaultRepoConfigURL)
            let sasURL = URL(string: sas ?? cfg.azureSAS ?? "")
            guard let sasURL else { throw ValidationError("Provide --sas or set [azure] sas in config") }
            try manager.restoreFromAzure(snapshotId: id, containerSASURL: sasURL, to: URL(fileURLWithPath: destination), concurrency: concurrency ?? cfg.concurrency)
            RepositoriesConfigStore.shared.recordRepoUsedAzure(containerSASURL: sasURL)
            print("Restored cloud snapshot \(id) to \(destination)")
        }
    }

    struct PruneAzure: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Prune cloud snapshots in Azure Blob (SAS)")

    @Option(name: .long, help: "Azure container SAS URL (can be set in config)")
    var sas: String?

        @Option(name: .long, help: "Keep the N most recent snapshots")
        var keepLast: Int?

        @Option(name: .long, help: "Keep snapshots from the last D days")
        var keepDays: Int?

        @Flag(name: .long, help: "Delete ALL cloud snapshots (dangerous). This bypasses safety and removes the newest as well.")
        var forceAll: Bool = false

        func run() throws {
            let manager = BackupManager()
            let cfg = AppConfigIO.load(from: AppConfig.defaultRepoConfigURL)
            let sasURL = URL(string: sas ?? cfg.azureSAS ?? "")
            guard let sasURL else { throw ValidationError("Provide --sas or set [azure] sas in config") }
            if forceAll {
                let items = try manager.listSnapshotsInAzure(containerSASURL: sasURL)
                if items.isEmpty { print("Pruned (cloud). Deleted: 0 | Kept: 0"); return }
                let client = AzureBlobClient(containerSASURL: sasURL)
                var deleted: [String] = []
                for it in items {
                    let prefix = "snapshots/\(it.id)/"
                    let list = try client.list(prefix: prefix, delimiter: nil)
                    for b in list.blobs { try? client.delete(blobPath: b) }
                    deleted.append(it.id)
                }
                print("Pruned (cloud). Deleted: \(deleted.count) | Kept: 0")
                if !deleted.isEmpty { print("Deleted IDs: \(deleted.joined(separator: ", "))") }
            } else {
                let policy = PrunePolicy(keepLast: keepLast, keepDays: keepDays)
                let result = try manager.pruneInAzure(containerSASURL: sasURL, policy: policy)
                print("Pruned (cloud). Deleted: \(result.deleted.count) | Kept: \(result.kept.count)")
                if !result.deleted.isEmpty { print("Deleted IDs: \(result.deleted.joined(separator: ", "))") }
            }
        }
    }
}

// MARK: - Inspect repositories.json
extension Bckp {
    struct Repos: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Inspect tracked repositories usage (repositories.json). Columns: KEY<TAB>LastUsedISO8601<TAB>SourcePath<TAB>LastBackupISO8601")

        @Flag(name: .long, help: "Output as pretty JSON instead of tab-separated rows")
        var json: Bool = false

        @Flag(name: .long, help: "Clear all tracked repositories (resets repositories.json)")
        var clear: Bool = false

        func run() throws {
            if clear {
                RepositoriesConfigStore.shared.clearAll()
                print("Cleared repositories.json")
                return
            }
            let cfg = RepositoriesConfigStore.shared.config
            if json {
                let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
                let data = try enc.encode(cfg)
                if let s = String(data: data, encoding: .utf8) { print(s) }
                return
            }
            if cfg.repositories.isEmpty {
                print("No repositories tracked yet")
                return
            }
            let dateFmt = ISO8601DateFormatter()
            for (key, info) in cfg.repositories.sorted(by: { $0.key < $1.key }) {
                let lastUsed = info.lastUsedAt.map { dateFmt.string(from: $0) } ?? ""
                if info.sources.isEmpty {
                    print("\(key)\t\(lastUsed)\t\t")
                } else {
                    for s in info.sources.sorted(by: { $0.path < $1.path }) {
                        let lb = s.lastBackupAt.map { dateFmt.string(from: $0) } ?? ""
                        print("\(key)\t\(lastUsed)\t\(s.path)\t\(lb)")
                    }
                }
            }
        }
    }
}

// MARK: - Logs viewer (NDJSON)
extension Bckp {
    struct Logs: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "View bckp logs (NDJSON). Defaults to today's file. Use --list to see available files.")

        @Flag(name: .long, help: "List available log files")
        var list: Bool = false

        @Option(name: .long, help: "Date (YYYY-MM-DD) of the log file to read; default: today")
        var date: String?

        @Option(name: .long, help: "Minimum level to show: error|warning|info|debug (default: info)")
        var level: String?

        @Option(name: .long, parsing: .upToNextOption, help: "Filter by subsystem(s). Provide multiple --subsystem values to include more than one.")
        var subsystem: [String] = []

        @Option(name: .long, help: "Show only the last N lines before following/exit")
        var limit: Int?

        @Flag(name: .long, help: "Output raw NDJSON lines instead of formatted text")
        var json: Bool = false

        @Flag(name: .long, help: "Follow the file and print new lines as they are written (Ctrl-C to stop)")
        var follow: Bool = false

        func run() throws {
            let logsDir = Logger.defaultLogsDirectory()
            if list {
                let files = (try? FileManager.default.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles])) ?? []
                if files.isEmpty {
                    print("No log files in \(logsDir.path)")
                    return
                }
                for url in files.filter({ $0.pathExtension == "log" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    print(url.lastPathComponent)
                }
                return
            }

            let fileURL = try resolveLogFileURL(logsDir: logsDir)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw ValidationError("Log file not found: \(fileURL.lastPathComponent)")
            }

            let minLevel = parseLevel(level) ?? .info
            let subsystems = Set(subsystem.map { $0.lowercased() })

            // Print initial content (optionally limited)
            let (entries, rawLines) = loadEntries(from: fileURL)
            let pairs: [(LogEntry, String)] = Array(zip(entries, rawLines))
            var filtered = pairs.filter { (e, _) in
                let levelOK = e.level <= minLevel
                let subsystemOK = subsystems.isEmpty || subsystems.contains(e.subsystem.lowercased())
                return levelOK && subsystemOK
            }
            if let limit, limit > 0, filtered.count > limit { filtered = Array(filtered.suffix(limit)) }
            output(filtered: filtered, asJSON: json)

            guard follow else { return }

            // Follow: keep reading appended data
            try followFile(url: fileURL, minLevel: minLevel, subsystems: subsystems, asJSON: json)
        }

        // MARK: - Helpers
        private func resolveLogFileURL(logsDir: URL) throws -> URL {
            if let date {
                // expect yyyy-MM-dd
                return logsDir.appendingPathComponent("bckp-\(date).log")
            }
            let fmt = DateFormatter(); fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd"
            let day = fmt.string(from: Date())
            return logsDir.appendingPathComponent("bckp-\(day).log")
        }

        private func parseLevel(_ s: String?) -> LogLevel? {
            guard let s else { return nil }
            switch s.lowercased() {
            case "error": return .error
            case "warning": return .warning
            case "info": return .info
            case "debug": return .debug
            default: return nil
            }
        }

        private func loadEntries(from url: URL) -> ([LogEntry], [String]) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return ([], []) }
            let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }).map { String($0) }
            var entries: [LogEntry] = []
            var raws: [String] = []
            for line in lines {
                if let d = line.data(using: .utf8), let e = try? dec.decode(LogEntry.self, from: d) {
                    entries.append(e); raws.append(line)
                }
            }
            return (entries, raws)
        }

    private func output(filtered: [(LogEntry, String)], asJSON: Bool) {
            if asJSON {
        for (_, raw) in filtered { print(raw) }
            } else {
                let df = ISO8601DateFormatter()
                for (e, _) in filtered {
                    var line = "\(df.string(from: e.timestamp))\t\(e.level.rawValue.uppercased())\t\(e.subsystem)\t\(e.message)"
                    if let ctx = e.context, !ctx.isEmpty {
                        let extras = ctx.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: ",")
                        line.append("\t{\(extras)}")
                    }
                    print(line)
                }
            }
        }

        private func followFile(url: URL, minLevel: LogLevel, subsystems: Set<String>, asJSON: Bool) throws {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            let handle = try FileHandle(forReadingFrom: url)
            var offset: UInt64 = try handle.seekToEnd()
            let df = ISO8601DateFormatter()
            while true {
                // Check for new data
                let end = try handle.seekToEnd()
                if end > offset {
                    let length = end - offset
                    try handle.seek(toOffset: offset)
                    if let data = try handle.read(upToCount: Int(length)), let text = String(data: data, encoding: .utf8) {
                        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }).map({ String($0) }) {
                            if let d = rawLine.data(using: .utf8), let e = try? dec.decode(LogEntry.self, from: d) {
                                let levelOK = e.level <= minLevel
                                let subsystemOK = subsystems.isEmpty || subsystems.contains(e.subsystem.lowercased())
                                if levelOK && subsystemOK {
                                    if asJSON { print(rawLine) }
                                    else {
                                        var line = "\(df.string(from: e.timestamp))\t\(e.level.rawValue.uppercased())\t\(e.subsystem)\t\(e.message)"
                                        if let ctx = e.context, !ctx.isEmpty {
                                            let extras = ctx.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: ",")
                                            line.append("\t{\(extras)}")
                                        }
                                        print(line)
                                    }
                                }
                            }
                        }
                    }
                    offset = end
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }
}

// MARK: - External drives
extension Bckp {
    struct Drives: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "List external/removable drives (macOS). Columns: UUID\tMountPath\tDevice")

        @Flag(name: .long, help: "Output as pretty JSON instead of tab-separated rows")
        var json: Bool = false

    func run() throws {
            let disks = listExternalDiskIdentities()
            if json {
                let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try enc.encode(disks)
                if let s = String(data: data, encoding: .utf8) { print(s) }
                return
            }
            if disks.isEmpty {
                print("No external drives detected")
                return
            }
            for d in disks {
                let uuid = d.volumeUUID ?? ""
                let dev = d.deviceBSDName ?? ""
                print("\(uuid)\t\(d.volumeURL.path)\t\(dev)")
            }
        }
    }
}

// Entry point for the CLI app.
Bckp.main()
