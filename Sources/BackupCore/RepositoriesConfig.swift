import Foundation

// MARK: - Models
public struct RepositoriesConfig: Codable {
    public var repositories: [String: RepositoryInfo]
    public init(repositories: [String: RepositoryInfo] = [:]) { self.repositories = repositories }
}

public struct RepositoryInfo: Codable {
    public var lastUsedAt: Date?
    public var sources: [RepoSourceInfo]
    public init(lastUsedAt: Date? = nil, sources: [RepoSourceInfo] = []) {
        self.lastUsedAt = lastUsedAt
        self.sources = sources
    }
}

public struct RepoSourceInfo: Codable, Equatable {
    public var path: String
    public var lastBackupAt: Date?
    public init(path: String, lastBackupAt: Date? = nil) {
        self.path = path
        self.lastBackupAt = lastBackupAt
    }
}

// MARK: - Store
public final class RepositoriesConfigStore {
    public static let shared = RepositoriesConfigStore()

    private let ioQueue = DispatchQueue(label: "bckp.repositories.config.io")
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private(set) public var config: RepositoriesConfig

    private init() {
        let url = Self.fileURL()
        if let data = try? Data(contentsOf: url), let cfg = try? decoder.decode(RepositoriesConfig.self, from: data) {
            self.config = cfg
        } else {
            self.config = RepositoriesConfig()
            persist()
        }
    }

    // MARK: Public API
    public func recordRepoUsedLocal(repoURL: URL, when: Date = Date()) {
        let key = Self.keyForLocal(repoURL)
        update { cfg in
            var info = cfg.repositories[key] ?? RepositoryInfo()
            info.lastUsedAt = when
            cfg.repositories[key] = info
        }
    }

    public func recordRepoUsedAzure(containerSASURL: URL, when: Date = Date()) {
        let key = Self.keyForAzure(containerSASURL)
        update { cfg in
            var info = cfg.repositories[key] ?? RepositoryInfo()
            info.lastUsedAt = when
            cfg.repositories[key] = info
        }
    }

    public func updateConfiguredSourcesLocal(repoURL: URL, sources: [URL]) {
        let key = Self.keyForLocal(repoURL)
        update { cfg in
            var info = cfg.repositories[key] ?? RepositoryInfo()
            var existing = info.sources
            let paths = sources.map { $0.standardizedFileURL.path }
            for p in paths where !existing.contains(where: { $0.path == p }) {
                existing.append(RepoSourceInfo(path: p, lastBackupAt: nil))
            }
            info.sources = existing
            cfg.repositories[key] = info
        }
    }

    public func updateConfiguredSourcesAzure(containerSASURL: URL, sources: [URL]) {
        let key = Self.keyForAzure(containerSASURL)
        update { cfg in
            var info = cfg.repositories[key] ?? RepositoryInfo()
            var existing = info.sources
            let paths = sources.map { $0.standardizedFileURL.path }
            for p in paths where !existing.contains(where: { $0.path == p }) {
                existing.append(RepoSourceInfo(path: p, lastBackupAt: nil))
            }
            info.sources = existing
            cfg.repositories[key] = info
        }
    }

    public func recordBackupLocal(repoURL: URL, sourcePaths: [URL], when: Date = Date()) {
        let key = Self.keyForLocal(repoURL)
        update { cfg in
            var info = cfg.repositories[key] ?? RepositoryInfo()
            info.lastUsedAt = when
            var map: [String: RepoSourceInfo] = Dictionary(uniqueKeysWithValues: info.sources.map { ($0.path, $0) })
            for url in sourcePaths {
                let p = url.standardizedFileURL.path
                if var existing = map[p] { existing.lastBackupAt = when; map[p] = existing }
                else { map[p] = RepoSourceInfo(path: p, lastBackupAt: when) }
            }
            info.sources = Array(map.values).sorted { $0.path < $1.path }
            cfg.repositories[key] = info
        }
    }

    public func recordBackupAzure(containerSASURL: URL, sourcePaths: [URL], when: Date = Date()) {
        let key = Self.keyForAzure(containerSASURL)
        update { cfg in
            var info = cfg.repositories[key] ?? RepositoryInfo()
            info.lastUsedAt = when
            var map: [String: RepoSourceInfo] = Dictionary(uniqueKeysWithValues: info.sources.map { ($0.path, $0) })
            for url in sourcePaths {
                let p = url.standardizedFileURL.path
                if var existing = map[p] { existing.lastBackupAt = when; map[p] = existing }
                else { map[p] = RepoSourceInfo(path: p, lastBackupAt: when) }
            }
            info.sources = Array(map.values).sorted { $0.path < $1.path }
            cfg.repositories[key] = info
        }
    }

    // MARK: - Helpers
    private func update(_ mutate: (inout RepositoriesConfig) -> Void) {
        ioQueue.sync {
            var cfg = self.config
            mutate(&cfg)
            self.config = cfg
            persist()
        }
    }

    private func persist() {
        let url = Self.fileURL()
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? encoder.encode(config) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    // MARK: - Locations/Keys
    static func fileURL() -> URL {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        #else
        let base = URL(fileURLWithPath: NSHomeDirectory())
        #endif
        let dir = base.appendingPathComponent("bckp", isDirectory: true)
        return dir.appendingPathComponent("repositories.json")
    }

    public static func keyForLocal(_ repoURL: URL) -> String {
        repoURL.standardizedFileURL.path
    }

    public static func keyForAzure(_ containerSASURL: URL) -> String {
        var comps = URLComponents(url: containerSASURL, resolvingAgainstBaseURL: false)
        comps?.query = nil
        comps?.fragment = nil
        return comps?.url?.absoluteString ?? containerSASURL.absoluteString
    }
}

private extension URL {
    func deletingQueryAndFragment() -> URL {
        var comps = URLComponents(url: self, resolvingAgainstBaseURL: false)
        comps?.query = nil
        comps?.fragment = nil
        return comps?.url ?? self
    }
}
