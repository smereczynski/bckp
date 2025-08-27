import Foundation
import CryptoKit

// MARK: - Azure Blob Storage (SAS) minimal client
// This client supports basic operations needed by our cloud repository:
// - Upload block blobs (single PUT for small files, Put Block + Put Block List for large files)
// - Download blobs
// - List blobs under a prefix (flat or by delimiter)
// - Delete blobs
// - Check existence
// The client is synchronous (blocking) and built on URLSession with semaphores for simplicity.

public struct AzureBlobClient {
    public let containerSASURL: URL // e.g. https://account.blob.core.windows.net/container?sv=...&sig=...
    private let session: URLSession
    private let apiVersion = "2021-08-06" // Sent as x-ms-version header for compatibility

    public init(containerSASURL: URL, session: URLSession = .shared) {
        self.containerSASURL = containerSASURL
        self.session = session
    }

    // Compose a blob URL by appending the blob path to the container SAS URL while preserving the query string.
    private func makeBlobURL(path: String) -> URL {
    let comps = URLComponents(url: containerSASURL, resolvingAgainstBaseURL: false)!
        var base = comps
        base.path = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Ensure single leading slash for container
        let containerPath = "/" + (base.path.isEmpty ? "" : base.path)
        base.path = containerPath + "/" + path
        return base.url!
    }

    // MARK: - Upload
    // Upload a local file as a block blob.
    // Sizing rules:
    // - If the file size is <= chunkSize (default 8 MiB), use a single Put Blob request.
    // - If the file size is > chunkSize, stream the upload via Put Block/Put Block List using blocks of size `chunkSize`.
    //   The last block may be smaller.
    // Integrity:
    // - For single PUT we compute MD5 over the whole payload and set both Content-MD5 and x-ms-blob-content-md5.
    // - For chunked uploads we compute an MD5 over the concatenated block data and set x-ms-blob-content-md5 at commit time.
    // Progress:
    // - Optional `progress` callback receives short textual status like "PUT chunked start ...", "PUT block i/N (...)".
    public func uploadFile(localURL: URL, toBlobPath blobPath: String, chunkSize: Int = 8 * 1024 * 1024, progress: ((String) -> Void)? = nil) throws {
        let attr = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let size = (attr[.size] as? NSNumber)?.intValue ?? 0
        if size <= chunkSize {
            try putBlob(localURL: localURL, toBlobPath: blobPath, progress: progress)
        } else {
            try putBlobChunked(localURL: localURL, toBlobPath: blobPath, chunkSize: chunkSize, totalSize: size, progress: progress)
        }
    }

