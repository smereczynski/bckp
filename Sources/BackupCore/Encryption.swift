import Foundation
#if os(macOS)
import Security
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - Encryption Utilities
// Resolve certificate selectors to DER blobs and build hdiutil args for certificate encryption.

public enum EncryptionError: Error, LocalizedError {
	case certificateNotFound(String)
	case noRecipients
	case tempWriteFailed
	case unsupportedPlatform

	public var errorDescription: String? {
		switch self {
		case .certificateNotFound(let sel): return "Certificate not found for selector: \(sel)"
		case .noRecipients: return "At least one certificate recipient is required"
		case .tempWriteFailed: return "Failed to write temporary certificate file"
		case .unsupportedPlatform: return "Certificate-based encryption is supported on macOS only"
		}
	}
}

public struct CertificateResolver {
	public init() {}

	/// Given selectors like "sha1:ABCDEF...", "cn:Full Name", or "label:My Cert",
	/// return an array of file URLs pointing to temporary DER-encoded certificate files suitable for `hdiutil -certificate`.
	public func resolveToTempDERFiles(selectors: [String]) throws -> [URL] {
		#if os(macOS)
		guard !selectors.isEmpty else { throw EncryptionError.noRecipients }
		var results: [URL] = []
		for sel in selectors {
			guard let cert = try findCertificate(selector: sel) else { throw EncryptionError.certificateNotFound(sel) }
			guard let data = SecCertificateCopyData(cert) as Data? else { throw EncryptionError.tempWriteFailed }
			let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bckp-cert-\(UUID().uuidString).der")
			do { try data.write(to: tmp, options: [.atomic]) } catch { throw EncryptionError.tempWriteFailed }
			results.append(tmp)
		}
		return results
		#else
		throw EncryptionError.unsupportedPlatform
		#endif
	}

	#if os(macOS)
	private func findCertificate(selector: String) throws -> SecCertificate? {
		let parts = selector.split(separator: ":", maxSplits: 1).map { String($0) }
		let key = parts.first?.lowercased() ?? ""
		let value = (parts.count > 1 ? parts[1] : selector)
		// Build a query for certificates across default keychains (including iCloud if synced)
	let query: [CFString: Any] = [
			kSecClass: kSecClassCertificate,
			kSecMatchLimit: kSecMatchLimitAll,
			kSecReturnRef: true
		]
		var items: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &items)
		guard status == errSecSuccess, let array = items as? [SecCertificate] else { return nil }

		func sha1Hex(_ data: Data) -> String {
			#if canImport(CryptoKit)
			let digest = Insecure.SHA1.hash(data: data)
			return digest.map { String(format: "%02x", $0) }.joined()
			#else
			return ""
			#endif
		}

		// If label search requested, use a targeted query first
		if key == "label" {
			let q: [CFString: Any] = [
				kSecClass: kSecClassCertificate,
				kSecAttrLabel: value,
				kSecReturnRef: true,
				kSecMatchLimit: kSecMatchLimitOne
			]
			var item: CFTypeRef?
			if SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let anyItem = item {
				let cert: SecCertificate = unsafeBitCast(anyItem, to: SecCertificate.self)
				return cert
			}
		}
		for cert in array {
			switch key {
			case "sha1":
				if let data = SecCertificateCopyData(cert) as Data? {
					let hex = sha1Hex(data)
					if hex.caseInsensitiveCompare(value) == .orderedSame { return cert }
				}
			case "cn":
				if let summary = SecCertificateCopySubjectSummary(cert) as String?, summary.caseInsensitiveCompare(value) == .orderedSame {
					return cert
				}
			default:
				// Try loose match against CN as fallback
				if let summary = SecCertificateCopySubjectSummary(cert) as String?, summary.caseInsensitiveCompare(selector) == .orderedSame {
					return cert
				}
			}
		}
		return nil
	}
	#endif
}

// Build hdiutil create arguments for encryption settings.
public enum DiskImageEncryptionArgs {
	/// Given optional EncryptionSettings, return additional args for `hdiutil create` and a cleanup action for temp files.
	public static func build(for settings: EncryptionSettings?) throws -> (args: [String], cleanup: () -> Void) {
		guard let settings, settings.mode != .none else { return ([], {}) }
		switch settings.mode {
		case .none:
			return ([], {})
		case .certificate:
			let resolver = CertificateResolver()
			let tempFiles = try resolver.resolveToTempDERFiles(selectors: settings.recipients)
			var args: [String] = ["-encryption", "AES-256"]
			for f in tempFiles { args.append(contentsOf: ["-certificate", f.path]) }
			let cleanup = {
				for f in tempFiles { try? FileManager.default.removeItem(at: f) }
			}
			return (args, cleanup)
		}
	}
}

