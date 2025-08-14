import Foundation

// MARK: - Data models used by the backup engine
// These are small, plain Swift types that describe the data we store on disk.
// Codable means they can be saved to / loaded from JSON easily.

/// A full description of one backup snapshot (one run of "backup").
public struct Snapshot: Codable, Equatable {
    /// Unique ID created for the snapshot (used as folder name under snapshots/)
    public let id: String
    /// When the snapshot was created
    public let createdAt: Date
    /// Absolute paths of all source folders included in this snapshot
    public let sources: [String]
    /// How many regular files were copied (directories are not counted)
    public let totalFiles: Int
    /// Sum of sizes of all copied files (in bytes)
    public let totalBytes: Int64
    /// Relative path from the repository root to this snapshot's folder
    public let relativePath: String
}

/// A lighter version of Snapshot used for listings.
public struct SnapshotListItem: Codable, Equatable {
    public let id: String
    public let createdAt: Date
    public let totalFiles: Int
    public let totalBytes: Int64
    /// Full source paths included in this snapshot (not just lastPathComponent labels)
    public let sources: [String]
}

/// Repository configuration saved at the root of the backup repo.
public struct RepoConfig: Codable, Equatable {
    /// Schema version for future upgrades/migrations
    public var version: Int
    /// When the repository was initialized
    public var createdAt: Date
}

// MARK: - Options

/// Options that control what gets included in a backup.
/// Think of this as a "configuration struct" that you pass into the engine.
public struct BackupOptions: Equatable {
    /// Glob patterns (relative to each source root) that must match for a file to be included.
    /// If empty, all files are considered (subject to excludes).
    public var include: [String]
    /// Glob patterns (relative to each source root) that, if matched, will exclude a path.
    public var exclude: [String]
    /// Max number of concurrent copy operations. If nil, we use the machine's CPU count.
    public var concurrency: Int?

    public init(include: [String] = [], exclude: [String] = [], concurrency: Int? = nil) {
        self.include = include
        self.exclude = exclude
        self.concurrency = concurrency
    }
}

/// Progress information emitted during backup.
/// This lets the caller (CLI or SwiftUI app) render a progress bar.
public struct BackupProgress: Equatable {
    /// Number of files copied so far.
    public let processedFiles: Int
    /// Total number of files to copy (may be 0 if nothing matched).
    public let totalFiles: Int
    /// Bytes copied so far.
    public let processedBytes: Int64
    /// Total bytes to copy (sum of matched files' sizes).
    public let totalBytes: Int64
    /// The relative path of the file or symlink currently being processed (if available).
    public let currentPath: String?
}

// MARK: - Prune
/// Policy for pruning old snapshots.
/// You can combine both knobs; the result is the union of items kept by either rule.
public struct PrunePolicy: Equatable {
    /// Keep the N most recent snapshots.
    public var keepLast: Int?
    /// Keep snapshots not older than D days.
    public var keepDays: Int?

    public init(keepLast: Int? = nil, keepDays: Int? = nil) {
        self.keepLast = keepLast
        self.keepDays = keepDays
    }
}

/// Result of a prune operation.
/// Useful for logging and UIs.
public struct PruneResult: Equatable {
    /// Snapshot IDs deleted by prune.
    public let deleted: [String]
    /// Snapshot IDs explicitly kept by the policy.
    public let kept: [String]
}