    private func putBlob(localURL: URL, toBlobPath blobPath: String, progress: ((String) -> Void)? = nil) throws {
        var req = URLRequest(url: makeBlobURL(path: blobPath))
        req.httpMethod = "PUT"
        req.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
        req.setValue(apiVersion, forHTTPHeaderField: "x-ms-version")
        let data = try Data(contentsOf: localURL)
        // Compute MD5 and set as both integrity header and blob property so it can be verified later.
        let digest = Insecure.MD5.hash(data: data)
        let md5Base64 = Data(digest).base64EncodedString()
        req.setValue(md5Base64, forHTTPHeaderField: "x-ms-blob-content-md5")
        req.setValue(md5Base64, forHTTPHeaderField: "Content-MD5")
        req.httpBody = data
        progress?("PUT blob size \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
        let (resp, err) = performSync(request: req)
        if let err = err { throw err }
        guard let http = resp as? HTTPURLResponse, (200...201).contains(http.statusCode) else {
            throw AzureError.uploadFailed(status: (resp as? HTTPURLResponse)?.statusCode ?? -1, path: blobPath)
        }
    }

    private func putBlobChunked(localURL: URL, toBlobPath blobPath: String, chunkSize: Int, totalSize: Int, progress: ((String) -> Void)? = nil) throws {
        // Note: chunkSize defaults to 8 MiB which balances memory footprint and request size.
        // Adjust callers if you need larger blocks; the code does not currently vary chunkSize dynamically.
        let totalBlocks = Int(ceil(Double(totalSize) / Double(chunkSize)))
        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        var blockIds: [String] = []
        var index = 0
        var hasher = Insecure.MD5()
        progress?("PUT chunked start \(totalBlocks) blocks @ \(ByteCountFormatter.string(fromByteCount: Int64(chunkSize), countStyle: .file)) each (last may be smaller)")
        while true {
            let data = handle.readData(ofLength: chunkSize)
            if data.isEmpty { break }
            let rawId = String(format: "%06d", index)
            let blockId = Data(rawId.utf8).base64EncodedString()
            try putBlock(blobPath: blobPath, blockId: blockId, data: data)
            hasher.update(data: data)
            blockIds.append(blockId)
            progress?("PUT block \(index + 1)/\(totalBlocks) (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))")
            index += 1
        }
        let md5 = hasher.finalize()
        let md5Base64 = Data(md5).base64EncodedString()
    progress?("PUT block list commit")
        try putBlockList(blobPath: blobPath, blockIds: blockIds, blobContentMD5Base64: md5Base64)
        progress?("PUT complete")
    }

    private func putBlock(blobPath: String, blockId: String, data: Data) throws {
        var url = makeBlobURL(path: blobPath)
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let existing = comps.percentEncodedQuery.map { $0 + "&" } ?? ""
        comps.percentEncodedQuery = existing + "comp=block&blockid=" + blockId.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        url = comps.url!
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(apiVersion, forHTTPHeaderField: "x-ms-version")
        req.httpBody = data
        let (resp, err) = performSync(request: req)
        if let err = err { throw err }
        guard let http = resp as? HTTPURLResponse, (200...201).contains(http.statusCode) else {
            throw AzureError.uploadFailed(status: (resp as? HTTPURLResponse)?.statusCode ?? -1, path: blobPath)
        }
    }

    private func putBlockList(blobPath: String, blockIds: [String], blobContentMD5Base64: String) throws {
        var url = makeBlobURL(path: blobPath)
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let existing = comps.percentEncodedQuery.map { $0 + "&" } ?? ""
        comps.percentEncodedQuery = existing + "comp=blocklist"
        url = comps.url!
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(apiVersion, forHTTPHeaderField: "x-ms-version")
        // Set the MD5 for the committed blob so it can be verified via HEAD/GET later.
        req.setValue(blobContentMD5Base64, forHTTPHeaderField: "x-ms-blob-content-md5")
        req.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        let xml = """
        <?xml version=\"1.0\" encoding=\"utf-8\"?>
        <BlockList>
        """ + blockIds.map { "<Latest>\($0)</Latest>" }.joined(separator: "\n") + "\n</BlockList>"
        req.httpBody = xml.data(using: .utf8)
        let (resp, err) = performSync(request: req)
        if let err = err { throw err }
        guard let http = resp as? HTTPURLResponse, (200...201).contains(http.statusCode) else {
            throw AzureError.uploadFailed(status: (resp as? HTTPURLResponse)?.statusCode ?? -1, path: blobPath)
        }
    }

    // MARK: - Download
    public func download(to localURL: URL, blobPath: String) throws {
        var req = URLRequest(url: makeBlobURL(path: blobPath))
        req.httpMethod = "GET"
        req.setValue(apiVersion, forHTTPHeaderField: "x-ms-version")
        let (resp, err, data) = performSyncWithData(request: req)
        if let err = err { throw err }
        guard let http = resp as? HTTPURLResponse, (200...200).contains(http.statusCode) else {
            throw AzureError.downloadFailed(status: (resp as? HTTPURLResponse)?.statusCode ?? -1, path: blobPath)
        }
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data?.write(to: localURL)
    }

    // MARK: - List
    public struct ListResult { public let blobs: [String]; public let prefixes: [String] }

    public func list(prefix: String, delimiter: String? = nil) throws -> ListResult {
        // Build ?restype=container&comp=list&prefix=...&delimiter=/ (optional)
        var comps = URLComponents(url: containerSASURL, resolvingAgainstBaseURL: false)!
        var queryItems = comps.queryItems ?? []
        queryItems.append(URLQueryItem(name: "restype", value: "container"))
        queryItems.append(URLQueryItem(name: "comp", value: "list"))
        if !prefix.isEmpty { queryItems.append(URLQueryItem(name: "prefix", value: prefix)) }
        if let d = delimiter { queryItems.append(URLQueryItem(name: "delimiter", value: d)) }
        comps.queryItems = queryItems
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue(apiVersion, forHTTPHeaderField: "x-ms-version")
        let (resp, err, data) = performSyncWithData(request: req)
        if let err = err { throw err }
        guard let http = resp as? HTTPURLResponse, (200...200).contains(http.statusCode), let data = data else {
            throw AzureError.listFailed(status: (resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return parseListXML(data: data)
    }

    private func parseListXML(data: Data) -> ListResult {
        // Minimal XML parsing to extract <Name> under <Blob> and <BlobPrefix><Name>
        class Parser: NSObject, XMLParserDelegate {
            var blobs: [String] = []
            var prefixes: [String] = []
            var currentElement: String = ""
            var inBlob = false
            var inPrefix = false
            var buffer: String = ""
            func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
                currentElement = elementName
                if elementName == "Blob" { inBlob = true }
                if elementName == "BlobPrefix" { inPrefix = true }
                buffer = ""
            }
            func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }
            func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
                if elementName == "Name" {
                    let name = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if inBlob { blobs.append(name) }
                    if inPrefix { prefixes.append(name) }
                }
                if elementName == "Blob" { inBlob = false }
                if elementName == "BlobPrefix" { inPrefix = false }
                buffer = ""
            }
        }
        let p = Parser()
        let xp = XMLParser(data: data)
        xp.delegate = p
        xp.parse()
        return ListResult(blobs: p.blobs, prefixes: p.prefixes)
    }

    // MARK: - Delete
    public func delete(blobPath: String) throws {
        var req = URLRequest(url: makeBlobURL(path: blobPath))
        req.httpMethod = "DELETE"
        req.setValue(apiVersion, forHTTPHeaderField: "x-ms-version")
        let (resp, err) = performSync(request: req)
        if let err = err { throw err }
        guard let http = resp as? HTTPURLResponse, (200...202).contains(http.statusCode) else {
            throw AzureError.deleteFailed(status: (resp as? HTTPURLResponse)?.statusCode ?? -1, path: blobPath)
        }
    }

    // MARK: - Exists
    public func exists(blobPath: String) throws -> Bool {
        var req = URLRequest(url: makeBlobURL(path: blobPath))
        req.httpMethod = "HEAD"
        req.setValue(apiVersion, forHTTPHeaderField: "x-ms-version")
        let (resp, err) = performSync(request: req)
        if let err = err { throw err }
        guard let http = resp as? HTTPURLResponse else { return false }
        if http.statusCode == 200 { return true }
        if http.statusCode == 404 { return false }
        return false
    }

    // HEAD the blob and return response headers for verification.
    public func headMetadata(blobPath: String) throws -> HTTPURLResponse? {
        var req = URLRequest(url: makeBlobURL(path: blobPath))
        req.httpMethod = "HEAD"
        req.setValue(apiVersion, forHTTPHeaderField: "x-ms-version")
        let (resp, err) = performSync(request: req)
        if let err = err { throw err }
        return resp as? HTTPURLResponse
    }

    // MARK: - Helpers
    private func performSync(request: URLRequest) -> (URLResponse?, Error?) {
        let sem = DispatchSemaphore(value: 1)
        sem.wait()
        var response: URLResponse?
        var error: Error?
        let done = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { _, resp, err in
            response = resp
            error = err
            done.signal()
        }
        task.resume()
        done.wait()
        sem.signal()
        return (response, error)
    }

    private func performSyncWithData(request: URLRequest) -> (URLResponse?, Error?, Data?) {
        let sem = DispatchSemaphore(value: 1)
        sem.wait()
        var response: URLResponse?
        var error: Error?
        var dataOut: Data?
        let done = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, resp, err in
            dataOut = data
            response = resp
            error = err
            done.signal()
        }
        task.resume()
        done.wait()
        sem.signal()
        return (response, error, dataOut)
    }
}

