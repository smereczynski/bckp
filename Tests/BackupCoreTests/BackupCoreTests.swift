import XCTest
@testable import BackupCore

final class BackupCoreTests: XCTestCase {
    func testInitBackupAndRestore() throws {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bckp-tests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        let repo = tmp.appendingPathComponent("repo")
        let src = tmp.appendingPathComponent("src")
        let dst = tmp.appendingPathComponent("dst")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)

        // Create sample files
        let fileA = src.appendingPathComponent("A/hello.txt")
        try fm.createDirectory(at: fileA.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "hello".data(using: .utf8)!.write(to: fileA)

        let fileB = src.appendingPathComponent("B/world.txt")
        try fm.createDirectory(at: fileB.deletingLastPathComponent(), withIntermediateDirectories: true)
        try String(repeating: "x", count: 1024).data(using: .utf8)!.write(to: fileB)

        let mgr = BackupManager()
        try mgr.initRepo(at: repo)
        let snap = try mgr.backup(sources: [src], to: repo)
        XCTAssertFalse(snap.id.isEmpty)
        let list = try mgr.listSnapshots(in: repo)
        XCTAssertEqual(list.count, 1)

        try mgr.restore(snapshotId: snap.id, from: repo, to: dst)
        let expectedA = dst.appendingPathComponent(src.lastPathComponent + "/A/hello.txt").path
        let expectedB = dst.appendingPathComponent(src.lastPathComponent + "/B/world.txt").path
        XCTAssertTrue(fm.fileExists(atPath: expectedA), "Expected file not found: \(expectedA)")
        XCTAssertTrue(fm.fileExists(atPath: expectedB), "Expected file not found: \(expectedB)")
    }

    func testIncludeExcludeFiltering() throws {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bckp-tests-include-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        let repo = tmp.appendingPathComponent("repo")
        let src = tmp.appendingPathComponent("src")
        let dst = tmp.appendingPathComponent("dst")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)

        // Create sample files
        let keepFile = src.appendingPathComponent("keep/yes.txt")
        try fm.createDirectory(at: keepFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "keep".data(using: .utf8)!.write(to: keepFile)

        let skipFile = src.appendingPathComponent("skip/no.txt")
        try fm.createDirectory(at: skipFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "skip".data(using: .utf8)!.write(to: skipFile)

        let mgr = BackupManager()
        try mgr.initRepo(at: repo)
        let opts = BackupOptions(include: ["keep/**"], exclude: ["**/no.txt"]) 
        let snap = try mgr.backup(sources: [src], to: repo, options: opts)

        // Restore and verify filtering took effect
        try mgr.restore(snapshotId: snap.id, from: repo, to: dst)
        let expectedKeep = dst.appendingPathComponent(src.lastPathComponent + "/keep/yes.txt").path
        let expectedSkip = dst.appendingPathComponent(src.lastPathComponent + "/skip/no.txt").path
        XCTAssertTrue(fm.fileExists(atPath: expectedKeep))
        XCTAssertFalse(fm.fileExists(atPath: expectedSkip))
    }

    func testPrunePolicyKeepLast() throws {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bckp-tests-prune-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        let repo = tmp.appendingPathComponent("repo")
        let src = tmp.appendingPathComponent("src")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try mgrInitAndWriteSample(in: src)

        let mgr = BackupManager()
        try mgr.initRepo(at: repo)

        // Create three snapshots with distinct timestamps
        _ = try mgr.backup(sources: [src], to: repo)
        sleep(1)
        _ = try mgr.backup(sources: [src], to: repo)
        sleep(1)
        _ = try mgr.backup(sources: [src], to: repo)

        var list = try mgr.listSnapshots(in: repo)
        XCTAssertEqual(list.count, 3)

        let result = try mgr.prune(in: repo, policy: PrunePolicy(keepLast: 2))
        XCTAssertEqual(result.deleted.count, 1)

        list = try mgr.listSnapshots(in: repo)
        XCTAssertEqual(list.count, 2)
    }

    // Helper to write a small sample file tree
    private func mgrInitAndWriteSample(in src: URL) throws {
        let fm = FileManager.default
        let file = src.appendingPathComponent("file.txt")
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "data".data(using: .utf8)!.write(to: file)
    }

    /// Symlink edge case: ensure symlinks are preserved when possible and still readable after restore.
    /// This test creates a relative symbolic link and verifies that after backup+restore
    /// the restored item is either a symlink pointing to the same relative target or (fallback)
    /// a regular file with identical contents.
    func testSymlinkPreservation() throws {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bckp-tests-symlink-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        let repo = tmp.appendingPathComponent("repo")
        let src = tmp.appendingPathComponent("src")
        let dst = tmp.appendingPathComponent("dst")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)

        // Create a real file and a relative symlink to it: links/alias -> ../real/target.txt
        let real = src.appendingPathComponent("real/target.txt")
        try fm.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "SYMLINK_CONTENT".data(using: .utf8)!.write(to: real)

        let link = src.appendingPathComponent("links/alias")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        let relativeTarget = "../real/target.txt"
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: relativeTarget)

