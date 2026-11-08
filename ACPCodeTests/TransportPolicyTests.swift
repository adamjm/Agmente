import XCTest
@testable import ACPCode

/// T-15 (FR-11, D-018, D-019): which endpoints the app may connect to.
final class TransportPolicyTests: XCTestCase {
    private func allowed(_ url: String, localOnly: Bool, debug: Bool) -> Bool {
        TransportPolicy.check(url: URL(string: url)!, localOnly: localOnly, isDebugBuild: debug) == nil
    }

    func testT15Matrix() {
        // (url, localOnly, debug) -> allowed
        let cases: [(String, Bool, Bool, Bool)] = [
            // Hosted wss: allowed unless Local only.
            ("wss://example.com", false, false, true),
            ("wss://example.com", false, true, true),
            ("wss://example.com", true, false, false),
            ("wss://example.com", true, true, false),
            // Public ws: never.
            ("ws://example.com", false, false, false),
            ("ws://example.com", false, true, false),
            ("ws://example.com", true, false, false),
            ("ws://example.com", true, true, false),
            // Tailscale / CGNAT ws: never (D-018).
            ("ws://100.100.1.1", false, false, false),
            ("ws://100.100.1.1", false, true, false),
            ("ws://100.100.1.1", true, false, false),
            ("ws://100.100.1.1", true, true, false),
            // RFC 1918 ws: only Local only.
            ("ws://192.168.1.5", false, false, false),
            ("ws://192.168.1.5", false, true, false),
            ("ws://192.168.1.5", true, false, true),
            ("ws://192.168.1.5", true, true, true),
            // .local ws: only Local only.
            ("ws://printer.local", false, false, false),
            ("ws://printer.local", false, true, false),
            ("ws://printer.local", true, false, true),
            ("ws://printer.local", true, true, true),
            // Loopback ws: Debug, or Local only.
            ("ws://127.0.0.1", false, false, false),
            ("ws://127.0.0.1", false, true, true),
            ("ws://127.0.0.1", true, false, true),
            ("ws://127.0.0.1", true, true, true),
        ]
        for (url, localOnly, debug, expected) in cases {
            XCTAssertEqual(allowed(url, localOnly: localOnly, debug: debug), expected,
                           "\(url) localOnly=\(localOnly) debug=\(debug)")
        }
    }

    func testHostClassesAreStrict() {
        XCTAssertTrue(TransportPolicy.isLoopback("localhost"))
        XCTAssertTrue(TransportPolicy.isLoopback("[::1]"))
        XCTAssertTrue(TransportPolicy.isLoopback("127.8.9.10"))
        XCTAssertFalse(TransportPolicy.isLoopback("127.0.0.1.evil.com"))
        XCTAssertFalse(TransportPolicy.isLoopback("localhost.evil.com"))
        XCTAssertTrue(TransportPolicy.isLocal("10.0.0.1"))
        XCTAssertTrue(TransportPolicy.isLocal("172.16.0.1"))
        XCTAssertTrue(TransportPolicy.isLocal("172.31.255.255"))
        XCTAssertFalse(TransportPolicy.isLocal("172.32.0.1"))
        XCTAssertFalse(TransportPolicy.isLocal("192.169.0.1"))
        XCTAssertFalse(TransportPolicy.isLocal("10.0.0.1.nip.io"))
        XCTAssertFalse(TransportPolicy.isLocal(".local"))
        XCTAssertFalse(TransportPolicy.isLocal("fd00::1"))
        XCTAssertFalse(TransportPolicy.isLocal("0x7f.0.0.1"))
        XCTAssertNil(TransportPolicy.ipv4Octets("127.1"))
        XCTAssertNil(TransportPolicy.ipv4Octets("256.0.0.1"))
    }

    func testIPv6LoopbackURL() {
        XCTAssertTrue(allowed("ws://[::1]:8787/", localOnly: false, debug: true))
        XCTAssertFalse(allowed("ws://[::1]:8787/", localOnly: false, debug: false))
    }

    func testUnsupportedSchemeIsRefused() {
        XCTAssertEqual(TransportPolicy.check(url: URL(string: "http://example.com")!, localOnly: false, isDebugBuild: true),
                       .unsupportedScheme("http"))
    }
}