public enum AzureError: Error, LocalizedError {
    case uploadFailed(status: Int, path: String)
    case downloadFailed(status: Int, path: String)
    case listFailed(status: Int)
    case deleteFailed(status: Int, path: String)
    case snapshotNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .uploadFailed(let status, let path):
            return "Azure upload failed (status \(status)) for \(path)"
        case .downloadFailed(let status, let path):
            return "Azure download failed (status \(status)) for \(path)"
        case .listFailed(let status):
            return "Azure list failed (status \(status))"
        case .deleteFailed(let status, let path):
            return "Azure delete failed (status \(status)) for \(path)"
        case .snapshotNotFound(let id):
            return "Azure snapshot not found: \(id)"
        }
    }
}

// MARK: - Cloud repository operations via Azure Blob
public extension BackupManager {
    // Compute file MD5 (base64) for verification
    static func fileMD5Base64(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        while true {
            let data = handle.readData(ofLength: 8 * 1024 * 1024)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        let digest = hasher.finalize()
        return Data(digest).base64EncodedString()
    }

    // Read Content-MD5 or x-ms-blob-content-md5 from Azure via HEAD
    private static func fetchBlobMD5Base64(client: AzureBlobClient, blobPath: String) throws -> String? {
        if let head = try client.headMetadata(blobPath: blobPath) {
            // Azure may return either header depending on API/version
            if let v = head.value(forHTTPHeaderField: "Content-MD5"), !v.isEmpty { return v }
            if let v = head.value(forHTTPHeaderField: "x-ms-blob-content-md5"), !v.isEmpty { return v }
        }
        return nil
    }
    /// Initialize a cloud repo by writing a config.json at the container root.
    func initAzureRepo(containerSASURL: URL) throws {
    Logger.shared.info("initAzureRepo", subsystem: "core.azure")
    let client = AzureBlobClient(containerSASURL: containerSASURL)
    // If already exists, do nothing (idempotent)
        let exists = (try? client.exists(blobPath: "config.json")) ?? false
    if exists { return }
        let cfg = RepoConfig(version: 1, createdAt: Date())
        let data = try JSON.encoder.encode(cfg)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bckp-config.json")
        try data.write(to: tmp, options: [.atomic])
        try client.uploadFile(localURL: tmp, toBlobPath: "config.json")
    }

    func ensureAzureRepoInitialized(_ containerSASURL: URL) throws {
        let client = AzureBlobClient(containerSASURL: containerSASURL)
        let ok = (try? client.exists(blobPath: "config.json")) ?? false
        if !ok { throw BackupError.repoNotInitialized(containerSASURL) }
    }

    /// Backup sources to Azure by staging into a sparse disk image, then uploading the image under snapshots/<id>/<id>.sparseimage and manifest.json alongside.
    func backupToAzure(sources: [URL], containerSASURL: URL, options: BackupOptions = BackupOptions(), progress: ((BackupProgress) -> Void)? = nil) throws -> Snapshot {
        try ensureAzureRepoInitialized(containerSASURL)
        let client = AzureBlobClient(containerSASURL: containerSASURL)
        let fm = FileManager.default
        let validSources = try sources.map { src -> URL in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue else { throw BackupError.notADirectory(src) }
            return src
        }

        let snapshotId = Self.makeSnapshotId()
    let basePrefix = "snapshots/\(snapshotId)"

        // Per-source .bckpignore
        struct SourceFilter { let include: [String]; let exclude: [String]; let reincludes: [String] }
        var perSource: [URL: SourceFilter] = [:]
        for src in validSources {
            let parsed = parseBckpIgnore(at: src.appendingPathComponent(".bckpignore"))
            let inc = parsed.includes.isEmpty ? options.include : parsed.includes
            let exc = parsed.excludes.isEmpty ? options.exclude : parsed.excludes
            perSource[src] = SourceFilter(include: inc, exclude: exc, reincludes: parsed.reincludes)
        }

    enum WorkKind { case file(size: Int64), symlink }
    struct WorkItem { let src: URL; let top: String; let relPath: String; let kind: WorkKind }

    var tasks: [WorkItem] = []
        var totalFiles = 0
        var totalBytes: Int64 = 0
        var symlinks: [String: String] = [:] // relPath -> destination

    // Plan tasks by enumerating sources; we'll size the sparse image based on totalBytes
        for src in validSources {
            let enumerator = fm.enumerator(at: src, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles])
            while let item = enumerator?.nextObject() as? URL {
                let rv = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                let relPath = Self.relativePath(of: item, under: src)
                let filter = perSource[src] ?? SourceFilter(include: options.include, exclude: options.exclude, reincludes: [])
                if rv.isDirectory == true {
                    if anyMatch(filter.exclude, path: relPath) && !anyMatch(filter.reincludes, path: relPath) {
                        enumerator?.skipDescendants()
                        continue
                    }
                    // no-op during planning
                } else if rv.isRegularFile == true {
                    if !Self.isIncluded(relPath: relPath, include: filter.include, exclude: filter.exclude, reincludes: filter.reincludes) { continue }
                    let size = Int64(rv.fileSize ?? 0)
                    tasks.append(WorkItem(src: item, top: src.lastPathComponent, relPath: relPath, kind: .file(size: size)))
                    totalFiles += 1
                    totalBytes += size
                } else if rv.isSymbolicLink == true {
                    if !Self.isIncluded(relPath: relPath, include: filter.include, exclude: filter.exclude, reincludes: filter.reincludes) { continue }
                    let dest = try fm.destinationOfSymbolicLink(atPath: item.path)
                    symlinks[relPath] = dest
                    tasks.append(WorkItem(src: item, top: src.lastPathComponent, relPath: relPath, kind: .symlink))
                }
            }
        }

        // Emit planning summary
        if let cb = progress {
            cb(BackupProgress(
                processedFiles: 0,
                totalFiles: totalFiles,
                processedBytes: 0,
                totalBytes: totalBytes,
                currentPath: "[plan] files=\(totalFiles) size=\(totalBytes)"
            ))
        }

    // Create and attach the sparse image sized with headroom; then stage the files under ~/Backups
    let home = FileManager.default.homeDirectoryForCurrentUser
    let backupsRoot = home.appendingPathComponent("Backups", isDirectory: true)
    try FileManager.default.createDirectory(at: backupsRoot, withIntermediateDirectories: true)
    let imageURL = backupsRoot.appendingPathComponent("bckp-\(snapshotId).sparseimage")
    let mountPoint = backupsRoot.appendingPathComponent("bckp-mount-\(snapshotId)", isDirectory: true)
    let headroomBytes = max(Int64(64 * 1024 * 1024), Int64(Double(totalBytes) * 0.5))
    var capacity = max(Int64(1 * 1024 * 1024), totalBytes + headroomBytes)
    let eightMiB: Int64 = 8 * 1024 * 1024
    capacity = ((capacity + eightMiB - 1) / eightMiB) * eightMiB
    let mib = (capacity + 1024 * 1024 - 1) / (1024 * 1024)
        let sizeArg = "\(mib)m"
        try DiskImage.createSparseImage(at: imageURL, size: sizeArg, volumeName: "bckp-\(snapshotId)")
        if let cb = progress {
            cb(BackupProgress(processedFiles: 0, totalFiles: totalFiles, processedBytes: 0, totalBytes: totalBytes, currentPath: "[disk] created sparse image \(imageURL.lastPathComponent) size=\(sizeArg)"))
        }
    let (device, _) = try DiskImage.attach(imageURL: imageURL, mountpoint: mountPoint)
        if let cb = progress {
            cb(BackupProgress(processedFiles: 0, totalFiles: totalFiles, processedBytes: 0, totalBytes: totalBytes, currentPath: "[disk] attached \(device) at \(mountPoint.path)"))
        }
    defer { try? DiskImage.detach(device: device, mountPoint: mountPoint) }
        let dataRoot = mountPoint.appendingPathComponent("data", isDirectory: true)
        try fm.createDirectory(at: dataRoot, withIntermediateDirectories: true)

        // Copy files into the mounted image with per-item progress
        // Emit a high-level stage line so CLI users see activity without file spam
        if let cb = progress {
            cb(BackupProgress(processedFiles: 0, totalFiles: totalFiles, processedBytes: 0, totalBytes: totalBytes, currentPath: "[data] copying data..."))
        }
        var processedFiles = 0
        var processedBytes: Int64 = 0
        for t in tasks {
            switch t.kind {
            case .file:
                let dst = dataRoot.appendingPathComponent(t.top, isDirectory: true).appendingPathComponent(t.relPath)
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: t.src, to: dst)
                // Update progress
                if let size = (try? t.src.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap({ Int64($0) }) {
                    processedFiles += 1
                    processedBytes += size
                } else {
                    processedFiles += 1
                }
                if let cb = progress {
                    cb(BackupProgress(processedFiles: processedFiles, totalFiles: totalFiles, processedBytes: processedBytes, totalBytes: totalBytes, currentPath: t.relPath))
                }
            case .symlink:
                let dst = dataRoot.appendingPathComponent(t.top, isDirectory: true).appendingPathComponent(t.relPath)
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                let dest = symlinks[t.relPath] ?? (try? fm.destinationOfSymbolicLink(atPath: t.src.path)) ?? ""
                if !dest.isEmpty {
                    try? fm.createSymbolicLink(atPath: dst.path, withDestinationPath: dest)
                }
                if let cb = progress {
                    cb(BackupProgress(processedFiles: processedFiles, totalFiles: totalFiles, processedBytes: processedBytes, totalBytes: totalBytes, currentPath: t.relPath))
                }
            }
        }
        // High-level stage completion
        if let cb = progress {
            cb(BackupProgress(processedFiles: processedFiles, totalFiles: totalFiles, processedBytes: processedBytes, totalBytes: totalBytes, currentPath: "[data] staging complete"))
        }

        // No per-file uploads: we staged locally into a sparse image; we'll upload it in one go below.

        // Write symlinks.json (if any) and manifest.json
        // Write manifest inside the mounted image, then detach and upload the sparse image
        let snapshot = Snapshot(id: snapshotId, createdAt: Date(), sources: validSources.map { $0.path }, totalFiles: totalFiles, totalBytes: totalBytes, relativePath: basePrefix)
        let manifestData = try JSON.encoder.encode(snapshot)
        let manifestURL = mountPoint.appendingPathComponent("manifest.json")
        try manifestData.write(to: manifestURL, options: [.atomic])
        // Ensure data is flushed by detaching before upload
        if let cb = progress { cb(BackupProgress(processedFiles: processedFiles, totalFiles: totalFiles, processedBytes: processedBytes, totalBytes: totalBytes, currentPath: "[disk] detaching")) }
        try DiskImage.detach(device: device, mountPoint: mountPoint)
        if let cb = progress { cb(BackupProgress(processedFiles: processedFiles, totalFiles: totalFiles, processedBytes: processedBytes, totalBytes: totalBytes, currentPath: "[disk] detached")) }
        // Compute MD5 (base64) for verification and emit progress line with checksum
        if let cb = progress { cb(BackupProgress(processedFiles: processedFiles, totalFiles: totalFiles, processedBytes: processedBytes, totalBytes: totalBytes, currentPath: "[hash] computing MD5")) }
        let md5Base64 = try Self.fileMD5Base64(of: imageURL)
        if let cb = progress {
            cb(BackupProgress(
                processedFiles: totalFiles,
                totalFiles: totalFiles,
                processedBytes: totalBytes,
                totalBytes: totalBytes,
                currentPath: "MD5 " + md5Base64
            ))
        }
        // Upload the sparse image
        if let cb = progress { cb(BackupProgress(processedFiles: processedFiles, totalFiles: totalFiles, processedBytes: processedBytes, totalBytes: totalBytes, currentPath: "[azure] upload start \(snapshotId).sparseimage")) }
        try client.uploadFile(localURL: imageURL, toBlobPath: basePrefix + "/\(snapshotId).sparseimage", progress: { msg in
            if let cb = progress {
                cb(BackupProgress(processedFiles: processedFiles, totalFiles: totalFiles, processedBytes: processedBytes, totalBytes: totalBytes, currentPath: "[azure] " + msg))
            }
        })
        if let cb = progress { cb(BackupProgress(processedFiles: processedFiles, totalFiles: totalFiles, processedBytes: processedBytes, totalBytes: totalBytes, currentPath: "[azure] upload done")) }
        // Verify: compare local MD5 (base64) with blob's Content-MD5/x-ms-blob-content-md5
        if let remoteMD5 = try? Self.fetchBlobMD5Base64(client: client, blobPath: basePrefix + "/\(snapshotId).sparseimage"), !remoteMD5.isEmpty {
            if remoteMD5 != md5Base64 { throw AzureError.uploadFailed(status: -1, path: basePrefix + "/\(snapshotId).sparseimage") }
        }
        if let cb = progress { cb(BackupProgress(processedFiles: processedFiles, totalFiles: totalFiles, processedBytes: processedBytes, totalBytes: totalBytes, currentPath: "[azure] verified MD5")) }
        // Cleanup local staging artifacts
        try? FileManager.default.removeItem(at: imageURL)
        if let cb = progress { cb(BackupProgress(processedFiles: processedFiles, totalFiles: totalFiles, processedBytes: processedBytes, totalBytes: totalBytes, currentPath: "[cleanup] removed local image")) }
        // Also upload manifest.json alongside for quick listing without mounting
        let tmpManifest = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bckp-manifest-\(snapshotId).json")
        try manifestData.write(to: tmpManifest, options: [.atomic])
        if let cb = progress { cb(BackupProgress(processedFiles: processedFiles, totalFiles: totalFiles, processedBytes: processedBytes, totalBytes: totalBytes, currentPath: "[azure] upload manifest.json")) }
        try client.uploadFile(localURL: tmpManifest, toBlobPath: basePrefix + "/manifest.json")
        // Optionally upload symlinks.json derived from the staging step
        if !symlinks.isEmpty {
            let data = try JSONSerialization.data(withJSONObject: symlinks, options: [.prettyPrinted, .sortedKeys])
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bckp-symlinks-\(snapshotId).json")
            try data.write(to: tmp, options: [.atomic])
            if let cb = progress { cb(BackupProgress(processedFiles: processedFiles, totalFiles: totalFiles, processedBytes: processedBytes, totalBytes: totalBytes, currentPath: "[azure] upload symlinks.json")) }
            try client.uploadFile(localURL: tmp, toBlobPath: basePrefix + "/symlinks.json")
        }
        Logger.shared.info("azure backup finished id=\(snapshotId) files=\(totalFiles) bytes=\(totalBytes)", subsystem: "core.azure")
        return snapshot
    }

