import CoreData
import Foundation

/// Moves server secrets from Core Data into the Keychain (FR-10, PLAN 2.2).
/// Order per field: write the Keychain, read it back, then erase the Core Data value.
/// A crash in between leaves the secret in both places, never in neither.
enum ServerSecretMigration {
    struct Report: Equatable {
        var migrated = 0
        var failed = 0
    }

    @discardableResult
    static func run(context: NSManagedObjectContext, keychain: KeychainStore) -> Report {
        var report = Report()
        let request = NSFetchRequest<StoredServer>(entityName: "StoredServer")
        guard let servers = try? context.fetch(request) else { return report }
        var changed = false
        for server in servers {
            guard let id = server.id else { continue }
            for field in KeychainStore.Field.allCases {
                guard let value = value(of: server, field), !value.isEmpty else { continue }
                do {
                    try keychain.set(value, serverId: id, field: field)
                    guard try keychain.get(serverId: id, field: field) == value else {
                        report.failed += 1
                        continue
                    }
                    setValue(nil, on: server, field)
                    changed = true
                    report.migrated += 1
                } catch {
                    // Keychain unavailable (for example, device locked). Keep the value; retry next launch.
                    report.failed += 1
                }
            }
        }
        if changed {
            try? context.save()
        }
        return report
    }

    static func value(of server: StoredServer, _ field: KeychainStore.Field) -> String? {
        switch field {
        case .token: return server.token
        case .cfAccessClientId: return server.cfAccessClientId
        case .cfAccessClientSecret: return server.cfAccessClientSecret
        }
    }

    static func setValue(_ value: String?, on server: StoredServer, _ field: KeychainStore.Field) {
        switch field {
        case .token: server.token = value
        case .cfAccessClientId: server.cfAccessClientId = value
        case .cfAccessClientSecret: server.cfAccessClientSecret = value
        }
    }
}
