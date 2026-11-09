import XCTest
import ACP
@testable import ACPClient

/// Records each gateway call and answers from `results`, or fails with `error`: the transport for these tests.
private final class ConnectorFakeTransport: GatewayCalling, @unchecked Sendable {
    var calls: [(method: String, params: ACP.Value?)] = []
    var results: [String: ACP.Value] = [:]
    var error: Error?

    func gatewayCall(method: String, params: ACP.Value?) async throws -> ACP.Value {
        calls.append((method, params))
        if let error { throw error }
        return results[method] ?? .null
    }
}

private func pairingValue(_ id: String, code: String = "482913", client: String = "Claude") -> ACP.Value {
    .object([
        "pairingId": .string(id), "code": .string(code), "clientName": .string(client),
        "requestedAt": .string("2026-11-07T10:00:00.000Z"), "expiresAt": .string("2026-11-07T10:05:00.000Z"),
    ])
}

private func grantValue(_ id: String, scope: ACP.Value, lastUsed: ACP.Value = .null) -> ACP.Value {
    .object([
        "grantId": .string(id), "label": .string("Claude web"), "scope": scope,
        "createdAt": .string("2026-11-07T10:00:00.000Z"), "lastUsedAt": lastUsed,
    ])
}

final class GatewayConnectorClientTests: XCTestCase {
    func testPendingDecodesEveryPairingAndSendsNoParams() async throws {
        let transport = ConnectorFakeTransport()
        transport.results["_acpcode/connector/pending"] = .object(["pairings": .array([pairingValue("p1"), pairingValue("p2", code: "000111", client: "Other")])])
        let pairings = try await GatewayClient(transport).connectorPending()
        XCTAssertEqual(pairings.map(\.pairingId), ["p1", "p2"])
        XCTAssertEqual(pairings[0].code, "482913")
        XCTAssertEqual(pairings[0].clientName, "Claude")
        XCTAssertEqual(pairings[1].clientName, "Other")
        XCTAssertEqual(pairings[0].expiresDate, Date(timeIntervalSince1970: 1_794_045_900), "the gateway's millisecond time parses")
        XCTAssertEqual(transport.calls.map(\.method), ["_acpcode/connector/pending"])
        XCTAssertEqual(transport.calls.first?.params, .object([:]))
    }

    func testApproveSendsOneProjectAndOneSessionAndReturnsTheGrantId() async throws {
        let transport = ConnectorFakeTransport()
        transport.results["_acpcode/connector/approve"] = .object(["grantId": .string("g1")])
        let session = GatewaySession(sessionId: "s9", projectId: "proj-a", title: "Fix", status: .idle, lastActivity: "2026-11-07T10:00:00.000Z", headSeq: 1, unread: 0)
        let grantId = try await GatewayClient(transport).approveConnectorPairing(pairingId: "p1", code: "482913", scope: .oneSession(session))
        XCTAssertEqual(grantId, "g1")
        XCTAssertEqual(transport.calls.map(\.method), ["_acpcode/connector/approve"])
        XCTAssertEqual(transport.calls.first?.params, .object([
            "pairingId": .string("p1"),
            "scope": .object(["projects": .array([.string("proj-a")]), "sessions": .array([.string("s9")])]),
            "code": .string("482913"),
        ]))
    }

    func testApproveRequestCarriesTheCode() async throws {
        let transport = ConnectorFakeTransport()
        transport.results["_acpcode/connector/approve"] = .object(["grantId": .string("g3")])
        _ = try await GatewayClient(transport).approveConnectorPairing(pairingId: "p1", code: "000111", scope: .allProjects)
        XCTAssertEqual(transport.calls.first?.params?["code"], .string("000111"))
        XCTAssertEqual(transport.calls.first?.params?["pairingId"], .string("p1"))
    }

    func testApproveAllProjectsSendsTheWordAllAndNoSessionList() async throws {
        let transport = ConnectorFakeTransport()
        transport.results["_acpcode/connector/approve"] = .object(["grantId": .string("g2")])
        let grantId = try await GatewayClient(transport).approveConnectorPairing(pairingId: "p1", code: "482913", scope: .allProjects)
        XCTAssertEqual(grantId, "g2")
        XCTAssertEqual(transport.calls.first?.params, .object([
            "pairingId": .string("p1"),
            "scope": .object(["projects": .string("all")]),
            "code": .string("482913"),
        ]))
    }

