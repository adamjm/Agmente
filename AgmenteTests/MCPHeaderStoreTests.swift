import XCTest
@testable import Agmente

/// PLAN 6B.1: MCP header and env values in the Keychain. Round trip, delete, delete-all for one
/// entry, and the T-14 method: no value under Application Support after a save.
final class MCPHeaderStoreTests: XCTestCase {
    private var store: MCPHeaderStore!
    private var entryId: UUID!
    private var serviceName: String!

    override func setUp() {
        super.setUp()
        serviceName = "com.agmente.tests.mcp.\(UUID().uuidString)"
        store = MCPHeaderStore(service: serviceName)
        entryId = UUID()
    }

    override func tearDown() {
        try? store.deleteAll(entryId: entryId, headerNames: ["Authorization", "X-Team"], envNames: ["API_TOKEN"])
        super.tearDown()
    }

    func testRoundTripAndOverwrite() throws {
        XCTAssertNil(try store.get(entryId: entryId, kind: .header, name: "Authorization"))
        try store.set("Bearer one", entryId: entryId, kind: .header, name: "Authorization")
        XCTAssertEqual(try store.get(entryId: entryId, kind: .header, name: "Authorization"), "Bearer one")
        try store.set("Bearer two", entryId: entryId, kind: .header, name: "Authorization")
        XCTAssertEqual(try store.get(entryId: entryId, kind: .header, name: "Authorization"), "Bearer two")
    }

    func testHeadersEnvAndEntriesAreSeparate() throws {
        let other = UUID()
        defer { try? store.deleteAll(entryId: other, headerNames: ["Authorization"], envNames: []) }
        try store.set("h", entryId: entryId, kind: .header, name: "Authorization")
        try store.set("e", entryId: entryId, kind: .env, name: "Authorization")
        try store.set("o", entryId: other, kind: .header, name: "Authorization")
        XCTAssertEqual(try store.get(entryId: entryId, kind: .header, name: "Authorization"), "h")
        XCTAssertEqual(try store.get(entryId: entryId, kind: .env, name: "Authorization"), "e")
        XCTAssertEqual(try store.get(entryId: other, kind: .header, name: "Authorization"), "o")
    }

    func testDeleteOneValue() throws {
        try store.set("x", entryId: entryId, kind: .header, name: "X-Team")
        try store.delete(entryId: entryId, kind: .header, name: "X-Team")
        XCTAssertNil(try store.get(entryId: entryId, kind: .header, name: "X-Team"))
        // Deleting a missing value is not an error.
        XCTAssertNoThrow(try store.delete(entryId: entryId, kind: .header, name: "X-Team"))
    }

    func testDeleteAllForOneEntryKeepsOthers() throws {
        let other = UUID()
        defer { try? store.deleteAll(entryId: other, headerNames: ["Authorization"], envNames: []) }
        try store.set("a", entryId: entryId, kind: .header, name: "Authorization")
        try store.set("b", entryId: entryId, kind: .header, name: "X-Team")
        try store.set("c", entryId: entryId, kind: .env, name: "API_TOKEN")
        try store.set("d", entryId: other, kind: .header, name: "Authorization")

        try store.deleteAll(entryId: entryId, headerNames: ["Authorization", "X-Team"], envNames: ["API_TOKEN"])

        XCTAssertNil(try store.get(entryId: entryId, kind: .header, name: "Authorization"))
        XCTAssertNil(try store.get(entryId: entryId, kind: .header, name: "X-Team"))
        XCTAssertNil(try store.get(entryId: entryId, kind: .env, name: "API_TOKEN"))
        XCTAssertEqual(try store.get(entryId: other, kind: .header, name: "Authorization"), "d")
    }

    func testValuesAreWhenUnlockedThisDeviceOnly() throws {
        try store.set("secret", entryId: entryId, kind: .header, name: "Authorization")
        let keychain = KeychainStore(service: serviceName)
        let id = MCPHeaderStore.itemId(entryId: entryId, kind: .header, name: "Authorization")
        XCTAssertEqual(try keychain.accessibility(serverId: id, field: .token),
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    /// T-14 method: a unique marker goes in as a header value. After the save, no file under the
    /// app's Application Support folder (or the test's own folder) may contain it.
    func testNoHeaderValueAppearsInApplicationSupport() throws {
        let marker = "marker-\(UUID().uuidString)"
        try store.set("Bearer \(marker)", entryId: entryId, kind: .header, name: "Authorization")
        let roots = [
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            FileManager.default.temporaryDirectory,
        ].compactMap { $0 }
        for root in roots {
            XCTAssertFalse(try fileContains(marker, under: root), "a header value was found under \(root.lastPathComponent)")
        }
    }

    /// Scans every regular file below `root` for `needle`. Unreadable files are skipped.
    private func fileContains(_ needle: String, under root: URL) throws -> Bool {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return false
        }
        let needleData = Data(needle.utf8)
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: url) else { continue }
            if data.range(of: needleData) != nil { return true }
        }
        return false
    }
}
