import CryptoKit
import Foundation

/// Values that belong to MCP servers, kept in the Keychain (FR-40, D-084, PLAN 6B.1): HTTP header
/// values and stdio environment values. They never go to a file. The gateway receives them only
/// inside `session/new` and `session/resume`, and holds them in memory for the session (D-084).
///
/// `KeychainStore` has a fixed set of fields, but an MCP server has any number of named values.
/// So each value is one Keychain item, addressed by a UUID derived from the MCP entry id, the kind
/// and the name. The items use `KeychainStore`, so they are
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and never sync.
struct MCPHeaderStore: Sendable {
    enum Kind: String, Sendable {
        case header
        case env
    }

    static let defaultService = "com.acpcode.mcp-values"

    private let keychain: KeychainStore

    init(service: String = MCPHeaderStore.defaultService) {
        keychain = KeychainStore(service: service)
    }

    func set(_ value: String, entryId: UUID, kind: Kind, name: String) throws {
        try keychain.set(value, serverId: Self.itemId(entryId: entryId, kind: kind, name: name), field: .token)
    }

    /// The stored value, or nil when there is none.
    func get(entryId: UUID, kind: Kind, name: String) throws -> String? {
        try keychain.get(serverId: Self.itemId(entryId: entryId, kind: kind, name: name), field: .token)
    }

    func delete(entryId: UUID, kind: Kind, name: String) throws {
        try keychain.delete(serverId: Self.itemId(entryId: entryId, kind: kind, name: name), field: .token)
    }

    /// Deletes every value of one MCP entry. The names come from the entry, which keeps them; names
    /// are not secret, values are.
    func deleteAll(entryId: UUID, headerNames: [String], envNames: [String]) throws {
        for name in headerNames {
            try delete(entryId: entryId, kind: .header, name: name)
        }
        for name in envNames {
            try delete(entryId: entryId, kind: .env, name: name)
        }
    }

    /// A stable UUID for one value: the first 16 bytes of SHA-256 over the entry id, kind and name.
    static func itemId(entryId: UUID, kind: Kind, name: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data("\(entryId.uuidString)|\(kind.rawValue)|\(name)".utf8)))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
        ))
    }
}