        let mgr = BackupManager()
        try mgr.initRepo(at: repo)
        let snap = try mgr.backup(sources: [src], to: repo)
        try mgr.restore(snapshotId: snap.id, from: repo, to: dst)

        let restoredLink = dst.appendingPathComponent(src.lastPathComponent + "/links/alias")
        let rv = try restoredLink.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        if rv.isSymbolicLink == true {
            // Good path: symlink preserved
            let dest = try fm.destinationOfSymbolicLink(atPath: restoredLink.path)
            XCTAssertTrue(dest.hasSuffix("real/target.txt"), "Unexpected symlink destination: \(dest)")
            let data = try Data(contentsOf: restoredLink)
            XCTAssertEqual(String(data: data, encoding: .utf8), "SYMLINK_CONTENT")
        } else {
            // Fallback path: backed up as a regular file; content must match
            XCTAssertEqual(rv.isRegularFile, true)
            let data = try Data(contentsOf: restoredLink)
            XCTAssertEqual(String(data: data, encoding: .utf8), "SYMLINK_CONTENT")
        }
    }

    /// Large directory edge case: many files with concurrency.
    /// We generate a few hundred small files and ensure:
    /// - backup finishes
    /// - total file count and byte sizes match
    /// - progress callback reports at least one update
    func testLargeDirectoryWithConcurrency() throws {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bckp-tests-large-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        let repo = tmp.appendingPathComponent("repo")
        let src = tmp.appendingPathComponent("src")
        let dst = tmp.appendingPathComponent("dst")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)

        // Create N files across two folders
        let filesPerDir = 100
        let sizePerFile = 4096
        var expectedBytes: Int64 = 0
        for d in ["A", "B"] {
            for i in 0..<filesPerDir {
                let f = src.appendingPathComponent("\(d)/file-\(i).bin")
                try fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = Data(repeating: 0xAB, count: sizePerFile)
                try data.write(to: f)
                expectedBytes += Int64(sizePerFile)
            }
        }
        let expectedFiles = filesPerDir * 2

        let mgr = BackupManager()
        try mgr.initRepo(at: repo)
        var progressUpdates = 0
        let opts = BackupOptions(include: [], exclude: [], concurrency: 8)
        let snap = try mgr.backup(sources: [src], to: repo, options: opts) { _ in progressUpdates += 1 }
        XCTAssertEqual(snap.totalFiles, expectedFiles)
        XCTAssertEqual(snap.totalBytes, expectedBytes)
        XCTAssertGreaterThan(progressUpdates, 0)

        // Quick sanity restore of a couple files
        try mgr.restore(snapshotId: snap.id, from: repo, to: dst)
        let checkA = dst.appendingPathComponent(src.lastPathComponent + "/A/file-0.bin")
        let checkB = dst.appendingPathComponent(src.lastPathComponent + "/B/file-99.bin")
        XCTAssertTrue(fm.fileExists(atPath: checkA.path))
        XCTAssertTrue(fm.fileExists(atPath: checkB.path))
    }
}
