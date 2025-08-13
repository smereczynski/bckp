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
