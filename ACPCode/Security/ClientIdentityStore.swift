import CryptoKit
import Foundation
import Security

/// Client certificates for mutual TLS (FR-14, PLAN 2.7).
/// A `.p12` is imported once; its passphrase is used for the import and never stored. The identity
/// (certificate and private key) is kept in the Keychain, readable only while the device is
/// unlocked, never synced. Servers that use the same certificate share one Keychain copy.
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

    /// Where a server's certificate fingerprint is kept (not a secret). Two servers can use the same
    /// certificate, and the Keychain holds one copy of it, so a server finds its identity by fingerprint.
    private func fingerprintKey(_ serverId: UUID) -> String { "\(labelPrefix).fingerprint.\(serverId.uuidString)" }

    /// SHA-256 of the identity's certificate, base64.
    static func fingerprint(of identity: SecIdentity) -> String? {
        var certificate: SecCertificate?
        SecIdentityCopyCertificate(identity, &certificate)
        guard let certificate else { return nil }
        let der = SecCertificateCopyData(certificate) as Data
        return Data(SHA256.hash(data: der)).base64EncodedString()
    }

    private func storedIdentity(fingerprint: String) -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let identities = result as? [SecIdentity] else { return nil }
        return identities.first { Self.fingerprint(of: $0) == fingerprint }
    }

    private func labelledIdentity(_ serverId: UUID) -> SecIdentity? {
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

    /// True when another server of this store uses the certificate with this fingerprint.
    private func isShared(fingerprint: String, except serverId: UUID) -> Bool {
        let prefix = "\(labelPrefix).fingerprint."
        let own = fingerprintKey(serverId)
        return UserDefaults.standard.dictionaryRepresentation().contains { key, value in
            key.hasPrefix(prefix) && key != own && (value as? String) == fingerprint
        }
    }

    func save(_ identity: SecIdentity, serverId: UUID) throws {
        guard let fingerprint = Self.fingerprint(of: identity) else { throw ImportError.noIdentity }
        try delete(serverId: serverId)
        let attributes: [String: Any] = [
            kSecValueRef as String: identity,
            kSecAttrLabel as String: label(serverId),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        // The Keychain holds one copy of a certificate and its key. When another server already saved
        // this certificate, the add reports a duplicate and this server shares the stored copy.
        if status == errSecDuplicateItem {
            guard storedIdentity(fingerprint: fingerprint) != nil else { throw ImportError.failed(status) }
        } else if status != errSecSuccess {
            throw ImportError.failed(status)
        }
        UserDefaults.standard.set(fingerprint, forKey: fingerprintKey(serverId))
    }

    func load(serverId: UUID) -> SecIdentity? {
        if let fingerprint = UserDefaults.standard.string(forKey: fingerprintKey(serverId)),
           let identity = storedIdentity(fingerprint: fingerprint) {
            return identity
        }
        // An identity saved before fingerprints were recorded is found by its label.
        return labelledIdentity(serverId)
    }

    func delete(serverId: UUID) throws {
        let legacy = labelledIdentity(serverId)
        let fingerprint = UserDefaults.standard.string(forKey: fingerprintKey(serverId))
            ?? legacy.flatMap(Self.fingerprint(of:))
        UserDefaults.standard.removeObject(forKey: fingerprintKey(serverId))
        guard let fingerprint else { return }
        // Another server still uses this certificate: keep the Keychain copy.
        if isShared(fingerprint: fingerprint, except: serverId) {
            // The copy may carry this server's label. Move it off, so this server no longer finds it.
            for itemClass in [kSecClassCertificate, kSecClassKey] {
                let query: [String: Any] = [kSecClass as String: itemClass, kSecAttrLabel as String: label(serverId)]
                let change: [String: Any] = [kSecAttrLabel as String: "\(labelPrefix).shared"]
                let status = SecItemUpdate(query as CFDictionary, change as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else { throw ImportError.failed(status) }
            }
            return
        }
        guard let identity = legacy ?? storedIdentity(fingerprint: fingerprint) else { return }
        // An identity is stored as a certificate item and a key item; remove both.
        var certificate: SecCertificate?
        SecIdentityCopyCertificate(identity, &certificate)
        var key: SecKey?
        SecIdentityCopyPrivateKey(identity, &key)
        let refs: [AnyObject?] = [certificate, key]
        for case let ref? in refs {
            let status = SecItemDelete([kSecValueRef as String: ref] as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw ImportError.failed(status) }
        }
    }
}
