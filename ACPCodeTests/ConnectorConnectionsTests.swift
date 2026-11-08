import XCTest
import ACP
@testable import ACPCode
import ACPClient

/// Records each gateway call and answers the connector and session methods from fixed values.
private final class ConnectionsFakeGateway: GatewayCalling, @unchecked Sendable {
    /// Every call in order. The screen's model makes its calls one after another, so no lock is needed.
    private(set) var calls: [(method: String, params: ACP.Value?)] = []
    var pairings: [ACP.Value] = []
    var grants: [ACP.Value] = []
    var sessions: [ACP.Value] = []
    /// A failure for one method, by its name.
    var errors: [String: Error] = [:]

    func params(of method: String) -> [ACP.Value?] { calls.filter { $0.method == method }.map(\.params) }

    func gatewayCall(method: String, params: ACP.Value?) async throws -> ACP.Value {
        calls.append((method, params))
        if let error = errors[method] { throw error }
        switch method {
        case "_acpcode/connector/pending": return .object(["pairings": .array(pairings)])
        case "_acpcode/connector/grants": return .object(["grants": .array(grants)])
        case "_acpcode/sessions/index": return .object(["sessions": .array(sessions)])
        case "_acpcode/connector/approve": return .object(["grantId": .string("g-new")])
        default: return .object([:])
        }
    }
}

private func pairingValue(_ id: String, code: String = "482913") -> ACP.Value {
    .object([
        "pairingId": .string(id), "code": .string(code), "clientName": .string("Claude"),
        "requestedAt": .string("2026-11-07T10:00:00.000Z"), "expiresAt": .string("2026-11-07T10:05:00.000Z"),
    ])
}

private func grantValue(_ id: String) -> ACP.Value {
    .object([
        "grantId": .string(id), "label": .string("Claude web"),
        "scope": .object(["projects": .string("all")]), "createdAt": .string("2026-11-07T09:00:00.000Z"),
        "lastUsedAt": .string("2026-11-07T09:30:00.000Z"),
    ])
}

private func sessionValue(_ id: String, project: String, activity: String) -> ACP.Value {
    .object([
        "sessionId": .string(id), "projectId": .string(project), "title": .string("Work \(id)"),
        "status": .string("idle"), "lastActivity": .string(activity), "headSeq": .int(3), "unread": .int(0),
    ])
}

@MainActor
final class ConnectorConnectionsModelTests: XCTestCase {
    private func makeModel(_ fake: ConnectionsFakeGateway) -> GatewayConnectionsModel {
        GatewayConnectionsModel(clientProvider: { GatewayClient(fake) })
    }

    func testAPendingPairingShowsItsCodeAndClient() async {
        let fake = ConnectionsFakeGateway()
        fake.pairings = [pairingValue("p1", code: "482913")]
        let model = makeModel(fake)
        await model.refresh()
        XCTAssertEqual(model.pairings.map(\.pairingId), ["p1"])
        XCTAssertEqual(model.pairings.first?.code, "482913")
        XCTAssertEqual(model.pairings.first?.clientName, "Claude")
        XCTAssertEqual(GatewayConnectionsModel.displayCode("482913"), "482 913")
        XCTAssertEqual(fake.calls.map(\.method), ["_acpcode/connector/pending", "_acpcode/connector/grants"])
    }

    func testTimeLeftCountsDownAndSaysWhenItIsOver() {
        let expires = GatewayConnectorPairing(pairingId: "p", code: "000000", clientName: "x", requestedAt: "2026-11-07T10:00:00.000Z", expiresAt: "2026-11-07T10:05:00.000Z").expiresDate
        let now = expires!.addingTimeInterval(-90)
        XCTAssertEqual(GatewayConnectionsModel.timeLeftText(expiresAt: expires, now: now), "1:30 left")
        XCTAssertEqual(GatewayConnectionsModel.timeLeftText(expiresAt: expires, now: expires!.addingTimeInterval(1)), "Expired")
        XCTAssertEqual(GatewayConnectionsModel.timeLeftText(expiresAt: nil, now: now), "Time unknown")
    }

    func testOneSessionIsTheDefaultAndApproveSendsExactlyOneProjectAndOneSession() async {
        let fake = ConnectionsFakeGateway()
        fake.pairings = [pairingValue("p1")]
        fake.sessions = [
            sessionValue("s-old", project: "p1", activity: "2026-11-06T08:00:00.000Z"),
            sessionValue("s-new", project: "p2", activity: "2026-11-07T09:00:00.000Z"),
        ]
        let model = makeModel(fake)
        await model.refresh()
        await model.loadSessions()
        XCTAssertEqual(model.selectedSessionId, "s-new", "the newest session is picked")

        let approved = await model.approve(model.pairings[0], choice: .oneSession)
        XCTAssertTrue(approved)
        XCTAssertEqual(fake.params(of: "_acpcode/connector/approve"), [.object([
            "pairingId": .string("p1"),
            "scope": .object(["projects": .array([.string("p2")]), "sessions": .array([.string("s-new")])]),
        ])])
        XCTAssertTrue(model.pairings.isEmpty, "the approved row leaves the list")
    }

