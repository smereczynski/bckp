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
        version: "0.1.0",
        subcommands: [InitRepo.self, Backup.self, Restore.self, List.self, Prune.self, InitAzure.self, BackupAzure.self, ListAzure.self, RestoreAzure.self, PruneAzure.self],
        defaultSubcommand: nil
    )
}

extension Bckp {
    /// Initialize the repository folder on disk.
    struct InitRepo: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Initialize a backup repository")

            @Option(name: .shortAndLong, help: "Path to the repository root (default ~/Backups/bckp; can be set in config)")
        var repo: String?

        func run() throws {
            let manager = BackupManager()
                let cfg = AppConfigIO.load(from: AppConfig.defaultRepoConfigURL)
                let repoURL = URL(fileURLWithPath: repo ?? cfg.repoPath ?? BackupManager.defaultRepoURL.path)
            try manager.initRepo(at: repoURL)
            print("Initialized repository at \(repoURL.path)")
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

        func run() throws {
            guard !source.isEmpty else {
                throw ValidationError("Provide at least one --source path")
            }
            let manager = BackupManager()
                let cfg = AppConfigIO.load(from: AppConfig.defaultRepoConfigURL)
                let repoURL = URL(fileURLWithPath: repo ?? cfg.repoPath ?? BackupManager.defaultRepoURL.path)
            let sources = source.map { URL(fileURLWithPath: $0) }
                let opts = BackupOptions(include: include.isEmpty ? cfg.include : include,
                                         exclude: exclude.isEmpty ? cfg.exclude : exclude,
                                         concurrency: concurrency ?? cfg.concurrency)
            let snap = try manager.backup(sources: sources, to: repoURL, options: opts, progress: progress ? { p in
                let percent: Double = (p.totalBytes > 0) ? (Double(p.processedBytes) / Double(p.totalBytes) * 100.0) : 0
                let processed = ByteCountFormatter.string(fromByteCount: p.processedBytes, countStyle: .file)
                let total = ByteCountFormatter.string(fromByteCount: p.totalBytes, countStyle: .file)
                let cur = p.currentPath ?? ""
                print(String(format: "[%.0f%%] %d/%d files (%@/%@) %@", percent, p.processedFiles, p.totalFiles, processed, total, cur))
            } : nil)
            let sizeStr = "\(snap.totalBytes)"
            print("Created snapshot: \(snap.id) | files: \(snap.totalFiles) | size: \(snap.totalBytes)")
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

        func run() throws {
            let manager = BackupManager()
                let cfg = AppConfigIO.load(from: AppConfig.defaultRepoConfigURL)
                let repoURL = URL(fileURLWithPath: repo ?? cfg.repoPath ?? BackupManager.defaultRepoURL.path)
            let policy = PrunePolicy(keepLast: keepLast, keepDays: keepDays)
            let result = try manager.prune(in: repoURL, policy: policy)
            print("Pruned. Deleted: \(result.deleted.count) | Kept: \(result.kept.count)")
            if !result.deleted.isEmpty {
                print("Deleted IDs: \(result.deleted.joined(separator: ", "))")
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

        func run() throws {
            guard !source.isEmpty else { throw ValidationError("Provide at least one --source path") }
            let manager = BackupManager()
            let cfg = AppConfigIO.load(from: AppConfig.defaultRepoConfigURL)
            let sources = source.map { URL(fileURLWithPath: $0) }
                let opts = BackupOptions(include: include.isEmpty ? cfg.include : include,
                                         exclude: exclude.isEmpty ? cfg.exclude : exclude,
                                         concurrency: concurrency ?? cfg.concurrency)
                let sasURL = URL(string: sas ?? cfg.azureSAS ?? "")
                guard let sasURL else { throw ValidationError("Provide --sas or set [azure] sas in config") }
                let snap = try manager.backupToAzure(sources: sources, containerSASURL: sasURL, options: opts, progress: progress ? { p in
                let percent: Double = (p.totalBytes > 0) ? (Double(p.processedBytes) / Double(p.totalBytes) * 100.0) : 0
                let processed = ByteCountFormatter.string(fromByteCount: p.processedBytes, countStyle: .file)
                let total = ByteCountFormatter.string(fromByteCount: p.totalBytes, countStyle: .file)
                let cur = p.currentPath ?? ""
                print(String(format: "[%.0f%%] %d/%d files (%@/%@) %@", percent, p.processedFiles, p.totalFiles, processed, total, cur))
            } : nil)
            let sizeStr = "\(snap.totalBytes)"
            print("Created cloud snapshot: \(snap.id) | files: \(snap.totalFiles) | size: \(snap.totalBytes)")
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

        func run() throws {
            let manager = BackupManager()
            let cfg = AppConfigIO.load(from: AppConfig.defaultRepoConfigURL)
            let sasURL = URL(string: sas ?? cfg.azureSAS ?? "")
            guard let sasURL else { throw ValidationError("Provide --sas or set [azure] sas in config") }
            let policy = PrunePolicy(keepLast: keepLast, keepDays: keepDays)
            let result = try manager.pruneInAzure(containerSASURL: sasURL, policy: policy)
            print("Pruned (cloud). Deleted: \(result.deleted.count) | Kept: \(result.kept.count)")
            if !result.deleted.isEmpty { print("Deleted IDs: \(result.deleted.joined(separator: ", "))") }
        }
    }
}

// Entry point for the CLI app.
Bckp.main()
