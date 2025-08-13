import XCTest
@testable import BackupCore
import Foundation

final class AzureIntegrationTests: XCTestCase {
    // Helper: Load SAS URL from ~/.config/bckp/config. Skip tests if not present.
    private func getSASURL() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cfgURL = home.appendingPathComponent(".config/bckp/config")
        let cfg = AppConfigIO.load(from: cfgURL)
        guard let sas = cfg.azureSAS, !sas.isEmpty else {
            throw XCTSkip("Azure SAS not found in ~/.config/bckp/config; skipping Azure integration tests.")
        }
        guard let url = URL(string: sas) else {
            XCTFail("Invalid SAS URL in ~/.config/bckp/config")
            throw XCTSkip("Invalid SAS URL; skipping to avoid false negatives.")
        }
        return url
    }

    // Create a small temporary source tree
    private func makeTempSource() throws -> URL {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bckp-azure-int-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try "hello world".data(using: .utf8)!.write(to: tmpDir.appendingPathComponent("file1.txt"))
        let sub = tmpDir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "subcontent".data(using: .utf8)!.write(to: sub.appendingPathComponent("file2.txt"))
        return tmpDir
    }

    func testAzureListUploadDownload() throws {
        let sasURL = try getSASURL()
        let manager = BackupManager()

        // Ensure repo marker exists (idempotent)
        try manager.initAzureRepo(containerSASURL: sasURL)

        // Upload a tiny snapshot
        let src = try makeTempSource()
        let snap = try manager.backupToAzure(
            sources: [src],
            containerSASURL: sasURL,
            options: BackupOptions(concurrency: 2),
            progress: nil
        )

        // List snapshots and verify the new one is present
        let items = try manager.listSnapshotsInAzure(containerSASURL: sasURL)
        XCTAssertTrue(items.contains(where: { $0.id == snap.id }), "Uploaded snapshot should be listed")

        // Restore to a temp directory and verify contents
        let restoreDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bckp-azure-int-dst-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: restoreDir, withIntermediateDirectories: true)
        try manager.restoreFromAzure(snapshotId: snap.id, containerSASURL: sasURL, to: restoreDir, concurrency: 2)

        // Validate restored files
        let restoredFile1 = restoreDir.appendingPathComponent("file1.txt")
        let restoredFile2 = restoreDir.appendingPathComponent("sub/file2.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoredFile1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoredFile2.path))
        let c1 = try String(contentsOf: restoredFile1, encoding: .utf8)
        let c2 = try String(contentsOf: restoredFile2, encoding: .utf8)
        XCTAssertEqual(c1, "hello world")
        XCTAssertEqual(c2, "subcontent")
    }
}
