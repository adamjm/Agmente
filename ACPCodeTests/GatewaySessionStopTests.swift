import XCTest
import ACP
import ACPClient
@testable import ACPCode

// D-106: stopping gateway sessions, the stalled flag, the unknown-session recovery and the phone-only check.
// Every test uses a fake gateway and a fake record access. Nothing touches the network or Core Data.

private final class StopFakeGateway: GatewayCalling, @unchecked Sendable {
    var calls: [(method: String, params: ACP.Value?)] = []
    var results: [String: ACP.Value] = [:]
    var errors: [String: Error] = [:]

    func gatewayCall(method: String, params: ACP.Value?) async throws -> ACP.Value {
        calls.append((method, params))
        if let error = errors[method] { throw error }
        return results[method] ?? .null
    }

    /// The params of each `_acpcode/sessions/stop` call, in order.
    var stopParams: [ACP.Value?] {
        calls.filter { $0.method == "_acpcode/sessions/stop" }.map(\.params)
    }
}

@MainActor
private final class FakeRecordAccess: GatewayRecordAccess {
    var loadError: Error?
    var loads: [(sessionId: String, cwd: String)] = []
    var removed: [String] = []

    func loadSession(sessionId: String, cwd: String) async throws {
        loads.append((sessionId, cwd))
        if let loadError { throw loadError }
    }

    func removeFromPhone(sessionId: String) {
        removed.append(sessionId)
    }
}

private func row(_ id: String, project: String = "p1", status: String = "idle", title: String? = nil, stalled: Bool? = nil) -> ACP.Value {
    var object: [String: ACP.Value] = [
        "sessionId": .string(id),
        "projectId": .string(project),
        "title": title.map { ACP.Value.string($0) } ?? ACP.Value.null,
        "status": .string(status),
        "lastActivity": .string("2026-11-08T10:00:00.000Z"),
        "headSeq": .int(1),
        "unread": .int(0),
    ]
    if let stalled { object["stalled"] = .bool(stalled) }
    return .object(object)
}

private func stopResult(_ outcome: String, _ stopped: [String] = []) -> ACP.Value {
    .object(["outcome": .string(outcome), "stoppedSessions": .array(stopped.map { ACP.Value.string($0) })])
}

private let project = "p1"

@MainActor
final class GatewaySessionStopTests: XCTestCase {

    // MARK: - Outcome decoding

    func testEveryOutcomeDecodesAndAnUnknownOneIsKept() async throws {
        let cases: [(String, GatewayStopOutcome)] = [
            ("not_running", .notRunning), ("cancelled", .cancelled), ("still_running", .stillRunning),
            ("stopped", .stopped), ("from_a_newer_gateway", .unknown("from_a_newer_gateway")),
        ]
        for (raw, expected) in cases {
            let fake = StopFakeGateway()
            fake.results["_acpcode/sessions/stop"] = stopResult(raw, ["s1"])
            let result = try await GatewayClient(fake).stopSession(sessionId: "s1", scope: .turn)
            XCTAssertEqual(result.outcome, expected, raw)
            XCTAssertEqual(result.stoppedSessions, ["s1"], raw)
        }
    }

    func testAnAnswerWithNoOutcomeIsAnInvalidResponse() async {
        let fake = StopFakeGateway()
        fake.results["_acpcode/sessions/stop"] = .object([:])
        do {
            _ = try await GatewayClient(fake).stopSession(sessionId: "s1", scope: .turn)
            XCTFail("expected an invalid response")
        } catch {
            XCTAssertEqual(error as? GatewayError, .invalidResponse("outcome"))
        }
    }

