import Foundation
import Network
import Security
import XCTest
@testable import ACPCodeTransport

/// PLAN 2.6 (FR-13): SPKI pin computation, pin parsing, and T-17 against a local TLS server.
final class SPKIPinTests: XCTestCase {
    private func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testPinMatchesOpenSSLForEachKeyType() throws {
        for name in ["rsa2048", "rsa4096", "p256", "p384"] {
            let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, try fixture(name, "der") as CFData), name)
            let expected = String(decoding: try fixture(name, "pin"), as: UTF8.self)
            XCTAssertEqual(SPKIPin.sha256(of: certificate)?.base64EncodedString(), expected, name)
        }
    }

    func testParsePins() {
        let a = Data(repeating: 1, count: 32).base64EncodedString()
        let b = Data(repeating: 2, count: 32).base64EncodedString()
        XCTAssertEqual(TransportTLSOptions.parsePins("\(a)\nsha256/\(b)"), [Data(repeating: 1, count: 32), Data(repeating: 2, count: 32)])
        XCTAssertEqual(TransportTLSOptions.parsePins("  "), [])
        XCTAssertNil(TransportTLSOptions.parsePins("not-base64"))
        XCTAssertNil(TransportTLSOptions.parsePins(Data(count: 20).base64EncodedString()), "SHA-1 length is refused")
    }

    #if os(macOS)
    // MARK: - T-17 with a real TLS server (openssl s_server, throwaway keys in a temp folder)

    private struct LocalTLS {
        let directory: URL
        let caCertificate: SecCertificate
        let serverCertificate: SecCertificate
        let server: Process
        let port: UInt16
    }

    private func run(_ args: [String], in dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        p.currentDirectoryURL = dir
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw NSError(domain: "openssl", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: args.joined(separator: " ")]) }
    }

    private func certificate(_ dir: URL, _ pem: String) throws -> SecCertificate {
        try run(["x509", "-in", pem, "-outform", "der", "-out", pem + ".der"], in: dir)
        return try XCTUnwrap(SecCertificateCreateWithData(nil, try Data(contentsOf: dir.appendingPathComponent(pem + ".der")) as CFData))
    }

    private func startLocalTLS() throws -> LocalTLS {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acpcode-t17-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        [req]
        distinguished_name = dn
        [dn]
        [ca]
        basicConstraints = critical, CA:true
        keyUsage = critical, keyCertSign, cRLSign
        [srv]
        basicConstraints = critical, CA:false
        keyUsage = critical, digitalSignature, keyEncipherment
        extendedKeyUsage = serverAuth
        subjectAltName = IP:127.0.0.1
        """.write(to: dir.appendingPathComponent("ext.cnf"), atomically: true, encoding: .utf8)
        // Named curves: Apple's Security framework does not read EC keys with explicit parameters,
        // which LibreSSL writes with `-newkey ec -pkeyopt ec_paramgen_curve:...`. LibreSSL also signs with
        // SHA-1 by default, which Apple rejects; hence -sha256.
        try run(["ecparam", "-name", "prime256v1", "-genkey", "-param_enc", "named_curve", "-noout", "-out", "ca.key"], in: dir)
        try run(["ecparam", "-name", "prime256v1", "-genkey", "-param_enc", "named_curve", "-noout", "-out", "srv.key"], in: dir)
        try run(["req", "-new", "-x509", "-sha256", "-key", "ca.key", "-out", "ca.pem", "-days", "2", "-subj", "/CN=acpcode-t17-ca", "-config", "ext.cnf", "-extensions", "ca"], in: dir)
        try run(["req", "-new", "-sha256", "-key", "srv.key", "-out", "srv.csr", "-subj", "/CN=127.0.0.1", "-config", "ext.cnf"], in: dir)
        try run(["x509", "-req", "-sha256", "-in", "srv.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-out", "srv.pem", "-days", "2", "-extfile", "ext.cnf", "-extensions", "srv"], in: dir)
        let port = UInt16.random(in: 42_000...48_000)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        server.arguments = ["s_server", "-accept", "\(port)", "-cert", "srv.pem", "-key", "srv.key", "-www", "-quiet"]
        server.currentDirectoryURL = dir
        server.standardInput = FileHandle.nullDevice
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        Thread.sleep(forTimeInterval: 0.5)
        return LocalTLS(directory: dir, caCertificate: try certificate(dir, "ca.pem"), serverCertificate: try certificate(dir, "srv.pem"), server: server, port: port)
    }

    /// Connect and classify the failure: TLS refused, or TLS passed and the WebSocket handshake failed
    /// (s_server -www answers HTTP 200, not 101).
    private enum Outcome: Equatable { case tlsRefused, tlsPassed }
    private func attempt(_ tls: LocalTLS, options: TransportTLSOptions) async -> Outcome {
        let connection = NativeWebSocketConnection(url: URL(string: "wss://127.0.0.1:\(tls.port)/")!, tls: options)
        do {
            try await connection.connect(headers: [:])
            return .tlsPassed
        } catch is NativeWebSocketConnection.NativeWebSocketError {
            return .tlsPassed
        } catch {
            print("T-17 attempt refused: \(error)")
            return .tlsRefused
        }
    }

    func testT17WrongPinFailsTheHandshake() async throws {
        let tls = try startLocalTLS()
        defer { tls.server.terminate(); try? FileManager.default.removeItem(at: tls.directory) }
        let serverPin = try XCTUnwrap(SPKIPin.sha256(of: tls.serverCertificate))
        let caPin = try XCTUnwrap(SPKIPin.sha256(of: tls.caCertificate))
        let wrongPin = Data(repeating: 0xAB, count: 32)
        // Direct trust evaluation, to tell a trust problem from a connection problem.
        var trust: SecTrust?
        SecTrustCreateWithCertificates([tls.serverCertificate] as CFArray, SecPolicyCreateSSL(true, "127.0.0.1" as CFString), &trust)
        if let trust {
            SecTrustSetAnchorCertificates(trust, [tls.caCertificate] as CFArray)
            var error: CFError?
            print("T-17 direct evaluation: \(SecTrustEvaluateWithError(trust, &error)) \(String(describing: error))")
        }

        // Control: trusted CA and the right leaf pin pass TLS.
        let right = await attempt(tls, options: TransportTLSOptions(spkiPins: [serverPin], trustAnchors: [tls.caCertificate]))
        XCTAssertEqual(right, .tlsPassed)
        // A pin on the issuing CA passes too.
        let ca = await attempt(tls, options: TransportTLSOptions(spkiPins: [caPin], trustAnchors: [tls.caCertificate]))
        XCTAssertEqual(ca, .tlsPassed)
        // T-17: a wrong pin fails the handshake, even though the chain is trusted.
        let wrong = await attempt(tls, options: TransportTLSOptions(spkiPins: [wrongPin], trustAnchors: [tls.caCertificate]))
        XCTAssertEqual(wrong, .tlsRefused)
        // A right pin does not replace trust: without the CA as anchor, the untrusted chain fails.
        let untrusted = await attempt(tls, options: TransportTLSOptions(spkiPins: [serverPin]))
        XCTAssertEqual(untrusted, .tlsRefused)
    }
    #endif
}
