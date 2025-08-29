import XCTest
@testable import BackupCore

final class EncryptionArgsTests: XCTestCase {
    func testNoEncryptionYieldsEmptyArgs() throws {
        let (args, cleanup) = try DiskImageEncryptionArgs.build(for: nil)
        defer { cleanup() }
        XCTAssertTrue(args.isEmpty)
    }

    func testCertificateModeRequiresRecipients() {
        XCTAssertThrowsError(try DiskImageEncryptionArgs.build(for: EncryptionSettings(mode: .certificate, recipients: [])))
    }

    func testCertificateSelectorFailureThrows() {
        // Use an unlikely selector to ensure not found
        XCTAssertThrowsError(try DiskImageEncryptionArgs.build(for: EncryptionSettings(mode: .certificate, recipients: ["cn:___unlikely___"])) ) { err in
            guard let e = err as? EncryptionError else { return XCTFail("wrong error type") }
            switch e { case .certificateNotFound: break; default: XCTFail("expected certificateNotFound") }
        }
    }
}