    func testTheBusyElsewhereRefusalKeepsItsCode() async {
        let fake = StopFakeGateway()
        fake.errors["_acpcode/sessions/stop"] = ACPServiceError.rpc(id: .number(1), error: .serverError(code: -32001, message: "other sessions are running in this project"))
        do {
            _ = try await GatewayClient(fake).stopSession(sessionId: "s1", scope: .agent)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? GatewayError, .rpc(code: -32001, message: "other sessions are running in this project"))
        }
    }

    // MARK: - Stalled badge

    func testTheStalledFlagComesFromTheIndexAndIsAbsentForOlderGateways() throws {
        func decode(_ json: String) throws -> GatewaySession {
            try JSONDecoder().decode(GatewaySession.self, from: Data(json.utf8))
        }
        let base = #""sessionId":"s1","projectId":"p1","title":null,"status":"running","lastActivity":"2026-11-08T10:00:00.000Z","headSeq":1,"unread":0"#
        XCTAssertTrue(GatewayStopRules.showsStalledBadge(try decode("{\(base),\"stalled\":true}")))
        XCTAssertFalse(GatewayStopRules.showsStalledBadge(try decode("{\(base),\"stalled\":false}")))
        XCTAssertFalse(GatewayStopRules.showsStalledBadge(try decode("{\(base)}")), "an older gateway sends no flag")
    }

    func testTheStalledBadgeFollowsTheFlagAlone() {
        let stalled = GatewaySession(sessionId: "s1", projectId: project, title: nil, status: .running, lastActivity: "2026-11-08T10:00:00.000Z", headSeq: 1, unread: 0, stalled: true)
        let idle = GatewaySession(sessionId: "s2", projectId: project, title: nil, status: .idle, lastActivity: "2026-11-08T10:00:00.000Z", headSeq: 1, unread: 0, stalled: nil)
        XCTAssertTrue(GatewayStopRules.showsStalledBadge(stalled))
        XCTAssertFalse(GatewayStopRules.showsStalledBadge(idle))
    }

    // MARK: - The force gate

    func testAStopTurnSendsScopeTurnAndNeverForce() async throws {
        let fake = StopFakeGateway()
        fake.results["_acpcode/sessions/stop"] = stopResult("cancelled", ["s1"])
        let result = try await GatewaySessionStop.stopTurn(GatewayClient(fake), sessionId: "s1")
        XCTAssertEqual(result.outcome, .cancelled)
        let params = try XCTUnwrap(fake.stopParams.first ?? nil)
        XCTAssertEqual(params["scope"]?.stringValue, "turn")
        XCTAssertNil(params["force"])
    }

    func testRequestingAnAgentStopReadsTheSessionsAndSendsNoStop() async {
        let fake = StopFakeGateway()
        fake.results["_acpcode/sessions/index"] = .object(["sessions": .array([row("s1", status: "running"), row("s2", status: "running", title: "Build")])])
        let (actions, _, _) = await makeActions(fake)

        await actions.requestAgentStop(sessionId: "s1")

        XCTAssertEqual(actions.agentStop?.candidates.map(\.sessionId), ["s2"], "the other running session is listed")
        XCTAssertTrue(fake.stopParams.isEmpty, "no stop is sent before the person confirms")
    }

    func testAConfirmedAgentStopSendsForceOnlyForSessionsThePersonWasShown() async throws {
        let fake = StopFakeGateway()
        fake.results["_acpcode/sessions/index"] = .object(["sessions": .array([row("s1", status: "running"), row("s2", status: "running")])])
        fake.results["_acpcode/sessions/stop"] = stopResult("stopped", ["s1", "s2"])
        let (actions, _, _) = await makeActions(fake)
        await actions.requestAgentStop(sessionId: "s1")
        XCTAssertTrue(fake.stopParams.isEmpty)

        await actions.confirmAgentStop()

        let params = try XCTUnwrap(fake.stopParams.first ?? nil)
        XCTAssertEqual(params["scope"]?.stringValue, "agent")
        XCTAssertEqual(params["force"]?.boolValue, true, "the other session was shown, so force is sent")
        XCTAssertNil(actions.agentStop, "the prompt is closed after the stop")
    }

    func testAgentStopWithNoOtherSessionsSendsNoForce() async throws {
        let fake = StopFakeGateway()
        fake.results["_acpcode/sessions/index"] = .object(["sessions": .array([row("s1", status: "running")])])
        fake.results["_acpcode/sessions/stop"] = stopResult("stopped", ["s1"])
        let (actions, _, _) = await makeActions(fake)
        await actions.requestAgentStop(sessionId: "s1")
        XCTAssertEqual(actions.agentStop?.candidates, [], "the prompt still asks, even with nobody else running")

        await actions.confirmAgentStop()

        let params = try XCTUnwrap(fake.stopParams.first ?? nil)
        XCTAssertNil(params["force"])
    }

    func testASessionThatStartedAfterTheListWasShownAsksAgainAndSendsNothing() async {
        let fake = StopFakeGateway()
        fake.results["_acpcode/sessions/index"] = .object(["sessions": .array([row("s1", status: "running"), row("s2", status: "running")])])
        let (actions, _, _) = await makeActions(fake)
        await actions.requestAgentStop(sessionId: "s1")

        // A third session starts before the person confirms.
        fake.results["_acpcode/sessions/index"] = .object(["sessions": .array([row("s1", status: "running"), row("s2", status: "running"), row("s3", status: "awaiting_approval")])])
        await actions.confirmAgentStop()

        XCTAssertTrue(fake.stopParams.isEmpty, "nothing is stopped when the list changed")
        XCTAssertEqual(actions.agentStop?.candidates.map(\.sessionId), ["s2", "s3"], "the new list is shown again")
    }

    func testTheConfirmationRuleForcesOnlyWhatWasShown() {
        let s2 = GatewayStopCandidate(sessionId: "s2", title: "Build", status: .running)
        let s3 = GatewayStopCandidate(sessionId: "s3", title: "Tests", status: .running)
        XCTAssertEqual(GatewayStopRules.confirmation(shown: [s2], now: [s2]), .send(force: true))
        XCTAssertEqual(GatewayStopRules.confirmation(shown: [], now: []), .send(force: false))
        XCTAssertEqual(GatewayStopRules.confirmation(shown: [s2], now: [s2, s3]), .listChanged([s2, s3]))
        XCTAssertEqual(GatewayStopRules.confirmation(shown: [], now: [s2]), .listChanged([s2]))
    }

    func testAStopTurnThatDoesNotEndOffersTheAgentStop() async {
        let fake = StopFakeGateway()
        fake.results["_acpcode/sessions/stop"] = stopResult("still_running")
        fake.results["_acpcode/sessions/index"] = .object(["sessions": .array([row("s1", status: "running"), row("s2", status: "running")])])
        let (actions, _, _) = await makeActions(fake)

        await actions.stopTurn(sessionId: "s1")

        XCTAssertEqual(actions.agentStop?.candidates.map(\.sessionId), ["s2"])
        XCTAssertEqual(fake.stopParams.count, 1, "only the turn stop was sent")
    }

    // MARK: - Unknown session

    func testASessionTheGatewayDoesNotKnowIsReattachedFirst() async {
        let access = FakeRecordAccess()
        let outcome = await GatewayUnknownSession.resolve(sessionId: "s1", cwd: "/srv/site", access: access)
        XCTAssertEqual(outcome, .reattached)
        XCTAssertEqual(access.loads.map(\.sessionId), ["s1"])
        XCTAssertEqual(access.loads.map(\.cwd), ["/srv/site"])
        XCTAssertTrue(access.removed.isEmpty)
    }

    func testRemovalIsOfferedOnlyWhenTheLoadFails() async {
        let access = FakeRecordAccess()
        access.loadError = GatewayError.rpc(code: -32000, message: "session not found")
        let outcome = await GatewayUnknownSession.resolve(sessionId: "s1", cwd: "/srv/site", access: access)
        XCTAssertEqual(outcome, .offerRemoval)
        XCTAssertEqual(access.loads.count, 1, "the load was tried first")
        XCTAssertTrue(access.removed.isEmpty, "resolving never removes anything")
    }

    func testWithoutACwdThereIsNothingToLoadSoRemovalIsOffered() async {
        let access = FakeRecordAccess()
        let outcome = await GatewayUnknownSession.resolve(sessionId: "s1", cwd: nil, access: access)
        XCTAssertEqual(outcome, .offerRemoval)
        XCTAssertTrue(access.loads.isEmpty)
    }

    func testOnlyAnInvalidParamsAnswerIsTakenAsUnknown() {
        XCTAssertTrue(GatewayUnknownSession.isUnknown(GatewayError.rpc(code: -32602, message: "unknown session")))
        XCTAssertFalse(GatewayUnknownSession.isUnknown(GatewayError.rpc(code: -32001, message: "answered elsewhere")))
        XCTAssertFalse(GatewayUnknownSession.isUnknown(GatewayError.disconnected))
    }

    func testTheRecoveryReattachesAndReopensWithoutAskingWhenTheLoadWorks() async {
        let fake = StopFakeGateway()
        fake.results["_acpcode/sessions/index"] = .object(["sessions": .array([])])
        let access = FakeRecordAccess()
        var reopened: [String] = []
        let (actions, _, _) = await makeActions(fake, records: [record("s1", cwd: "/srv/site")], access: access, reopened: { reopened.append($0) })

        await actions.sessionUnknown("s1")

        XCTAssertEqual(reopened, ["s1"])
        XCTAssertNil(actions.removal)
        XCTAssertTrue(access.removed.isEmpty)
    }

    func testTheRecoveryOffersRemovalAndRemovesOnlyAfterConfirmation() async {
        let fake = StopFakeGateway()
        fake.results["_acpcode/sessions/index"] = .object(["sessions": .array([])])
        let access = FakeRecordAccess()
        access.loadError = GatewayError.rpc(code: -32000, message: "gone")
        let (actions, _, _) = await makeActions(fake, records: [record("s1", cwd: "/srv/site", title: "Old")], access: access)

        await actions.sessionUnknown("s1")

        XCTAssertEqual(actions.removal?.sessionId, "s1")
        XCTAssertEqual(actions.removal?.title, "Old")
        XCTAssertTrue(access.removed.isEmpty, "nothing is removed before the person confirms")

        actions.confirmRemoval()

        XCTAssertEqual(access.removed, ["s1"])
        XCTAssertNil(actions.removal)
    }

    func testARecoveryThatLoadsButStillFailsDoesNotLoopAndOffersRemoval() async {
        let fake = StopFakeGateway()
        fake.results["_acpcode/sessions/index"] = .object(["sessions": .array([])])
        let access = FakeRecordAccess()
        var reopened: [String] = []
        let (actions, _, _) = await makeActions(fake, records: [record("s1", cwd: "/srv/site")], access: access, reopened: { reopened.append($0) })

        await actions.sessionUnknown("s1")
        await actions.sessionUnknown("s1")

        XCTAssertEqual(reopened, ["s1"], "the second unknown answer does not load again")
        XCTAssertEqual(access.loads.count, 1)
        XCTAssertEqual(actions.removal?.sessionId, "s1")
    }

    func testTheUnknownSessionFlowNeverSendsSessionDelete() async {
        let fake = StopFakeGateway()
        fake.results["_acpcode/sessions/index"] = .object(["sessions": .array([])])
        let access = FakeRecordAccess()
        access.loadError = GatewayError.rpc(code: -32000, message: "gone")
        let (actions, _, _) = await makeActions(fake, records: [record("s1", cwd: "/srv/site")], access: access)

        await actions.sessionUnknown("s1")
        actions.confirmRemoval()

        XCTAssertFalse(fake.calls.contains { $0.method.contains("delete") }, "session/delete is never sent for a record the gateway does not know")
        XCTAssertEqual(access.removed, ["s1"], "the phone's copy is removed, and only that")
    }

    // MARK: - Phone-only check

    func testOrphansAreLocalRecordsTheGatewayDoesNotListNewestFirst() {
        let now = Date(timeIntervalSince1970: 1_000)
        let local = [
            StoredSessionInfo(sessionId: "a", title: "A", cwd: "/srv/a", updatedAt: now.addingTimeInterval(-10)),
            StoredSessionInfo(sessionId: "b", title: "B", cwd: "/srv/b", updatedAt: now),
            StoredSessionInfo(sessionId: "c", title: "C", cwd: "/srv/c", updatedAt: now),
            StoredSessionInfo(sessionId: "d", title: "D", cwd: "/srv/d", updatedAt: now),
            StoredSessionInfo(sessionId: "", title: nil, cwd: nil, updatedAt: now),
        ]
        let orphans = GatewayOrphanSessions.find(local: local, gatewayIds: ["c"], pending: ["d"])
        XCTAssertEqual(orphans.map(\.sessionId), ["b", "a"], "newest first, ties by id; listed and pending ones are left out")
    }

    func testThePhoneOnlyListReadsTheIndexAndChangesNothing() async throws {
        let fake = StopFakeGateway()
        fake.results["_acpcode/sessions/index"] = .object(["sessions": .array([row("a")])])
        let access = FakeRecordAccess()
        let (actions, _, _) = await makeActions(fake, records: [record("a", cwd: "/srv"), record("b", cwd: "/srv")], access: access)

        let orphans = try await actions.phoneOnlyRecords()

        XCTAssertEqual(orphans.map(\.sessionId), ["b"])
        XCTAssertTrue(access.removed.isEmpty)
        XCTAssertFalse(fake.calls.contains { $0.method.contains("delete") })
    }

    // MARK: - Helpers

    private func record(_ id: String, cwd: String?, title: String? = nil) -> StoredSessionInfo {
        StoredSessionInfo(sessionId: id, title: title, cwd: cwd, updatedAt: nil)
    }

    /// Actions over a home loaded from `fake`, with the given local records and record access.
    private func makeActions(
        _ fake: StopFakeGateway,
        records: [StoredSessionInfo] = [],
        access: FakeRecordAccess? = nil,
        reopened: @escaping (String) -> Void = { _ in }
    ) async -> (GatewaySessionActions, GatewayHomeModel, FakeRecordAccess) {
        let access = access ?? FakeRecordAccess()
        fake.results["_acpcode/projects/list"] = .object(["projects": .array([])])
        let home = GatewayHomeModel()
        home.configure(serverId: nil) { GatewayClient(fake) }
        await home.refresh()
        let actions = GatewaySessionActions(
            home: home,
            client: { GatewayClient(fake) },
            records: { records },
            pending: { [] },
            access: { access },
            reopen: reopened
        )
        return (actions, home, access)
    }
}
