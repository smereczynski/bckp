import Foundation

// MARK: - Custom errors
// We define a small set of errors so we can print friendly messages in the CLI.
// LocalizedError gives us user-facing strings via `errorDescription`.
enum BackupError: Error, LocalizedError {
    case notADirectory(URL)
    case repoAlreadyExists(URL)
    case repoNotInitialized(URL)
    case snapshotNotFound(String)
    case copyFailed(URL, URL, Error)

    var errorDescription: String? {
        switch self {
        case .notADirectory(let url):
            return "Not a directory: \(url.path)"
        case .repoAlreadyExists(let url):
            return "Repository already exists at: \(url.path)"
        case .repoNotInitialized(let url):
            return "Repository not initialized at: \(url.path)"
        case .snapshotNotFound(let id):
            return "Snapshot not found: \(id)"
        case .copyFailed(let src, let dst, let err):
            return "Failed to copy \(src.path) to \(dst.path): \(err.localizedDescription)"
        }
    }
}

// Small convenience to check if a URL points to a directory on disk.
extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}

// Convert a number of bytes to a readable string, like "1.2 MB".
public extension ByteCountFormatter {
    static func string(fromBytes bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

// Handy JSON encoder/decoder with ISO 8601 dates.
struct JSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

// MARK: - Disk Identification (macOS)
#if os(macOS)
public struct DiskIdentity: Codable, Equatable {
    // e.g., disk2s1 (intentionally not resolved in this lightweight impl)
    public let deviceBSDName: String?
    // Stable volume UUID (if the system exposes it). Used to construct stable repo keys for external volumes.
    public let volumeUUID: String?         // UUID string of the volume
    // Mounted volume URL (mount point)
    public let volumeURL: URL
    public let isExternal: Bool
}

/// Resolve the mounted volume URL that contains the given path.
private func volumeURL(containing path: URL) -> URL? {
    let fm = FileManager.default
    guard let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeURLKey], options: []) else { return nil }
    let std = path.standardizedFileURL
    // Pick the longest matching volume mount point prefix
    let matches = volumes.filter { std.path.hasPrefix($0.path) }
    return matches.sorted { $0.path.count > $1.path.count }.first
}

/// Returns true if the volume at URL is external (removable or external drive).
/// Heuristics: removable flag OR mounted under /Volumes/.
private func isExternalVolume(_ vol: URL) -> Bool {
    let vals = try? vol.resourceValues(forKeys: [.volumeIsRemovableKey, .volumeURLKey, .volumeUUIDStringKey])
    if let removable = vals?.volumeIsRemovable, removable { return true }
    // Heuristic: external volumes are typically mounted under /Volumes/<Name>
    if vol.path.hasPrefix("/Volumes/") { return true }
    return false
}

/// Load the Volume UUID using URL resource values when possible.
/// If not available, returns nil and callers fall back to path-based keys.
private func volumeUUIDString(_ vol: URL) -> String? {
    if let vals = try? vol.resourceValues(forKeys: [.volumeUUIDStringKey]), let uuid = vals.volumeUUIDString {
        return uuid
    }
    return nil
}

/// Resolve the BSD device name for a mounted volume using IOKit.
/// Not implemented in this version; left as a placeholder for future enrichment.
private func bsdNameForVolume(_ vol: URL) -> String? { nil }

/// Identify the disk containing the provided path. Returns volume UUID, mount URL and whether it's external.
public func identifyDisk(forPath path: URL) -> DiskIdentity? {
    guard let vol = volumeURL(containing: path) else { return nil }
    let external = isExternalVolume(vol)
    let uuid = volumeUUIDString(vol)
    let bsd = bsdNameForVolume(vol)
    return DiskIdentity(deviceBSDName: bsd, volumeUUID: uuid, volumeURL: vol, isExternal: external)
}

/// Convenience: true if the given path resides on an external/removable volume.
public func pathIsOnExternalVolume(_ path: URL) -> Bool {
    guard let vol = volumeURL(containing: path) else { return false }
    return isExternalVolume(vol)
}

/// List identities of all currently mounted external volumes.
/// Used by the CLI (drives) and the GUI external-drive picker on macOS.
public func listExternalDiskIdentities() -> [DiskIdentity] {
    let fm = FileManager.default
    guard let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey, .volumeIsRemovableKey], options: []) else { return [] }
    return volumes.compactMap { vol in
        let ext = isExternalVolume(vol)
        guard ext else { return nil }
        let uuid = volumeUUIDString(vol)
        let bsd = bsdNameForVolume(vol)
        return DiskIdentity(deviceBSDName: bsd, volumeUUID: uuid, volumeURL: vol, isExternal: true)
    }
}
#endif

// MARK: - Glob Match
// A tiny glob matcher supporting '*', '**' across path components.
// For simplicity we translate to a regular expression and test full-string matches.
struct GlobMatcher {
    private let regex: NSRegularExpression

    init(_ pattern: String) {
        // Normalize path separators and escape regex special chars except our wildcards
        let esc = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*\\*", with: "__GLOB_DBL__")
            .replacingOccurrences(of: "\\*", with: "__GLOB_ONE__")

        // '**' => match any path (including '/')
        // '*'  => match any chars except '/'
        let re = "^" + esc
            .replacingOccurrences(of: "__GLOB_DBL__", with: ".*")
            .replacingOccurrences(of: "__GLOB_ONE__", with: "[^/]*") + "$"

        self.regex = try! NSRegularExpression(pattern: re)
    }

    func matches(_ path: String) -> Bool {
        let range = NSRange(location: 0, length: path.utf16.count)
        return regex.firstMatch(in: path, range: range) != nil
    }
}

// Returns true if any of the glob patterns matches the given path.
func anyMatch(_ patterns: [String], path: String) -> Bool {
    for p in patterns {
        if GlobMatcher(p).matches(path) { return true }
    }
    return false
}

// MARK: - .bckpignore parsing
// Simple parser for .bckpignore files.
// Rules:
// - Lines starting with '#' are comments
// - Blank lines are ignored
// - Lines starting with '!' are re-includes (override excludes)
// - All patterns are glob patterns relative to the source root
// Note: This is a simplified implementation and does not fully emulate .gitignore directory un-skipping semantics.
func parseBckpIgnore(at url: URL) -> (includes: [String], excludes: [String], reincludes: [String]) {
    guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
        return ([], [], [])
    }
    var includes: [String] = []
    var excludes: [String] = []
    var reincludes: [String] = []
    for rawLine in text.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        if line.hasPrefix("!") {
            let pat = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            if !pat.isEmpty { reincludes.append(pat) }
        } else if line.hasPrefix("include ") || line.hasPrefix("include:") {
            // Optional directive style: include: pattern
            if let idx = line.firstIndex(of: ":") ?? line.firstIndex(of: " ") {
                let pat = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                if !pat.isEmpty { includes.append(pat) }
            }
        } else if line.hasPrefix("exclude ") || line.hasPrefix("exclude:") {
            // Optional directive style: exclude: pattern
            if let idx = line.firstIndex(of: ":") ?? line.firstIndex(of: " ") {
                let pat = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                if !pat.isEmpty { excludes.append(pat) }
            }
        } else {
            excludes.append(line)
        }
    }
    return (includes, excludes, reincludes)
}
