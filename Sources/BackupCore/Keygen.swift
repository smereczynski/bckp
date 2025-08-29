// Key generation and self-signed certificate creation for macOS Keychain.
// - Generates an RSA-4096 private key using modern SecAccessControl to manage key usage permissions.
// - Optionally marks the key as synchronizable for iCloud Keychain sync (best-effort).
// - Builds a self-signed end-entity certificate using swift-certificates and imports it into the login keychain.
// - Returns the DER SHA-1 fingerprint (hex, lowercase) of the certificate for convenient recipient selection via sha1:...
// Notes:
// - Uses SecAccessControl (no deprecated SecAccess/SecTrustedApplication) to avoid deprecation warnings.
// - No network or external dependencies; only local Keychain operations.
import Foundation
import Security
import X509
import CryptoKit

public enum KeygenError: Error, LocalizedError {
    case osStatus(OSStatus)
    case keyCreationFailed(String)
    case certificateBuildFailed
    case certificateImportFailed(OSStatus)
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .osStatus(let s): return "Keychain error: \(s)"
        case .keyCreationFailed(let m): return "Key creation failed: \(m)"
        case .certificateBuildFailed: return "Failed to build self-signed certificate"
        case .certificateImportFailed(let s): return "Failed to import certificate: \(s)"
        case .unsupported: return "Unsupported platform"
        }
    }
}

/// Generate RSA-4096 key into login keychain with ACL; optionally mark synchronizable (iCloud).
/// - Parameters:
///   - label: Keychain item label for the key.
///   - synchronizable: If true, attempts to enable iCloud Keychain sync for the key.
/// - Returns: SecKey for the generated private key stored in the keychain.
/// - Throws: KeygenError or CFError if Keychain operations fail.
private func generateRSA4096Key(label: String, synchronizable: Bool) throws -> SecKey {
    // Preferred: Use SecAccessControl for private key usage.
    var acError: Unmanaged<CFError>?
    let accessControl = SecAccessControlCreateWithFlags(
        nil,
        kSecAttrAccessibleAfterFirstUnlock,
        [.privateKeyUsage],
        &acError
    )
    if let e = acError?.takeRetainedValue() {
        // If building SecAccessControl fails, we'll fall back to a minimal attribute set below.
        NSLog("SecAccessControlCreateWithFlags failed, will fall back: \(e)")
    }

    func makeAttributes(useAccessControl: Bool) -> [CFString: Any] {
        var a: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 4096,
            kSecAttrIsPermanent: true,
            kSecAttrLabel: label
        ]
        if useAccessControl, let ac = accessControl {
            a[kSecAttrAccessControl] = ac
            // Only set synchronizable when true to avoid -34018 in environments without entitlements.
            if synchronizable { a[kSecAttrSynchronizable] = kCFBooleanTrue as Any }
        } else {
            // Minimal attributes; do not include access control or synchronizable flags.
        }
        return a
    }

    var err: Unmanaged<CFError>?
    // Try with access control first
    if let key = SecKeyCreateRandomKey(makeAttributes(useAccessControl: true) as CFDictionary, &err) {
        return key
    }
    // If failed with missing entitlement (-34018) or any other error, attempt a minimal retry.
    if let e = err?.takeRetainedValue() as Error? {
        NSLog("SecKeyCreateRandomKey with AccessControl failed, retrying without AC: \(e)")
    }
    err = nil
    if let key = SecKeyCreateRandomKey(makeAttributes(useAccessControl: false) as CFDictionary, &err) {
        return key
    }
    if let e = err?.takeRetainedValue() { throw e }
    throw KeygenError.keyCreationFailed("SecKeyCreateRandomKey")
}

/// Create a self-signed certificate (RSA-4096) and import it into login keychain.
/// - Parameter commonName: Subject common name for the certificate and key label.
/// - Parameter icloudSync: When true, attempts to create the key as synchronizable.
/// - Returns: Hex lowercase DER SHA-1 fingerprint of the certificate (no colons).
/// - Behavior: Adds the certificate to the login keychain; if the certificate already exists (duplicate), it's treated as success.
/// - Note: The private key is created first; the certificate is created using swift-certificates and then imported.
public struct EncryptionInitializer {
    public static func generateSelfSignedRSA(commonName: String, icloudSync: Bool) throws -> String {
    // 1) Private key in Keychain
    let key = try generateRSA4096Key(label: commonName, synchronizable: icloudSync)

    // 2) X.509 bridge: wrap SecKey into swift-certificates key types
    let issuerPrivateKey = try Certificate.PrivateKey(key)
    let publicKey = issuerPrivateKey.publicKey

        // 3) Subject/Issuer DN and validity
        let subject = try DistinguishedName { CommonName(commonName) }
        let notBefore = Date()
        let notAfter = notBefore.addingTimeInterval(825 * 24 * 3600) // ~27 months

    // 4) Extensions: mark as end-entity (not a CA) and allow digitalSignature/keyEncipherment
        let extensions = try Certificate.Extensions {
            Critical(KeyUsage(digitalSignature: true, keyEncipherment: true))
            // Prefer explicit non-CA basic constraints when available.
            Critical(BasicConstraints.notCertificateAuthority)
        }

        // 5) Build and sign self-signed cert
        let cert = try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: publicKey,
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            issuer: subject,
            subject: subject,
            extensions: extensions,
            issuerPrivateKey: issuerPrivateKey
        )

    // 6) Bridge to SecCertificate for Keychain import
    let sCert = try SecCertificate.makeWithCertificate(cert)

        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecValueRef: sCert,
            kSecAttrLabel: commonName
        ]
        let st = SecItemAdd(addQuery as CFDictionary, nil)
        guard st == errSecSuccess || st == errSecDuplicateItem else { throw KeygenError.certificateImportFailed(st) }

    // 7) SHA-1 fingerprint (no colons) for selector convenience
    // Compute over DER bytes of the SecCertificate
    let derData = SecCertificateCopyData(sCert) as Data
    let fp = Insecure.SHA1.hash(data: derData).map { String(format: "%02x", $0) }.joined()
    return fp
    }
}
