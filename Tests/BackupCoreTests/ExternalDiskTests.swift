import XCTest
@testable import BackupCore

#if os(macOS)
final class ExternalDiskTests: XCTestCase {
    func testExternalDiskIdentityAndKeyNormalization() throws {
        // Discover external/removable volumes.
        let disks = listExternalDiskIdentities()
        if disks.isEmpty {
            throw XCTSkip("No external/removable volumes present; skipping external disk tests.")
        }

        // Use the first detected external volume.
        let d = disks[0]
        XCTAssertTrue(d.isExternal, "Expected isExternal=true for external volume")
        XCTAssertTrue(d.volumeURL.isFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.volumeURL.path), "Volume mount path should exist")

        // identifyDisk(forPath:) should echo the same volume and mark it external.
        if let id2 = identifyDisk(forPath: d.volumeURL) {
            XCTAssertEqual(id2.volumeURL.standardizedFileURL.path, d.volumeURL.standardizedFileURL.path)
            XCTAssertTrue(id2.isExternal)
        } else {
            XCTFail("identifyDisk(forPath:) returned nil for a known external volume URL")
        }

        // Convenience check should report true for the volume root.
        XCTAssertTrue(pathIsOnExternalVolume(d.volumeURL))

        // If a UUID is available, keyForLocal should embed it via ext://volumeUUID=<UUID> prefix.
        if let uuid = d.volumeUUID {
            // Construct a plausible repo path under the mounted volume without touching disk.
            let repo = d.volumeURL.appendingPathComponent("Backups/bckp", isDirectory: true)
            let key = RepositoriesConfigStore.keyForLocal(repo)
            XCTAssertTrue(key.hasPrefix("ext://volumeUUID=\(uuid)"), "Expected key to start with ext://volumeUUID=\(uuid), got: \(key)")
        }
    }
}
#endif
