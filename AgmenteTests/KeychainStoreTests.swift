import XCTest
@testable import Agmente

/// PLAN 2.1: KeychainStore round trip, overwrite, delete and accessibility class.
final class KeychainStoreTests: XCTestCase {
    private var store: KeychainStore!
    private var serverId: UUID!

    override func setUp() {
        super.setUp()
        store = KeychainStore(service: "com.agmente.tests.\(UUID().uuidString)")
        serverId = UUID()
    }

    override func tearDown() {
        try? store.deleteAll(serverId: serverId)
        super.tearDown()
    }

    func testRoundTripOverwriteAndDelete() throws {
        XCTAssertNil(try store.get(serverId: serverId, field: .token))
        try store.set("first", serverId: serverId, field: .token)
        XCTAssertEqual(try store.get(serverId: serverId, field: .token), "first")
        try store.set("second", serverId: serverId, field: .token)
        XCTAssertEqual(try store.get(serverId: serverId, field: .token), "second")
        try store.delete(serverId: serverId, field: .token)
        XCTAssertNil(try store.get(serverId: serverId, field: .token))
    }

    func testEmptyValueDeletesItem() throws {
        try store.set("x", serverId: serverId, field: .cfAccessClientSecret)
        try store.set("", serverId: serverId, field: .cfAccessClientSecret)
        XCTAssertNil(try store.get(serverId: serverId, field: .cfAccessClientSecret))
    }

    func testFieldsAndServersAreSeparate() throws {
        let other = UUID()
        defer { try? store.deleteAll(serverId: other) }
        try store.set("a", serverId: serverId, field: .token)
        try store.set("b", serverId: serverId, field: .cfAccessClientId)
        try store.set("c", serverId: other, field: .token)
        XCTAssertEqual(try store.get(serverId: serverId, field: .token), "a")
        XCTAssertEqual(try store.get(serverId: serverId, field: .cfAccessClientId), "b")
        XCTAssertEqual(try store.get(serverId: other, field: .token), "c")
        try store.deleteAll(serverId: serverId)
        XCTAssertNil(try store.get(serverId: serverId, field: .token))
        XCTAssertEqual(try store.get(serverId: other, field: .token), "c")
    }

    func testItemsAreWhenUnlockedThisDeviceOnly() throws {
        try store.set("secret", serverId: serverId, field: .token)
        XCTAssertEqual(try store.accessibility(serverId: serverId, field: .token),
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        // Overwriting keeps the class.
        try store.set("secret2", serverId: serverId, field: .token)
        XCTAssertEqual(try store.accessibility(serverId: serverId, field: .token),
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }
}
