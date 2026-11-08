import Foundation
import Security
import XCTest
@testable import ACPCodeTransport

#if os(macOS)
/// PLAN 2.7 live check (FR-14): connect through Caddy with mutual TLS to the gateway.
/// Opt-in. Set ACPCODE_MTLS_URL (wss://...), ACPCODE_MTLS_P12, ACPCODE_MTLS_P12_PASS,
/// ACPCODE_MTLS_ANCHOR (Caddy's root.crt, PEM or DER) and ACPCODE_MTLS_TOKEN.
/// The .p12 is imported in memory only, so the login keychain is not changed.
final class MutualTLSLiveTests: XCTestCase {
    private struct Env: @unchecked Sendable {
        let url: URL, p12: Data, pass: String, anchor: SecCertificate, token: String
    }

    private func env() throws -> Env {
        let e = ProcessInfo.processInfo.environment
        guard let u = e["ACPCODE_MTLS_URL"], let url = URL(string: u),
              let p12Path = e["ACPCODE_MTLS_P12"], let pass = e["ACPCODE_MTLS_P12_PASS"],
              let anchorPath = e["ACPCODE_MTLS_ANCHOR"], let token = e["ACPCODE_MTLS_TOKEN"] else {
            throw XCTSkip("Set ACPCODE_MTLS_* to run the live mutual TLS check (PLAN 2.7).")
        }
        var anchorData = try Data(contentsOf: URL(fileURLWithPath: anchorPath))
        if let pem = String(data: anchorData, encoding: .utf8), pem.contains("BEGIN CERTIFICATE") {
            let body = pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
            anchorData = Data(base64Encoded: body) ?? Data()
        }
        let anchor = try XCTUnwrap(SecCertificateCreateWithData(nil, anchorData as CFData))
        return Env(url: url, p12: try Data(contentsOf: URL(fileURLWithPath: p12Path)), pass: pass, anchor: anchor, token: token)
    }

    @available(macOS 15.0, *)
    private func identity(_ env: Env) throws -> SecIdentity {
        var items: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: env.pass, kSecImportToMemoryOnly as String: true]
        XCTAssertEqual(SecPKCS12Import(env.p12 as CFData, options as CFDictionary, &items), errSecSuccess)
        let first = try XCTUnwrap((items as? [[String: Any]])?.first)
        return first[kSecImportItemIdentity as String] as! SecIdentity
    }

    private enum Outcome: Equatable { case tlsRefused, http(Int), connected, timedOut }

    private func say(_ text: String) { FileHandle.standardError.write(Data("[mtls] \(text)\n".utf8)) }

    private func attempt(_ env: Env, identity: SecIdentity?, token: String?) async -> Outcome {
        say("attempt identity=\(identity != nil) token=\(token != nil)")
        let result = await Self.attemptOnce(env, identity: identity, token: token)
        say("outcome \(result)")
        return result
    }

    private struct IdentityBox: @unchecked Sendable { let value: SecIdentity? }

    private static func attemptOnce(_ env: Env, identity: SecIdentity?, token: String?) async -> Outcome {
        let tls = TransportTLSOptions(trustAnchors: [env.anchor], clientIdentity: identity)
        let connection = NativeWebSocketConnection(url: env.url, tls: tls, connectTimeout: 8)
        do {
            try await connection.connect(headers: token.map { ["Authorization": "Bearer \($0)"] } ?? [:])
            // One ACP round trip through Caddy, the gateway and the fake agent.
            try await connection.send(text: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}"#)
            let reply = try await connection.receive()
            await connection.close()
            if case .text(let text) = reply, text.contains("\"id\":1") { return .connected }
            return .http(-1)
        } catch NativeWebSocketConnection.NativeWebSocketError.invalidStatusCode(let code) {
            return .http(code)
        } catch NativeWebSocketConnection.NativeWebSocketError.connectTimeout(let state) {
            FileHandle.standardError.write(Data("[mtls] connect timeout, last state \(state)\n".utf8))
            return .timedOut
        } catch {
            FileHandle.standardError.write(Data("[mtls] error: \(error)\n".utf8))
            return .tlsRefused
        }
    }

    func testMutualTLSThroughCaddy() async throws {
        let env = try env()
        guard #available(macOS 15.0, *) else { throw XCTSkip("needs macOS 15 for an in-memory .p12 import") }
        let id = try identity(env)
        let none = await attempt(env, identity: nil, token: env.token)
        XCTAssertEqual(none, .tlsRefused, "no client certificate: the TLS handshake fails")
        let noToken = await attempt(env, identity: id, token: nil)
        XCTAssertEqual(noToken, .http(401), "certificate but no token: the gateway answers 401")
        let full = await attempt(env, identity: id, token: env.token)
        XCTAssertEqual(full, .connected, "certificate and token: an ACP initialize round-trips")
    }
}
#endif
