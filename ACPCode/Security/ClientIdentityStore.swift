import Foundation
import Security

/// Client certificates for mutual TLS (FR-14, PLAN 2.7).
/// A `.p12` is imported once; its passphrase is used for the import and never stored. The identity
/// (certificate and private key) is kept in the Keychain, readable only while the device is
/// unlocked, never synced, one per server, under the label `<prefix>.<serverId>`.
struct ClientIdentityStore: Sendable {
    enum ImportError: LocalizedError, Equatable {
        case wrongPassphrase
        case noIdentity
        case failed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .wrongPassphrase: return "The passphrase for this certificate file is not correct."
            case .noIdentity: return "The file has no certificate with a private key."
            case .failed(let status): return "The certificate could not be imported (\(status))."
            }
        }
    }

    static let shared = ClientIdentityStore()
    let labelPrefix: String

    init(labelPrefix: String = "com.acpcode.client-identity") {
        self.labelPrefix = labelPrefix
    }

    private func label(_ serverId: UUID) -> String { "\(labelPrefix).\(serverId.uuidString)" }

    /// Read the identity from PKCS#12 data. Nothing is written anywhere.
    static func importPKCS12(_ data: Data, passphrase: String) throws -> SecIdentity {
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: passphrase] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &items)
        switch status {
        case errSecSuccess: break
        case errSecAuthFailed, errSecPkcs12VerifyFailure: throw ImportError.wrongPassphrase
        default: throw ImportError.failed(status)
        }
        guard let first = (items as? [[String: Any]])?.first,
              let value = first[kSecImportItemIdentity as String] else { throw ImportError.noIdentity }
        return value as! SecIdentity // CF type: the cast always succeeds when the key is present.
    }

    /// A short description for the form: the certificate's subject summary.
    static func summary(of identity: SecIdentity) -> String {
        var certificate: SecCertificate?
        SecIdentityCopyCertificate(identity, &certificate)
        guard let certificate else { return "Client certificate" }
        return (SecCertificateCopySubjectSummary(certificate) as String?) ?? "Client certificate"
    }

    func save(_ identity: SecIdentity, serverId: UUID) throws {
        try delete(serverId: serverId)
        let attributes: [String: Any] = [
            kSecValueRef as String: identity,
            kSecAttrLabel as String: label(serverId),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw ImportError.failed(status) }
    }

    func load(serverId: UUID) -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label(serverId),
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let result else { return nil }
        return (result as! SecIdentity)
    }

    func delete(serverId: UUID) throws {
        // An identity is stored as a certificate item and a key item; remove both.
        for itemClass in [kSecClassIdentity, kSecClassCertificate, kSecClassKey] {
            let query: [String: Any] = [kSecClass as String: itemClass, kSecAttrLabel as String: label(serverId)]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw ImportError.failed(status) }
        }
    }
}
