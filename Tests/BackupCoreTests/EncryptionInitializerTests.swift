import XCTest
@testable import BackupCore
import Security
import CryptoKit

final class EncryptionInitializerTests: XCTestCase {
    func testGenerateSelfSignedRSACreatesIdentity() throws {
        let cn = "bckp-test-" + UUID().uuidString

        // Act: generate key + self-signed cert
        let fingerprint: String
        do {
            fingerprint = try EncryptionInitializer.generateSelfSignedRSA(commonName: cn, icloudSync: false)
        } catch let err as KeygenError {
            // Skip on environments where keychain isn't available or interaction is disallowed.
            switch err {
            case .osStatus(let status) where status == errSecNotAvailable || status == errSecInteractionNotAllowed:
                throw XCTSkip("Keychain not available for tests (status=\(status)). Skipping.")
            default:
                throw err
            }
        }

        // Assert: certificate exists in keychain with given label
        var certRef: CFTypeRef?
        let certQuery: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: cn,
            kSecReturnRef: true
        ]
        let certStatus = SecItemCopyMatching(certQuery as CFDictionary, &certRef)
        if certStatus == errSecNotAvailable || certStatus == errSecInteractionNotAllowed {
            throw XCTSkip("Keychain not available for tests (status=\(certStatus)). Skipping.")
        }
      XCTAssertEqual(certStatus, errSecSuccess, "Certificate not found in keychain (status=\(certStatus))")
      guard certStatus == errSecSuccess, let cf = certRef,
          CFGetTypeID(cf) == SecCertificateGetTypeID() else { return }
      let cert: SecCertificate = unsafeBitCast(cf, to: SecCertificate.self)

        // Assert: fingerprint matches DER SHA-1 of the certificate
        let der = SecCertificateCopyData(cert) as Data
        let computed = Insecure.SHA1.hash(data: der).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(computed, fingerprint, "Returned SHA-1 fingerprint should match certificate DER SHA-1")

        // Assert: identity can be constructed (implies matching private key exists)
        var identity: SecIdentity?
        let idStatus = SecIdentityCreateWithCertificate(nil, cert, &identity)
        XCTAssertEqual(idStatus, errSecSuccess, "SecIdentity should be creatable (status=\(idStatus))")
        XCTAssertNotNil(identity)

        // Cleanup: best-effort remove test artifacts to not pollute user keychain
        // Try identity (virtual), certificate, and both private/public keys; include synchronizable-any to catch iCloud-synced items.
    let identityDelete: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecAttrLabel: cn,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny
        ]
    let certDelete: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: cn,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny
        ]
    let privKeyDelete: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrLabel: cn,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny
        ]
    let pubKeyDelete: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrLabel: cn,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny
        ]
        _ = SecItemDelete(identityDelete as CFDictionary)
        _ = SecItemDelete(certDelete as CFDictionary)
        _ = SecItemDelete(privKeyDelete as CFDictionary)
        _ = SecItemDelete(pubKeyDelete as CFDictionary)
    }
}
