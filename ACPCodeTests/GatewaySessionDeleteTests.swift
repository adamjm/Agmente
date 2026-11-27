import XCTest
import ACP
import ACPClient
@testable import ACPCode

// Deleting a gateway session: the confirmation, the call, the phone's copy, and the refusals. Every test uses a fake
// gateway and a fake record access. Nothing touches the network or Core Data.

private final class DeleteFakeGateway: GatewayCalling, @unchecked Sendable {
    var calls: [(method: String, params: ACP.Value?)] = []
    var results: [String: ACP.Value] = [:]
    var errors: [String: Error] = [:]

    func gatewayCall(method: String, params: ACP.Value?) async throws -> ACP.Value {
        calls.append((method, params))
        if let error = errors[method] { throw error }
        return results[method] ?? .null
    }

    var deleteCalls: [ACP.Value?] { calls.filter { $0.method == "_acpcode/sessions/delete" }.map(\.params) }
}

@MainActor
private final class DeleteFakeAccess: GatewayRecordAccess {
    var removed: [String] = []
    func loadSession(sessionId: String, cwd: String) async throws {}
    func removeFromPhone(sessionId: String) { removed.append(sessionId) }
}

@MainActor
final class GatewaySessionDeleteTests: XCTestCase {

    func testDeleteCallSendsTheSessionIdAndReadsBothFlags() async throws {
        let fake = DeleteFakeGateway()
        fake.results["_acpcode/sessions/delete"] = .object(["deleted": .bool(true), "agent": .bool(false)])

        let result = try await GatewayClient(fake).deleteSession(sessionId: "s1")

        XCTAssertEqual(result, GatewayDeleteResult(deleted: true, agentDeleted: false))
        XCTAssertEqual(fake.deleteCalls.first??["sessionId"]?.stringValue, "s1")
    }

    func testDeleteCallRejectsAnAnswerWithoutTheDeletedFlag() async {
        let fake = DeleteFakeGateway()
        fake.results["_acpcode/sessions/delete"] = .object([:])
        do {
            _ = try await GatewayClient(fake).deleteSession(sessionId: "s1")
            XCTFail("expected an invalid response")
        } catch {
            XCTAssertEqual(error as? GatewayError, .invalidResponse("deleted"))
        }
    }

    func testRequestingADeleteOnlyAsksAndSendsNothing() async {
        let fake = DeleteFakeGateway()
        let (actions, _) = await makeActions(fake)

        actions.requestDelete(sessionId: "s1", title: "Fix login")

        XCTAssertEqual(actions.deletion?.sessionId, "s1")
        XCTAssertEqual(actions.deletion?.title, "Fix login")
        XCTAssertTrue(fake.deleteCalls.isEmpty)
    }

    func testAnUntitledSessionIsAskedAboutAsNewChat() async {
        let (actions, _) = await makeActions(DeleteFakeGateway())
        actions.requestDelete(sessionId: "s1", title: nil)
        XCTAssertEqual(actions.deletion?.title, "New Chat")
    }

    func testConfirmingDeletesOnTheGatewayThenRemovesThePhonesCopy() async throws {
        let fake = DeleteFakeGateway()
        fake.results["_acpcode/sessions/delete"] = .object(["deleted": .bool(true), "agent": .bool(true)])
        let (actions, access) = await makeActions(fake)
        actions.requestDelete(sessionId: "s1", title: "Fix login")
        let prompt = try XCTUnwrap(actions.deletion)

        await actions.confirmDelete(prompt)

        XCTAssertEqual(fake.deleteCalls.count, 1)
        XCTAssertEqual(access.removed, ["s1"])
        XCTAssertNil(actions.deletion)
        XCTAssertNil(actions.notice)
    }

    func testARunningSessionIsRefusedAndStaysOnThePhone() async throws {
        let fake = DeleteFakeGateway()
        fake.errors["_acpcode/sessions/delete"] = GatewayError.rpc(code: -32001, message: "the session has a turn running")
        let (actions, access) = await makeActions(fake)
        actions.requestDelete(sessionId: "s1", title: "Busy")
        let prompt = try XCTUnwrap(actions.deletion)

        await actions.confirmDelete(prompt)

        XCTAssertTrue(access.removed.isEmpty, "nothing is removed when the gateway refuses")
        XCTAssertEqual(actions.notice?.message, GatewayDeleteCopy.running)
    }

    func testAGatewayThatDoesNotKnowTheSessionStillClearsThePhonesCopy() async throws {
        let fake = DeleteFakeGateway()
        fake.errors["_acpcode/sessions/delete"] = GatewayError.rpc(code: -32602, message: "unknown session")
        let (actions, access) = await makeActions(fake)
        actions.requestDelete(sessionId: "s1", title: nil)
        let prompt = try XCTUnwrap(actions.deletion)

        await actions.confirmDelete(prompt)

        XCTAssertEqual(access.removed, ["s1"])
        XCTAssertNil(actions.notice)
    }

    func testAnOldGatewayIsToldToUpdateAndNothingIsRemoved() async throws {
        let fake = DeleteFakeGateway()
        fake.errors["_acpcode/sessions/delete"] = GatewayError.rpc(code: -32601, message: "Method not found")
        let (actions, access) = await makeActions(fake)
        actions.requestDelete(sessionId: "s1", title: nil)
        let prompt = try XCTUnwrap(actions.deletion)

        await actions.confirmDelete(prompt)

        XCTAssertTrue(access.removed.isEmpty)
        XCTAssertEqual(actions.notice?.message, GatewayDeleteCopy.oldGateway)
    }

    func testADropOutKeepsTheSession() async throws {
        let fake = DeleteFakeGateway()
        fake.errors["_acpcode/sessions/delete"] = GatewayError.disconnected
        let (actions, access) = await makeActions(fake)
        actions.requestDelete(sessionId: "s1", title: nil)
        let prompt = try XCTUnwrap(actions.deletion)

        await actions.confirmDelete(prompt)

        XCTAssertTrue(access.removed.isEmpty)
        XCTAssertEqual(actions.notice?.message, "Not connected")
    }

    // MARK: - Helpers

    private func makeActions(_ fake: DeleteFakeGateway) async -> (GatewaySessionActions, DeleteFakeAccess) {
        let access = DeleteFakeAccess()
        fake.results["_acpcode/projects/list"] = .object(["projects": .array([])])
        fake.results["_acpcode/sessions/index"] = .object(["sessions": .array([])])
        let home = GatewayHomeModel()
        home.configure(serverId: nil) { GatewayClient(fake) }
        await home.refresh()
        let actions = GatewaySessionActions(
            home: home,
            client: { GatewayClient(fake) },
            records: { [] },
            pending: { [] },
            access: { access },
            reopen: { _ in }
        )
        return (actions, access)
    }
}
