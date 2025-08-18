import Foundation

// MARK: - AppConfig
// Simple INI-like config with sections and key=value pairs. Lines starting with '#' are comments.
// Example:
// [repo]
// path = /Users/me/Backups/bckp
// [backup]
// include = **/*
// exclude = **/.git/**,**/node_modules/**
// concurrency = 8
// [azure]
// sas = https://acct.blob.core.windows.net/container?sv=...&sig=...

public struct AppConfig: Equatable {
    public var repoPath: String?
    public var include: [String] = []
    public var exclude: [String] = []
    public var concurrency: Int?
    public var azureSAS: String?
    // Logging
    // If true, enables debug-level logging. Defaults to false when omitted.
    public var loggingDebug: Bool?

    public init(repoPath: String? = nil, include: [String] = [], exclude: [String] = [], concurrency: Int? = nil, azureSAS: String? = nil, loggingDebug: Bool? = nil) {
        self.repoPath = repoPath
        self.include = include
        self.exclude = exclude
        self.concurrency = concurrency
        self.azureSAS = azureSAS
        self.loggingDebug = loggingDebug
    }

    // Default config file locations
    public static var defaultRepoConfigURL: URL {
        // Prefer a config in the default local repo, else ~/.config/bckp/config
        let local = BackupManager.defaultRepoURL.deletingLastPathComponent().appendingPathComponent("bckp.config")
        if FileManager.default.fileExists(atPath: local.path) { return local }
        let cfgDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/bckp", isDirectory: true)
        return cfgDir.appendingPathComponent("config")
    }
}

// MARK: - Parsing/Writing
public enum AppConfigIO {
    public static func load(from url: URL) -> AppConfig {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return AppConfig()
        }
        var section = ""
        var table: [String: [String: String]] = [:]
        func set(_ key: String, _ val: String) {
            var sec = table[section, default: [:]]
            sec[key] = val
            table[section] = sec
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).lowercased()
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                set(parts[0].lowercased(), parts[1])
            }
        }
        var cfg = AppConfig()
        if let repo = table["repo"]?["path"], !repo.isEmpty { cfg.repoPath = repo }
        if let inc = table["backup"]?["include"], !inc.isEmpty { cfg.include = inc.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        if let exc = table["backup"]?["exclude"], !exc.isEmpty { cfg.exclude = exc.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        if let conc = table["backup"]?["concurrency"], let n = Int(conc) { cfg.concurrency = n }
        if let sas = table["azure"]?["sas"], !sas.isEmpty { cfg.azureSAS = sas }
        if let dbg = table["logging"]?["debug"] {
            let v = dbg.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            cfg.loggingDebug = (v == "1" || v == "true" || v == "yes" || v == "on")
        }
        return cfg
    }

    public static func save(_ cfg: AppConfig, to url: URL) throws {
        var lines: [String] = []
        lines.append("# bckp configuration file")
        lines.append("# Lines starting with '#' are comments.")
        lines.append("")
        lines.append("[repo]")
        lines.append("# Local repository root path")
        lines.append("path = \(cfg.repoPath ?? BackupManager.defaultRepoURL.path)")
        lines.append("")
        lines.append("[backup]")
        lines.append("# Comma-separated include patterns (glob)")
        lines.append("include = \(cfg.include.joined(separator: ", "))")
        lines.append("# Comma-separated exclude patterns (glob)")
        lines.append("exclude = \(cfg.exclude.joined(separator: ", "))")
        lines.append("# Max concurrent operations (omit or 0 for default)")
        lines.append("concurrency = \(cfg.concurrency ?? 0)")
        lines.append("")
        lines.append("[azure]")
        lines.append("# Azure Blob Storage container SAS URL")
        lines.append("sas = \(cfg.azureSAS ?? "")")
    lines.append("")
    lines.append("[logging]")
    lines.append("# Enable debug-level logging (true/false)")
    lines.append("debug = \(cfg.loggingDebug == true ? "true" : "false")")
        let text = lines.joined(separator: "\n") + "\n"
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.data(using: .utf8)!.write(to: url, options: Data.WritingOptions.atomic)
    }
}