    func testAnEmptyCodeIsRefusedLocallyWithNothingSent() async {
        let transport = ConnectorFakeTransport()
        transport.results["_acpcode/connector/approve"] = .object(["grantId": .string("g4")])
        for code in ["", "   "] {
            do {
                _ = try await GatewayClient(transport).approveConnectorPairing(pairingId: "p1", code: code, scope: .allProjects)
                XCTFail("an empty code must not be sent")
            } catch {
                XCTAssertEqual(error as? GatewayError, .missingPairingCode)
                XCTAssertEqual((error as? GatewayError)?.message, "This pairing has no code, so it was not approved. Refresh the list and try again.")
            }
        }
        XCTAssertTrue(transport.calls.isEmpty, "no request reaches the gateway for an empty code")
    }

    func testApproveWithoutAGrantIdIsNamed() async {
        let transport = ConnectorFakeTransport()
        transport.results["_acpcode/connector/approve"] = .object([:])
        do {
            _ = try await GatewayClient(transport).approveConnectorPairing(pairingId: "p1", code: "482913", scope: .allProjects)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? GatewayError, .invalidResponse("grantId"))
        }
    }

    func testDenySendsNoCode() async throws {
        let transport = ConnectorFakeTransport()
        try await GatewayClient(transport).denyConnectorPairing(pairingId: "p3")
        XCTAssertEqual(transport.calls.first?.params, .object(["pairingId": .string("p3")]))
        XCTAssertNil(transport.calls.first?.params?["code"], "deny takes no code")
    }

    func testDenySendsThePairingIdAndNeedsNoAnswerBody() async throws {
        let transport = ConnectorFakeTransport()
        try await GatewayClient(transport).denyConnectorPairing(pairingId: "p3")
        XCTAssertEqual(transport.calls.map(\.method), ["_acpcode/connector/deny"])
        XCTAssertEqual(transport.calls.first?.params, .object(["pairingId": .string("p3")]))
    }

    func testGrantsDecodeBothScopeShapesAndLastUse() async throws {
        let transport = ConnectorFakeTransport()
        transport.results["_acpcode/connector/grants"] = .object(["grants": .array([
            grantValue("g1", scope: .object(["projects": .string("all")]), lastUsed: .string("2026-11-07T10:02:00.000Z")),
            grantValue("g2", scope: .object(["projects": .array([.string("a")]), "sessions": .array([.string("s1")])])),
        ])])
        let grants = try await GatewayClient(transport).connectorGrants()
        XCTAssertEqual(grants.map(\.grantId), ["g1", "g2"])
        XCTAssertEqual(grants[0].scope, .allProjects)
        XCTAssertEqual(grants[0].scope.summary, "All projects")
        XCTAssertEqual(grants[0].lastUsedDate, Date(timeIntervalSince1970: 1_794_045_720), "last use is a date")
        XCTAssertNil(grants[1].lastUsedAt, "a grant never used has no last use")
        XCTAssertEqual(grants[1].scope, GatewayConnectorScope(projects: .some(["a"]), sessions: ["s1"]))
        XCTAssertEqual(grants[1].scope.summary, "1 project · 1 session")
        XCTAssertEqual(transport.calls.first?.params, .object([:]))
    }

    func testAGrantWithAScopeTheAppDoesNotKnowIsNamed() async {
        let transport = ConnectorFakeTransport()
        transport.results["_acpcode/connector/grants"] = .object(["grants": .array([
            grantValue("g1", scope: .object(["projects": .string("some")])),
        ])])
        do {
            _ = try await GatewayClient(transport).connectorGrants()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? GatewayError, .invalidResponse("grants"))
        }
    }

    func testRevokeSendsTheGrantId() async throws {
        let transport = ConnectorFakeTransport()
        try await GatewayClient(transport).revokeConnectorGrant(grantId: "g1")
        XCTAssertEqual(transport.calls.map(\.method), ["_acpcode/connector/revoke"])
        XCTAssertEqual(transport.calls.first?.params, .object(["grantId": .string("g1")]))
    }

    func testEachCallKeepsAGatewayErrorCodeAndText() async {
        let transport = ConnectorFakeTransport()
        transport.error = ACPServiceError.rpc(id: .number(4), error: .serverError(code: -32001, message: "pairing already closed"))
        let calls: [(String, () async throws -> Void)] = [
            ("pending", { _ = try await GatewayClient(transport).connectorPending() }),
            ("approve", { _ = try await GatewayClient(transport).approveConnectorPairing(pairingId: "p1", code: "482913", scope: .allProjects) }),
            ("deny", { try await GatewayClient(transport).denyConnectorPairing(pairingId: "p1") }),
            ("grants", { _ = try await GatewayClient(transport).connectorGrants() }),
            ("revoke", { try await GatewayClient(transport).revokeConnectorGrant(grantId: "g1") }),
        ]
        for (name, call) in calls {
            do {
                try await call()
                XCTFail("\(name) should throw")
            } catch {
                XCTAssertEqual(error as? GatewayError, .rpc(code: -32001, message: "pairing already closed"), name)
                XCTAssertEqual((error as? GatewayError)?.message, "pairing already closed", name)
            }
        }
        XCTAssertEqual(transport.calls.map(\.method), [
            "_acpcode/connector/pending", "_acpcode/connector/approve", "_acpcode/connector/deny",
            "_acpcode/connector/grants", "_acpcode/connector/revoke",
        ])
    }

    func testADisconnectIsReportedByEachCall() async {
        let transport = ConnectorFakeTransport()
        transport.error = ACPServiceError.disconnected
        do {
            _ = try await GatewayClient(transport).connectorPending()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? GatewayError, .disconnected)
        }
        do {
            try await GatewayClient(transport).revokeConnectorGrant(grantId: "g1")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? GatewayError, .disconnected)
        }
    }

    func testAPendingAnswerWithTheWrongShapeIsNamed() async {
        let transport = ConnectorFakeTransport()
        transport.results["_acpcode/connector/pending"] = .object(["pairings": .string("none")])
        do {
            _ = try await GatewayClient(transport).connectorPending()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? GatewayError, .invalidResponse("pairings"))
        }
    }
}

