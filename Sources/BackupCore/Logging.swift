import Foundation

// MARK: - Logging

public enum LogLevel: String, Codable, Comparable {
    case error
    case warning
    case info
    case debug
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        func rank(_ l: LogLevel) -> Int {
            switch l { case .error: return 0; case .warning: return 1; case .info: return 2; case .debug: return 3 }
        }
        return rank(lhs) < rank(rhs)
    }
}

public struct LogEntry: Codable {
    public let timestamp: Date
    public let level: LogLevel
    public let subsystem: String
    public let message: String
    public let context: [String: String]?
}

public protocol LogSink {
    func write(_ entry: LogEntry)
}

/// Default sink writing NDJSON (one JSON per line) to macOS-native logs directory.
public final class FileLogSink: LogSink {
    private let directory: URL
    private let queue = DispatchQueue(label: "bckp.logger.file")
    private let enc: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileLogSink.defaultLogsDirectory()
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public static func defaultLogsDirectory() -> URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        return lib.appendingPathComponent("Logs", isDirectory: true).appendingPathComponent("bckp", isDirectory: true)
    }

    private func fileURL(for date: Date) -> URL {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let day = fmt.string(from: date)
        return directory.appendingPathComponent("bckp-\(day).log")
    }

    public func write(_ entry: LogEntry) {
        queue.async {
            let url = self.fileURL(for: entry.timestamp)
            if let data = try? self.enc.encode(entry), var line = String(data: data, encoding: .utf8) {
                line.append("\n")
                if let d = line.data(using: .utf8) {
                    if FileManager.default.fileExists(atPath: url.path) {
                        if let h = try? FileHandle(forWritingTo: url) {
                            defer { try? h.close() }
                            do { try h.seekToEnd(); try h.write(contentsOf: d) } catch { /* ignore file write errors */ }
                        }
                    } else {
                        try? d.write(to: url, options: [.atomic])
                    }
                }
            }
        }
    }
}

/// Central logger with pluggable sinks (similar to NLog-style targets).
public final class Logger {
    public static let shared = Logger()

    private var sinks: [LogSink] = []
    private var minLevel: LogLevel = .info
    private let lock = NSLock()

    private init() {
        // Default sink: file-based NDJSON in ~/Library/Logs/bckp
        sinks = [FileLogSink()]
        // Best-effort: read default config to toggle debug level
        let cfg = AppConfigIO.load(from: AppConfig.defaultRepoConfigURL)
        if (cfg.loggingDebug ?? false) { minLevel = .debug }
    }

    public func setDebugEnabled(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        minLevel = enabled ? .debug : .info
    }

    public func addSink(_ sink: LogSink) {
        lock.lock(); defer { lock.unlock() }
        sinks.append(sink)
    }

    public func replaceSinks(_ newSinks: [LogSink]) {
        lock.lock(); defer { lock.unlock() }
        sinks = newSinks
    }

    public func log(_ level: LogLevel, subsystem: String, _ message: String, context: [String: String]? = nil) {
        lock.lock(); let allow = level <= minLevel; let targets = sinks; lock.unlock()
        guard allow else { return }
        let entry = LogEntry(timestamp: Date(), level: level, subsystem: subsystem, message: message, context: context)
        for s in targets { s.write(entry) }
    }

    public func error(_ message: String, subsystem: String = "core", context: [String: String]? = nil) { log(.error, subsystem: subsystem, message, context: context) }
    public func warning(_ message: String, subsystem: String = "core", context: [String: String]? = nil) { log(.warning, subsystem: subsystem, message, context: context) }
    public func info(_ message: String, subsystem: String = "core", context: [String: String]? = nil) { log(.info, subsystem: subsystem, message, context: context) }
    public func debug(_ message: String, subsystem: String = "core", context: [String: String]? = nil) { log(.debug, subsystem: subsystem, message, context: context) }

    // For future CLI/GUI log viewers
    public static func defaultLogsDirectory() -> URL { FileLogSink.defaultLogsDirectory() }
}