    func testAPickedSessionIsTheOneSent() async {
        let fake = ConnectionsFakeGateway()
        fake.pairings = [pairingValue("p1")]
        fake.sessions = [
            sessionValue("s-old", project: "p1", activity: "2026-11-06T08:00:00.000Z"),
            sessionValue("s-new", project: "p2", activity: "2026-11-07T09:00:00.000Z"),
        ]
        let model = makeModel(fake)
        await model.refresh()
        await model.loadSessions()
        model.selectedSessionId = "s-old"
        await model.approve(model.pairings[0], choice: .oneSession)
        let sent = fake.params(of: "_acpcode/connector/approve").first.flatMap { $0 }
        XCTAssertEqual(sent?["scope"], .object(["projects": .array([.string("p1")]), "sessions": .array([.string("s-old")])]))
    }

    func testAllProjectsSendsAllAndNoSessionList() async {
        let fake = ConnectionsFakeGateway()
        fake.pairings = [pairingValue("p1")]
        fake.sessions = [sessionValue("s-new", project: "p2", activity: "2026-11-07T09:00:00.000Z")]
        let model = makeModel(fake)
        await model.refresh()
        await model.loadSessions()
        await model.approve(model.pairings[0], choice: .allProjects)
        XCTAssertEqual(fake.params(of: "_acpcode/connector/approve"), [.object([
            "pairingId": .string("p1"),
            "scope": .object(["projects": .string("all")]),
        ])])
    }

    func testOneSessionWithNoSessionToPickSendsNothing() async {
        let fake = ConnectionsFakeGateway()
        fake.pairings = [pairingValue("p1")]
        let model = makeModel(fake)
        await model.refresh()
        await model.loadSessions()
        XCTAssertNil(model.scope(for: .oneSession))
        let approved = await model.approve(model.pairings[0], choice: .oneSession)
        XCTAssertFalse(approved)
        XCTAssertTrue(fake.params(of: "_acpcode/connector/approve").isEmpty)
    }

    func testApprovedGrantAppearsInTheGrantList() async {
        let fake = ConnectionsFakeGateway()
        fake.pairings = [pairingValue("p1")]
        fake.sessions = [sessionValue("s1", project: "p1", activity: "2026-11-07T09:00:00.000Z")]
        let model = makeModel(fake)
        await model.refresh()
        await model.loadSessions()
        fake.grants = [grantValue("g-new")]
        await model.approve(model.pairings[0], choice: .oneSession)
        XCTAssertEqual(model.grants.map(\.grantId), ["g-new"])
    }

    func testDenyRemovesTheRowAndSendsTheDenyCall() async {
        let fake = ConnectionsFakeGateway()
        fake.pairings = [pairingValue("p1"), pairingValue("p2", code: "111222")]
        let model = makeModel(fake)
        await model.refresh()
        await model.deny(model.pairings[0])
        XCTAssertEqual(fake.params(of: "_acpcode/connector/deny"), [.object(["pairingId": .string("p1")])])
        XCTAssertEqual(model.pairings.map(\.pairingId), ["p2"])
    }

    func testRevokeRemovesTheGrant() async {
        let fake = ConnectionsFakeGateway()
        fake.grants = [grantValue("g1"), grantValue("g2")]
        let model = makeModel(fake)
        await model.refresh()
        XCTAssertEqual(model.grants.count, 2)
        await model.revoke(model.grants[0])
        XCTAssertEqual(fake.params(of: "_acpcode/connector/revoke"), [.object(["grantId": .string("g1")])])
        XCTAssertEqual(model.grants.map(\.grantId), ["g2"])
    }

    func testAFailedApprovalKeepsTheRowAndSaysWhy() async {
        let fake = ConnectionsFakeGateway()
        fake.pairings = [pairingValue("p1")]
        fake.sessions = [sessionValue("s1", project: "p1", activity: "2026-11-07T09:00:00.000Z")]
        let model = makeModel(fake)
        await model.refresh()
        await model.loadSessions()
        fake.errors["_acpcode/connector/approve"] = ACPServiceError.rpc(id: .number(2), error: .serverError(code: -32001, message: "pairing expired"))
        let approved = await model.approve(model.pairings[0], choice: .oneSession)
        XCTAssertFalse(approved)
        XCTAssertEqual(model.errorMessage, "pairing expired")
    }

    func testARowAnsweredHereDoesNotComeBackOnTheNextRead() async {
        let fake = ConnectionsFakeGateway()
        fake.pairings = [pairingValue("p1")]
        let model = makeModel(fake)
        await model.refresh()
        await model.deny(model.pairings[0])
        XCTAssertTrue(model.pairings.isEmpty)
        // The gateway still lists it in a read that started before the deny landed.
        await model.refresh()
        XCTAssertTrue(model.pairings.isEmpty)
    }

    func testWithoutAGatewayTheScreenSaysSo() async {
        let model = GatewayConnectionsModel(clientProvider: { nil })
        await model.refresh()
        XCTAssertEqual(model.errorMessage, "Not connected to the gateway.")
        XCTAssertTrue(model.pairings.isEmpty)
    }
}