    func listSnapshotsInAzure(containerSASURL: URL) throws -> [SnapshotListItem] {
        try ensureAzureRepoInitialized(containerSASURL)
        let client = AzureBlobClient(containerSASURL: containerSASURL)
        // Use delimiter to get prefixes one level under "snapshots/"
        let result = try client.list(prefix: "snapshots/", delimiter: "/")
        var items: [SnapshotListItem] = []
        for name in result.prefixes { // e.g. snapshots/<id>/
            guard name.hasPrefix("snapshots/") else { continue }
            let id = name.replacingOccurrences(of: "snapshots/", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            // Fetch manifest.json for each
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bckp-manifest-\(id).json")
            do {
                try client.download(to: tmp, blobPath: "snapshots/\(id)/manifest.json")
                let data = try Data(contentsOf: tmp)
                if let snap = try? JSON.decoder.decode(Snapshot.self, from: data) {
                    // Use full source paths in listings
                    items.append(SnapshotListItem(id: snap.id, createdAt: snap.createdAt, totalFiles: snap.totalFiles, totalBytes: snap.totalBytes, sources: snap.sources))
                }
            } catch {
                // Skip malformed snapshots
                continue
            }
        }
        return items.sorted { $0.createdAt < $1.createdAt }
    }

    func restoreFromAzure(snapshotId: String, containerSASURL: URL, to destination: URL, concurrency: Int? = nil) throws {
        try ensureAzureRepoInitialized(containerSASURL)
        let client = AzureBlobClient(containerSASURL: containerSASURL)
        // Check manifest exists
        let exists = (try? client.exists(blobPath: "snapshots/\(snapshotId)/manifest.json")) ?? false
    if !exists { Logger.shared.error("azure restore: manifest not found for id=\(snapshotId)", subsystem: "core.azure"); throw AzureError.snapshotNotFound(snapshotId) }

        // If an image exists, prefer mounting the image and copying locally. Otherwise, fall back to per-file download.
        let imageBlobPath = "snapshots/\(snapshotId)/\(snapshotId).sparseimage"
        if (try? client.exists(blobPath: imageBlobPath)) == true {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let backupsRoot = home.appendingPathComponent("Backups", isDirectory: true)
            try FileManager.default.createDirectory(at: backupsRoot, withIntermediateDirectories: true)
            let localImage = backupsRoot.appendingPathComponent("bckp-restore-\(snapshotId).sparseimage")
            try client.download(to: localImage, blobPath: imageBlobPath)
            // Attach and copy data/
            let mountPoint = backupsRoot.appendingPathComponent("bckp-restore-mount-\(snapshotId)", isDirectory: true)
            let (dev, _) = try DiskImage.attach(imageURL: localImage, mountpoint: mountPoint)
            defer {
                try? DiskImage.detach(device: dev, mountPoint: mountPoint)
                try? FileManager.default.removeItem(at: localImage)
            }
            let dataRoot = mountPoint.appendingPathComponent("data", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let enumerator = FileManager.default.enumerator(at: dataRoot, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: [])
            while let item = enumerator?.nextObject() as? URL {
                let rel = BackupManager.relativePath(of: item, under: dataRoot)
                let out = destination.appendingPathComponent(rel)
                let rv = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                if rv.isDirectory == true {
                    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                } else if rv.isRegularFile == true {
                    try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: out.path) { try? FileManager.default.removeItem(at: out) }
                    try FileManager.default.copyItem(at: item, to: out)
                } else if rv.isSymbolicLink == true {
                    try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: out.path) { try? FileManager.default.removeItem(at: out) }
                    let dest = try FileManager.default.destinationOfSymbolicLink(atPath: item.path)
                    try? FileManager.default.createSymbolicLink(atPath: out.path, withDestinationPath: dest)
                }
            }
        } else {
            // Download all blobs under data prefix (legacy layout)
            let dataPrefix = "snapshots/\(snapshotId)/data/"
            let list = try client.list(prefix: dataPrefix, delimiter: nil)
            let blobs = list.blobs // full names including prefix
            // Concurrently download
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = max(1, concurrency ?? ProcessInfo.processInfo.activeProcessorCount)
            queue.qualityOfService = .userInitiated
            var firstError: Error?
            for b in blobs {
                // Compute local path relative to dataPrefix
                guard b.hasPrefix(dataPrefix) else { continue }
                let rel = String(b.dropFirst(dataPrefix.count))
                let local = destination.appendingPathComponent(rel)
                queue.addOperation {
                    do { try client.download(to: local, blobPath: b) } catch { if firstError == nil { firstError = error } }
                }
            }
            queue.waitUntilAllOperationsAreFinished()
            if let err = firstError { Logger.shared.error("azure restore failed: \(err)", subsystem: "core.azure"); throw err }
        }

        // Recreate symlinks if symlinks.json exists
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bckp-symlinks-\(snapshotId).json")
        if (try? client.exists(blobPath: "snapshots/\(snapshotId)/symlinks.json")) == true {
            try client.download(to: tmp, blobPath: "snapshots/\(snapshotId)/symlinks.json")
            if let dict = try JSONSerialization.jsonObject(with: Data(contentsOf: tmp)) as? [String: String] {
                for (rel, dest) in dict {
                    let linkURL = destination.appendingPathComponent(rel)
                    let parent = linkURL.deletingLastPathComponent()
                    try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: linkURL.path) {
                        try? FileManager.default.removeItem(at: linkURL)
                    }
                    try? FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: dest)
                }
            }
        }
        Logger.shared.info("azure restore finished id=\(snapshotId) to=\(destination.path)", subsystem: "core.azure")
    }

    func pruneInAzure(containerSASURL: URL, policy: PrunePolicy) throws -> PruneResult {
        let items = try listSnapshotsInAzure(containerSASURL: containerSASURL) // ascending by date
        if items.isEmpty { return PruneResult(deleted: [], kept: []) }

        var keep = Set<String>()
        if let n = policy.keepLast, n > 0 { for it in items.suffix(n) { keep.insert(it.id) } }
        if let d = policy.keepDays, d > 0 {
            let cutoff = Date().addingTimeInterval(-TimeInterval(d * 24 * 60 * 60))
            for it in items where it.createdAt >= cutoff { keep.insert(it.id) }
        }
        if keep.isEmpty, let newest = items.last { keep.insert(newest.id) }

        let client = AzureBlobClient(containerSASURL: containerSASURL)
        var deleted: [String] = []
        var kept: [String] = []
        for it in items {
            if keep.contains(it.id) { kept.append(it.id); continue }
            // Delete all blobs under snapshots/<id>/ by listing prefix and deleting each
            let prefix = "snapshots/\(it.id)/"
            let list = try client.list(prefix: prefix, delimiter: nil)
            for b in list.blobs { try? client.delete(blobPath: b) }
            deleted.append(it.id)
        }
    Logger.shared.info("azure prune finished deleted=\(deleted.count) kept=\(kept.count)", subsystem: "core.azure")
    return PruneResult(deleted: deleted, kept: kept)
    }
}
