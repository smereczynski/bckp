import XCTest
@testable import BackupCore

final class RepositoriesConfigStoreTests: XCTestCase {
    private var tempDir: URL!
    private var fileURL: URL!

    override func setUp() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bckp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        tempDir = base
        fileURL = base.appendingPathComponent("repositories.json")
        RepositoriesConfigStore.overrideFileURL = fileURL
        // Force reset shared store content for isolated run
        RepositoriesConfigStore.shared.resetForTesting()
    }

    override func tearDown() async throws {
        RepositoriesConfigStore.overrideFileURL = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testKeyNormalizationLocalAndAzure() throws {
        let local = URL(fileURLWithPath: "/tmp/../tmp/foo").standardizedFileURL
        let keyLocal = RepositoriesConfigStore.keyForLocal(local)
        XCTAssertEqual(keyLocal, local.path)

        let withQuery = URL(string: "https://account.blob.core.windows.net/container?sas=abc#frag")!
        let keyAzure = RepositoriesConfigStore.keyForAzure(withQuery)
        XCTAssertEqual(keyAzure, "https://account.blob.core.windows.net/container")
    }

    func testRecordRepoUsedAndConfiguredSources() throws {
        let repo = URL(fileURLWithPath: "/tmp/repo")
        let src1 = URL(fileURLWithPath: "/Users/u/A")
        let src2 = URL(fileURLWithPath: "/Users/u/B")

        // record used
        RepositoriesConfigStore.shared.recordRepoUsedLocal(repoURL: repo)
        // configure sources
        RepositoriesConfigStore.shared.updateConfiguredSourcesLocal(repoURL: repo, sources: [src1, src2])

        let cfg1 = RepositoriesConfigStore.shared.config
        let key = RepositoriesConfigStore.keyForLocal(repo)
        let repoInfo = cfg1.repositories[key]
        XCTAssertNotNil(repoInfo)
        XCTAssertEqual(Set(repoInfo?.sources.map { $0.path } ?? []), Set([src1.standardizedFileURL.path, src2.standardizedFileURL.path]))
        XCTAssertNotNil(repoInfo?.lastUsedAt)
    }

    func testRecordBackupUpdatesLastBackupAtAndPersists() throws {
        let repo = URL(fileURLWithPath: "/tmp/repo2")
        let src1 = URL(fileURLWithPath: "/Users/u/C")
        let when = Date()

        // prepare configured source
        RepositoriesConfigStore.shared.updateConfiguredSourcesLocal(repoURL: repo, sources: [src1])
        // record backup
        RepositoriesConfigStore.shared.recordBackupLocal(repoURL: repo, sourcePaths: [src1], when: when)

        // Assert in-memory
    let cfg = RepositoriesConfigStore.shared.config
    let key = RepositoriesConfigStore.keyForLocal(repo)
    let got1 = cfg.repositories[key]?.sources.first?.lastBackupAt?.timeIntervalSince1970
    XCTAssertNotNil(got1)
    if let got1 { XCTAssertEqual(got1, when.timeIntervalSince1970, accuracy: 0.01) }

        // Assert persisted to file by loading fresh decoder
        let data = try Data(contentsOf: fileURL)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    let loaded = try dec.decode(RepositoriesConfig.self, from: data)
    let got2 = loaded.repositories[key]?.sources.first?.lastBackupAt?.timeIntervalSince1970
    XCTAssertNotNil(got2)
    // JSON ISO8601 encoding drops fractional seconds by default; compare at second resolution.
    let expectedSeconds = floor(when.timeIntervalSince1970)
    if let got2 { XCTAssertEqual(got2, expectedSeconds, accuracy: 0.5) }
    }

    func testAzureRecordRepoUsedAndConfiguredSources() throws {
        let containerWithSAS = URL(string: "https://acct.blob.core.windows.net/c1?sv=abc&sig=xyz")!
        let src1 = URL(fileURLWithPath: "/Users/u/X")
        let src2 = URL(fileURLWithPath: "/Users/u/Y")

        // record used
        RepositoriesConfigStore.shared.recordRepoUsedAzure(containerSASURL: containerWithSAS)
        // configure sources
        RepositoriesConfigStore.shared.updateConfiguredSourcesAzure(containerSASURL: containerWithSAS, sources: [src1, src2])

        let cfg = RepositoriesConfigStore.shared.config
        let key = RepositoriesConfigStore.keyForAzure(containerWithSAS)
        let repoInfo = cfg.repositories[key]
        XCTAssertNotNil(repoInfo)
        XCTAssertEqual(Set(repoInfo?.sources.map { $0.path } ?? []), Set([src1.standardizedFileURL.path, src2.standardizedFileURL.path]))
        XCTAssertNotNil(repoInfo?.lastUsedAt)
    }

    func testAzureRecordBackupUpdatesLastBackupAtAndPersists() throws {
        let containerWithSAS = URL(string: "https://acct.blob.core.windows.net/c2?sv=abc&sig=xyz#frag")!
        let src = URL(fileURLWithPath: "/Users/u/Z")
        let when = Date()

        // prepare configured source
        RepositoriesConfigStore.shared.updateConfiguredSourcesAzure(containerSASURL: containerWithSAS, sources: [src])
        // record backup
        RepositoriesConfigStore.shared.recordBackupAzure(containerSASURL: containerWithSAS, sourcePaths: [src], when: when)

        // Assert in-memory
        let cfg = RepositoriesConfigStore.shared.config
        let key = RepositoriesConfigStore.keyForAzure(containerWithSAS)
        let got1 = cfg.repositories[key]?.sources.first?.lastBackupAt?.timeIntervalSince1970
        XCTAssertNotNil(got1)
        if let got1 { XCTAssertEqual(got1, when.timeIntervalSince1970, accuracy: 0.01) }

        // Assert persisted to file by loading fresh decoder
        let data = try Data(contentsOf: fileURL)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let loaded = try dec.decode(RepositoriesConfig.self, from: data)
        let got2 = loaded.repositories[key]?.sources.first?.lastBackupAt?.timeIntervalSince1970
        XCTAssertNotNil(got2)
        let expectedSeconds = floor(when.timeIntervalSince1970)
        if let got2 { XCTAssertEqual(got2, expectedSeconds, accuracy: 0.5) }
    }
}
