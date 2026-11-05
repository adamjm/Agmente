import CoreData
import XCTest
@testable import Agmente

/// T-14 (FR-10, PLAN 2.2): server secrets move from Core Data to the Keychain and are erased from Core Data.
final class ServerSecretMigrationTests: XCTestCase {
    private var directory: URL!
    private var keychain: KeychainStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agmente-t14-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        keychain = KeychainStore(service: "com.agmente.tests.\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeController() -> PersistenceController {
        PersistenceController(storeURL: directory.appendingPathComponent("Agmente.sqlite"))
    }

    /// Insert a server the way the old app stored it: secrets as plain Core Data strings.
    private func insertLegacyServer(in context: NSManagedObjectContext, id: UUID) throws {
        let server = NSEntityDescription.insertNewObject(forEntityName: "StoredServer", into: context) as! StoredServer
        server.id = id
        server.name = "legacy"
        server.host = "gateway.example.com"
        server.scheme = "wss"
        server.workingDirectory = "/"
        server.token = "legacy-token-T14"
        server.cfAccessClientId = "cf-id-T14"
        server.cfAccessClientSecret = "cf-secret-T14"
        try context.save()
    }

    private func storedServer(_ context: NSManagedObjectContext, _ id: UUID) throws -> StoredServer? {
        let request = NSFetchRequest<StoredServer>(entityName: "StoredServer")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try context.fetch(request).first
    }

    func testT14MigratesLegacySecretsAndErasesCoreData() throws {
        let id = UUID()
        defer { try? keychain.deleteAll(serverId: id) }
        let controller = makeController()
        try insertLegacyServer(in: controller.container.viewContext, id: id)

        let storage = SessionStorage(container: controller.container, keychain: keychain)
        let servers = storage.fetchServers()

        // The app still sees the secrets.
        let config = try XCTUnwrap(servers.first { $0.id == id })
        XCTAssertEqual(config.token, "legacy-token-T14")
        XCTAssertEqual(config.cfAccessClientId, "cf-id-T14")
        XCTAssertEqual(config.cfAccessClientSecret, "cf-secret-T14")

        // They are in the Keychain.
        XCTAssertEqual(try keychain.get(serverId: id, field: .token), "legacy-token-T14")
        XCTAssertEqual(try keychain.get(serverId: id, field: .cfAccessClientId), "cf-id-T14")
        XCTAssertEqual(try keychain.get(serverId: id, field: .cfAccessClientSecret), "cf-secret-T14")

        // And the Core Data attributes are empty, also as read from a fresh store load.
        let reopened = makeController()
        let stored = try XCTUnwrap(try storedServer(reopened.container.viewContext, id))
        XCTAssertNil(stored.token)
        XCTAssertNil(stored.cfAccessClientId)
        XCTAssertNil(stored.cfAccessClientSecret)
    }

    func testSaveServerWritesKeychainNotCoreData() throws {
        let controller = makeController()
        let storage = SessionStorage(container: controller.container, keychain: keychain)
        let id = UUID()
        defer { try? keychain.deleteAll(serverId: id) }
        storage.saveServer(ACPServerConfiguration(
            id: id, name: "new", scheme: "wss", host: "gateway.example.com",
            token: "new-token", cfAccessClientId: "", cfAccessClientSecret: "",
            workingDirectory: "/", serverType: .acp
        ))
        XCTAssertEqual(try keychain.get(serverId: id, field: .token), "new-token")
        XCTAssertNil(try storedServer(controller.container.viewContext, id)?.token)
        XCTAssertEqual(storage.fetchServers().first { $0.id == id }?.token, "new-token")

        storage.deleteServer(id: id)
        XCTAssertNil(try keychain.get(serverId: id, field: .token))
    }
}
