import CoreData
import XCTest
@testable import Agmente

/// PLAN 2.8 (FR-15) and the extra PLAN 2.2 check: protection options, backup exclusion, and no
/// trace of an erased token in the store files.
final class StoreProtectionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agmente-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var storeURL: URL { directory.appendingPathComponent("Agmente.sqlite") }

    func testStoreHasCompleteProtectionSecureDeleteAndNoBackup() throws {
        let controller = PersistenceController(storeURL: storeURL)
        XCTAssertNil(controller.loadError)
        let description = try XCTUnwrap(controller.container.persistentStoreDescriptions.first)
        XCTAssertEqual(description.options[NSPersistentStoreFileProtectionKey] as? FileProtectionType, .complete)
        XCTAssertEqual((description.options[NSSQLitePragmasOption] as? [String: String])?["secure_delete"], "ON")

        let values = try storeURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        // The simulator does not enforce data protection; record what it reports.
        let attributes = try FileManager.default.attributesOfItem(atPath: storeURL.path)
        print("store protection attribute on this platform: \(String(describing: attributes[.protectionKey]))")
    }

    func testErasedTokenLeavesNoBytesInStoreFiles() throws {
        let marker = "erase-me-\(UUID().uuidString)"
        let keychain = KeychainStore(service: "com.agmente.tests.\(UUID().uuidString)")
        let id = UUID()
        defer { try? keychain.deleteAll(serverId: id) }
        do {
            let controller = PersistenceController(storeURL: storeURL)
            let context = controller.container.viewContext
            let server = NSEntityDescription.insertNewObject(forEntityName: "StoredServer", into: context) as! StoredServer
            server.id = id
            server.name = "legacy"
            server.host = "gateway.example.com"
            server.scheme = "wss"
            server.workingDirectory = "/"
            server.token = marker
            try context.save()
            _ = SessionStorage(container: controller.container, keychain: keychain).fetchServers()
            // Closing the store checkpoints the WAL into the main file.
            let coordinator = controller.container.persistentStoreCoordinator
            for store in coordinator.persistentStores { try coordinator.remove(store) }
        }
        let needle = Data(marker.utf8)
        for file in StoreProtection.files(for: storeURL) where FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            XCTAssertNil(data.range(of: needle), "erased token bytes found in \(file.lastPathComponent)")
        }
        XCTAssertEqual(try keychain.get(serverId: id, field: .token), marker)
    }
}