final class GatewayConnectorScopeTests: XCTestCase {
    private let session = GatewaySession(sessionId: "s9", projectId: "proj-a", title: "Fix", status: .idle, lastActivity: "2026-11-07T10:00:00.000Z", headSeq: 1, unread: 0)

    /// The one-session scope names exactly one project and exactly one session, and never "all".
    /// This is the path the app's approve sheet uses by default, so a change here fails the app test too.
    func testOneSessionScopeIsOneProjectAndOneSession() {
        let scope = GatewayConnectorScope.oneSession(session)
        XCTAssertEqual(scope.projects, .some(["proj-a"]))
        XCTAssertEqual(scope.sessions, ["s9"])
        XCTAssertNotEqual(scope.projects, .all)
        XCTAssertEqual(scope.value, .object(["projects": .array([.string("proj-a")]), "sessions": .array([.string("s9")])]))
    }

    func testAllProjectsScopeSendsAllAndNoSessions() {
        XCTAssertEqual(GatewayConnectorScope.allProjects.value, .object(["projects": .string("all")]))
        XCTAssertEqual(GatewayConnectorScope.allProjects.summary, "All projects")
    }

    func testScopeRoundTripsThroughJSON() throws {
        for scope in [GatewayConnectorScope.allProjects, GatewayConnectorScope.oneSession(session), GatewayConnectorScope(projects: .some(["a", "b"]), sessions: nil)] {
            let data = try JSONEncoder().encode(scope)
            XCTAssertEqual(try JSONDecoder().decode(GatewayConnectorScope.self, from: data), scope)
        }
    }

    func testSummariesCountProjectsAndSessions() {
        XCTAssertEqual(GatewayConnectorScope(projects: .some(["a"]), sessions: nil).summary, "1 project")
        XCTAssertEqual(GatewayConnectorScope(projects: .some(["a", "b"]), sessions: ["s1", "s2"]).summary, "2 projects · 2 sessions")
    }
}
