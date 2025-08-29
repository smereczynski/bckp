import XCTest
@testable import BackupCore

final class LoggingAndVersionTests: XCTestCase {
    private final class MemorySink: LogSink {
        private let q = DispatchQueue(label: "memsink")
        private var store: [LogEntry] = []
        func write(_ entry: LogEntry) { q.sync { store.append(entry) } }
        var entries: [LogEntry] { q.sync { store } }
    }

    func testLoggerRespectsLevel() {
    let sink = MemorySink()
    Logger.shared.replaceSinks([sink])
        Logger.shared.setDebugEnabled(false)
        Logger.shared.debug("hidden")
        Logger.shared.info("visible")
        // Allow async write
        usleep(10000)
    XCTAssertTrue(sink.entries.contains(where: { $0.message == "visible" }))
    XCTAssertFalse(sink.entries.contains(where: { $0.message == "hidden" }))
    }

    func testSnapshotIdFormat() {
        let id = BackupManager.makeSnapshotId()
        // Expect timestamp-like prefix and hyphen UUID suffix length ~8
        XCTAssertTrue(id.contains("-"))
        let parts = id.split(separator: "-")
        XCTAssertGreaterThanOrEqual(parts.count, 2)
        XCTAssertGreaterThanOrEqual(parts.last!.count, 8)
    }
}
