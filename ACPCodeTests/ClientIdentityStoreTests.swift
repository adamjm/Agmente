import Security
import XCTest
@testable import ACPCode

/// PLAN 2.7 (FR-14): import a .p12, store the identity in the Keychain, load and delete it.
final class ClientIdentityStoreTests: XCTestCase {
    /// Throwaway self-signed client certificate (CN=agmente-test-client, P-256), made for this test
    /// with OpenSSL on 2026-11-06. It is not a credential for any server. Passphrase: agmente-test.
    private static let testP12 = Data(base64Encoded: "MIID1QIBAzCCA5sGCSqGSIb3DQEHAaCCA4wEggOIMIIDhDCCAj8GCSqGSIb3DQEHBqCCAjAwggIsAgEAMIICJQYJKoZIhvcNAQcBMBwGCiqGSIb3DQEMAQMwDgQINcClnLDGB/oCAggAgIIB+M8lLxgaib3fNWtEO2RhBm+a5AFva200NElrk/NAosqDOc0uxRyjyNyPEHPv8S37oUIZ9rwSvxF0uq0FanDs2dG7ZDeAQLvi/t/l83rUztolRV84LwPJP7nHrz/EE20mhzteFHvQxQwEFCq5ufCiy7RRS9fCXEAFNbnRc38Yw81T3nNW1lt2e/FMrA8eEghZFBqC8EkcWqMN8F/W6E8fqHEFz2XEGKzsdwcbdRCD488BWDtKHJbbFZeuZ6ZqfQG2npAxSqQ53tYGJPO1bptWNCbEwq3/B2FajVHN3tbRPjVdMCT4b/wBZoXP8/k0axd2XDG5k1PpoK1sg4rn7CislbvtxNT8l+fENWAywokURfvJSl1Si1L85fErD7WL/RLMDbsMsLb8124YuGR5CtXf2NU+QLyOyTd3W/j9IRrNT18niexC6WdJB0in7rVNXXeGsJ5cvjpIYxdfjHKjzOGK4uzKr2kNA+ru3NRJKua83G/1gglyU9UrFCe1/9JdCqightKiRhfwYTVPMXO019egWcc74iiyaKixXPMtRZOLDo3Ms2nMgQUy4fxERA8tVMResOSwnS2BELRoGK+IgMvNuwM97J+8BKmLaVMbLFMh60LYSRJL2tvc3DqIHXhhscaPJqfPRm8C95iKuTJB7uThfU/ppKnWVittLDCCAT0GCSqGSIb3DQEHAaCCAS4EggEqMIIBJjCCASIGCyqGSIb3DQEMCgECoIG0MIGxMBwGCiqGSIb3DQEMAQMwDgQIzYqFwKQZHrsCAggABIGQ1MFxvKifSoVmmWUgQKHlUmUDct4YKepTC9uq20f8TAht0zbjr2zv3ywrkZEaY0f2FOxVExr/l//+pL/UQgxjvGCh6LgargTRYhsdK/VYxNC+4m3etqqoqetui1EGXbQa2mltcIQJcfV9H1F7pyPxl5EHPHVs0deejFqacTP+cbR0AiXQ3DGH+0e49e2OQ+LoMVwwIwYJKoZIhvcNAQkVMRYEFJyqnebzV1fOeL20hjb9iKVDKC/DMDUGCSqGSIb3DQEJFDEoHiYAYQBnAG0AZQBuAHQAZQAtAHQAZQBzAHQALQBjAGwAaQBlAG4AdDAxMCEwCQYFKw4DAhoFAAQUNE0XOYmZSfENUw9FnLvVI3jl/GcECPM5dmz7Z77jAgIIAA==")!

    private var store: ClientIdentityStore!
    private var serverId: UUID!

    override func setUp() {
        super.setUp()
        store = ClientIdentityStore(labelPrefix: "com.acpcode.tests.identity.\(UUID().uuidString)")
        serverId = UUID()
    }

    override func tearDown() {
        try? store.delete(serverId: serverId)
        super.tearDown()
    }

    func testImportWithRightPassphrase() throws {
        let identity = try ClientIdentityStore.importPKCS12(Self.testP12, passphrase: "agmente-test")
        XCTAssertEqual(ClientIdentityStore.summary(of: identity), "agmente-test-client")
    }

    func testWrongPassphraseIsReported() {
        XCTAssertThrowsError(try ClientIdentityStore.importPKCS12(Self.testP12, passphrase: "wrong")) { error in
            XCTAssertEqual(error as? ClientIdentityStore.ImportError, .wrongPassphrase)
        }
    }

    func testSaveLoadDelete() throws {
        let identity = try ClientIdentityStore.importPKCS12(Self.testP12, passphrase: "agmente-test")
        XCTAssertNil(store.load(serverId: serverId))
        try store.save(identity, serverId: serverId)
        let loaded = try XCTUnwrap(store.load(serverId: serverId))
        XCTAssertEqual(ClientIdentityStore.summary(of: loaded), "agmente-test-client")
        // Saving again replaces, not duplicates.
        try store.save(identity, serverId: serverId)
        XCTAssertNotNil(store.load(serverId: serverId))
        try store.delete(serverId: serverId)
        XCTAssertNil(store.load(serverId: serverId))
    }

    func testStoredKeyIsWhenUnlockedThisDeviceOnly() throws {
        let identity = try ClientIdentityStore.importPKCS12(Self.testP12, passphrase: "agmente-test")
        try store.save(identity, serverId: serverId)
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: "\(store.labelPrefix).\(serverId.uuidString)",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    /// The phone's local and remote servers use one certificate. The Keychain keeps one copy, and both load it.
    func testTwoServersShareOneCertificate() throws {
        let identity = try ClientIdentityStore.importPKCS12(Self.testP12, passphrase: "agmente-test")
        let other = UUID()
        defer { try? store.delete(serverId: other) }
        try store.save(identity, serverId: serverId)
        try store.save(identity, serverId: other)
        XCTAssertNotNil(store.load(serverId: serverId))
        XCTAssertNotNil(store.load(serverId: other))
        // Removing it from one server leaves the other's copy.
        try store.delete(serverId: serverId)
        XCTAssertNil(store.load(serverId: serverId))
        XCTAssertNotNil(store.load(serverId: other))
        try store.delete(serverId: other)
        XCTAssertNil(store.load(serverId: other))
    }

    /// An identity saved by the earlier build has a label and no recorded fingerprint. A second server
    /// can still share it, and removing the first leaves the second working.
    func testSharesAnIdentitySavedBeforeFingerprints() throws {
        let identity = try ClientIdentityStore.importPKCS12(Self.testP12, passphrase: "agmente-test")
        let other = UUID()
        defer { try? store.delete(serverId: other) }
        let legacy: [String: Any] = [
            kSecValueRef as String: identity,
            kSecAttrLabel as String: "\(store.labelPrefix).\(serverId.uuidString)",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        XCTAssertEqual(SecItemAdd(legacy as CFDictionary, nil), errSecSuccess)
        XCTAssertNotNil(store.load(serverId: serverId))
        try store.save(identity, serverId: other)
        XCTAssertNotNil(store.load(serverId: other))
        try store.delete(serverId: serverId)
        XCTAssertNil(store.load(serverId: serverId))
        XCTAssertNotNil(store.load(serverId: other))
    }
}
