import Foundation

public struct RepoSourceInfo: Codable, Equatable {
    public var path: String
    public var lastBackupAt: Date?
}

public struct RepoInfo: Codable, Equatable {
    public var key: String // unique key: local path or azure container URL sans query
    public var type: String // "local" | "azure"
    public var displayName: String?
    public var lastUsedAt: Date?
    public var sources: [RepoSourceInfo]
}

public struct RepositoriesConfig: Codable, Equatable {
    public var version: Int = 1
    public var repositories: [RepoInfo] = []
}

public final class RepositoriesConfigStore {
    public static let shared = RepositoriesConfigStore()

    private let queue = DispatchQueue(label: "bckp.repositories.config.store")
    private var config: RepositoriesConfig
    private let fileURL: URL

    private init() {
        let fm = FileManager.default
        #if os(macOS)
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        #else
        let base = URL(fileURLWithPath: NSHomeDirectory())
        #endif
        let dir = base.appendingPathComponent("bckp", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("repositories.json")
        if let data = try? Data(contentsOf: fileURL), let decoded = try? JSON.decoder.decode(RepositoriesConfig.self, from: data) {
            self.config = decoded
        } else {
            self.config = RepositoriesConfig()
            self.persist()
        }
    }

    // MARK: - Public helpers
    public func recordRepoUsedLocal(repoPath: String, when: Date = Date()) {
        let key = Self.keyForLocal(path: repoPath)
        queue.sync { upsertRepo(key: key, type: "local") { repo in repo.lastUsedAt = when } }
    }

    public func recordBackupLocal(repoPath: String, sources: [URL], when: Date = Date()) {
        let key = Self.keyForLocal(path: repoPath)
        queue.sync {
            upsertRepo(key: key, type: "local") { repo in
                repo.lastUsedAt = when
                for s in sources.map({ $0.path }) { upsertSource(into: &repo.sources, path: s) { $0.lastBackupAt = when } }
            }
        }
    }

    public func updateConfiguredSourcesLocal(repoPath: String, sources: [String]) {
        let key = Self.keyForLocal(path: repoPath)
        queue.sync {
            upsertRepo(key: key, type: "local") { repo in
                // Ensure all provided sources exist in repo.sources, preserve existing lastBackupAt
                var map = Dictionary(uniqueKeysWithValues: repo.sources.map { ($0.path, $0) })
                for p in sources { if map[p] == nil { map[p] = RepoSourceInfo(path: p, lastBackupAt: nil) } }
                repo.sources = Array(map.values).sorted { $0.path < $1.path }
                repo.lastUsedAt = Date()
            }
        }
    }

    public func recordRepoUsedAzure(containerSASURL: URL, when: Date = Date()) {
        let key = Self.keyForAzure(containerSASURL: containerSASURL)
        queue.sync { upsertRepo(key: key, type: "azure") { $0.lastUsedAt = when } }
    }

    public func recordBackupAzure(containerSASURL: URL, sources: [URL], when: Date = Date()) {
        let key = Self.keyForAzure(containerSASURL: containerSASURL)
        queue.sync {
            upsertRepo(key: key, type: "azure") { repo in
                repo.lastUsedAt = when
                for s in sources.map({ $0.path }) { upsertSource(into: &repo.sources, path: s) { $0.lastBackupAt = when } }
            }
        }
    }

    // MARK: - Internal helpers
    private func upsertRepo(key: String, type: String, update: (inout RepoInfo) -> Void) {
        if let idx = config.repositories.firstIndex(where: { $0.key == key }) {
            var repo = config.repositories[idx]
            update(&repo)
            config.repositories[idx] = repo
        } else {
            var repo = RepoInfo(key: key, type: type, displayName: nil, lastUsedAt: nil, sources: [])
            update(&repo)
            config.repositories.append(repo)
        }
        persist()
    }

    private func upsertSource(into sources: inout [RepoSourceInfo], path: String, update: (inout RepoSourceInfo) -> Void) {
        if let idx = sources.firstIndex(where: { $0.path == path }) {
            var s = sources[idx]; update(&s); sources[idx] = s
        } else {
            var s = RepoSourceInfo(path: path, lastBackupAt: nil); update(&s); sources.append(s)
        }
    }

    private func persist() {
        if let data = try? JSON.encoder.encode(config) { try? data.write(to: fileURL, options: [.atomic]) }
    }

    // Keys
    public static func keyForLocal(path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
    public static func keyForAzure(containerSASURL: URL) -> String {
        var comps = URLComponents(url: containerSASURL, resolvingAgainstBaseURL: false)
        comps?.query = nil
        return comps?.url?.absoluteString ?? containerSASURL.absoluteString
    }
}
