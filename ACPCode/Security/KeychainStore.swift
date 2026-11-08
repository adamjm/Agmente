import Foundation
import Security

/// Per-server secrets in the Keychain (FR-10, PLAN 2.1).
/// Generic-password items: service `com.acpcode.server`, account `<serverId>/<field>`.
/// Items are readable only while the device is unlocked, never leave this device, and never sync.
struct KeychainStore: Sendable {
    enum Field: String, CaseIterable, Sendable {
        case token
        case cfAccessClientId
        case cfAccessClientSecret
    }

    struct KeychainError: Error, Equatable {
        let status: OSStatus
    }

    static let defaultService = "com.acpcode.server"
    static let shared = KeychainStore()

    let service: String

    init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    private func account(_ serverId: UUID, _ field: Field) -> String {
        "\(serverId.uuidString)/\(field.rawValue)"
    }

    private func baseQuery(_ serverId: UUID, _ field: Field) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(serverId, field),
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    /// Store a value. An empty value deletes the item.
    func set(_ value: String, serverId: UUID, field: Field) throws {
        if value.isEmpty {
            try delete(serverId: serverId, field: field)
            return
        }
        let data = Data(value.utf8)
        let query = baseQuery(serverId, field)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(update) { _, new in new }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    /// Read a value. Returns nil when there is no item.
    func get(serverId: UUID, field: Field) throws -> String? {
        var query = baseQuery(serverId, field)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    /// The accessibility class stored on an item, for tests.
    func accessibility(serverId: UUID, field: Field) throws -> String? {
        var query = baseQuery(serverId, field)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let attrs = result as? [String: Any] else { throw KeychainError(status: status) }
        return attrs[kSecAttrAccessible as String] as? String
    }

    func delete(serverId: UUID, field: Field) throws {
        let status = SecItemDelete(baseQuery(serverId, field) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    func deleteAll(serverId: UUID) throws {
        for field in Field.allCases {
            try delete(serverId: serverId, field: field)
        }
    }
}
