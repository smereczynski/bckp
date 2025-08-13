import Foundation

// MARK: - CloudProvider abstraction
public protocol CloudProvider {
    // Initialize remote repo (write config etc.)
    func initRepo() throws
    // Upload snapshot from local sources, return created Snapshot
    func backup(sources: [URL], options: BackupOptions, progress: ((BackupProgress) -> Void)?) throws -> Snapshot
    // List snapshot items
    func listSnapshots() throws -> [SnapshotListItem]
    // Restore snapshot to destination
    func restore(snapshotId: String, to destination: URL, concurrency: Int?) throws
    // Prune snapshots with policy
    func prune(policy: PrunePolicy) throws -> PruneResult
}

public struct AzureBlobProvider: CloudProvider {
    let sasURL: URL
    let manager: BackupManager

    public init(sasURL: URL, manager: BackupManager = BackupManager()) {
        self.sasURL = sasURL
        self.manager = manager
    }

    public func initRepo() throws { try manager.initAzureRepo(containerSASURL: sasURL) }

    public func backup(sources: [URL], options: BackupOptions, progress: ((BackupProgress) -> Void)?) throws -> Snapshot {
        try manager.backupToAzure(sources: sources, containerSASURL: sasURL, options: options, progress: progress)
    }

    public func listSnapshots() throws -> [SnapshotListItem] {
        try manager.listSnapshotsInAzure(containerSASURL: sasURL)
    }

    public func restore(snapshotId: String, to destination: URL, concurrency: Int?) throws {
        try manager.restoreFromAzure(snapshotId: snapshotId, containerSASURL: sasURL, to: destination, concurrency: concurrency)
    }

    public func prune(policy: PrunePolicy) throws -> PruneResult {
        try manager.pruneInAzure(containerSASURL: sasURL, policy: policy)
    }
}
