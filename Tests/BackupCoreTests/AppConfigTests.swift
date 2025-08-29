import XCTest
@testable import BackupCore

final class AppConfigTests: XCTestCase {
    func testParseAndSaveRoundTrip() throws {
    let cfg = AppConfig(
            repoPath: "/tmp/bckp-repo",
            include: ["**/*", "!**/.git/**"],
            exclude: ["**/node_modules/**"],
            concurrency: 4,
            azureSAS: "https://acct.blob.core.windows.net/container?sv=x",
            loggingDebug: true,
            encryptionMode: "certificate",
            encryptionRecipients: ["cn:Unit Test Cert", "sha1:DEADBEEF"]
        )
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bckp-appconfig-")
        let url = tmp.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try AppConfigIO.save(cfg, to: url)

        // Load and assert round-trip
        let loaded = AppConfigIO.load(from: url)
        XCTAssertEqual(loaded.repoPath, cfg.repoPath)
        XCTAssertEqual(loaded.include, cfg.include)
        XCTAssertEqual(loaded.exclude, cfg.exclude)
        XCTAssertEqual(loaded.concurrency, cfg.concurrency)
        XCTAssertEqual(loaded.azureSAS, cfg.azureSAS)
        XCTAssertEqual(loaded.loggingDebug, cfg.loggingDebug)
        XCTAssertEqual(loaded.encryptionMode, cfg.encryptionMode)
        XCTAssertEqual(loaded.encryptionRecipients, cfg.encryptionRecipients)
    }

    func testLoggingDebugParsingVariants() throws {
        let text = """
        [logging]
        debug = TrUe
        """
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bckp-appconfig-variants")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let loaded = AppConfigIO.load(from: url)
        XCTAssertEqual(loaded.loggingDebug, true)
    }
}
