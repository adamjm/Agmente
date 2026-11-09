import XCTest
import ACP
@testable import ACPCode
import ACPClient

/// A gateway that answers by method name and records every call.
private final class SendFakeGateway: GatewayCalling, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(method: String, params: ACP.Value?)] = []
    var handlers: [String: (ACP.Value?) throws -> ACP.Value] = [:]

    var methods: [String] { lock.lock(); defer { lock.unlock() }; return recorded.map(\.method) }
    func count(_ method: String) -> Int { methods.filter { $0 == method }.count }
    func params(for method: String) -> [ACP.Value] {
        lock.lock(); defer { lock.unlock() }
        return recorded.filter { $0.method == method }.compactMap(\.params)
    }

    func gatewayCall(method: String, params: ACP.Value?) async throws -> ACP.Value {
        lock.lock()
        recorded.append((method, params))
        let handler = handlers[method]
        lock.unlock()
        guard let handler else { return .null }
        return try handler(params)
    }
}

/// The app's side of the sender, as a fake. It records every call that could change the app's state.
@MainActor
private final class SendFakeHost: AgentSessionHost {
    var selectedServerID: UUID?
    var connectCount = 0
    var connect: (() async throws -> GatewayClient)?
    var selectCalls: [UUID] = []

    func connectSelectedGateway() async throws -> GatewayClient {
        connectCount += 1
        guard let connect else { throw AgentSessionError.unreachable }
        return try await connect()
    }

    func selectServer(_ id: UUID) {
        selectCalls.append(id)
    }
}

@MainActor
final class SendToAgentSessionTests: XCTestCase {
    private let serverID = UUID(uuidString: "5F1C2E0A-7B7B-4C1D-9C3E-2A4B6D8F0A11")!
    private let otherServerID = UUID(uuidString: "0A0B0C0D-1111-2222-3333-444455556666")!
    private let prompt = "Refactor the parser and keep the tests green"
    private let secret = "the-secret-launch-code-4417"

    private func session(_ id: String, title: String?) -> ACP.Value {
        var row: [String: ACP.Value] = [
            "sessionId": .string(id), "projectId": .string("a1"), "status": .string("idle"),
            "lastActivity": .string("2026-11-09T08:00:00.000Z"), "headSeq": .int(4), "unread": .int(0),
        ]
        if let title { row["title"] = .string(title) }
        return .object(row)
    }

    /// A gateway with one session, `s-1`, that accepts a prompt with turn `t-7`.
    private func healthyGateway() -> SendFakeGateway {
        let gateway = SendFakeGateway()
        gateway.handlers["_acpcode/sessions/index"] = { _ in .object(["sessions": .array([self.session("s-1", title: "Fix build")])]) }
        gateway.handlers["_acpcode/sessions/prompt"] = { _ in .object(["turnId": .string("t-7"), "status": .string("accepted")]) }
        return gateway
    }

    private func host(_ gateway: SendFakeGateway, selected: UUID? = nil) -> SendFakeHost {
        let host = SendFakeHost()
        host.selectedServerID = selected ?? serverID
        let client = GatewayClient(gateway)
        host.connect = { client }
        return host
    }

    private func target(_ sessionId: String = "s-1", on server: UUID? = nil) -> AgentSessionTarget {
        AgentSessionTarget(serverID: server ?? serverID, sessionId: sessionId)
    }

    private func sender(_ host: SendFakeHost, connect: Duration = .seconds(10)) -> AgentSessionSender {
        AgentSessionSender(host: host, connectDeadline: connect)
    }

    // MARK: - Accepted

    func testAnAcceptedSendReturnsItsTurnAndSendsOneTextPrompt() async throws {
        let gateway = healthyGateway()
        let host = host(gateway)
        let outcome = try await sender(host).send(prompt: prompt, to: target())
        XCTAssertEqual(outcome.status, .accepted)
        XCTAssertEqual(outcome.turnId, "t-7")
        XCTAssertEqual(outcome.sessionId, "s-1")
        XCTAssertEqual(outcome.entityID, "\(serverID.uuidString)/s-1")
        XCTAssertNil(outcome.detail)
        XCTAssertEqual(gateway.count("_acpcode/sessions/prompt"), 1)
        let sent = gateway.params(for: "_acpcode/sessions/prompt").first
        XCTAssertEqual(sent?["sessionId"], .string("s-1"))
        XCTAssertEqual(sent?["prompt"], .array([.object(["type": .string("text"), "text": .string(prompt)])]))
    }

    func testTheSendNeverSelectsAServerOrOpensASessionAndTheSelectionStaysPut() async throws {
        let gateway = healthyGateway()
        let host = host(gateway)
        _ = try await sender(host).send(prompt: prompt, to: target())
        XCTAssertEqual(host.selectCalls, [], "the Shortcut must never select a server")
        XCTAssertFalse(gateway.methods.contains("session/new"))
        XCTAssertFalse(gateway.methods.contains("session/load"))
        XCTAssertFalse(gateway.methods.contains("session/resume"))
        XCTAssertFalse(gateway.methods.contains("_acpcode/sessions/subscribe"))
        XCTAssertEqual(host.selectedServerID, serverID)
    }

    // MARK: - Refusals, before any request to the session

    func testASessionFromAnotherServerIsRefusedWithNoConnectAndNoRequest() async {
        let gateway = healthyGateway()
        let host = host(gateway)
        do {
            _ = try await sender(host).send(prompt: prompt, to: target(on: otherServerID))
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? SendToSessionError, .otherServer)
        }
        XCTAssertEqual(host.connectCount, 0)
        XCTAssertTrue(gateway.methods.isEmpty)
        XCTAssertEqual(host.selectCalls, [])
    }

    func testNoSelectedServerIsRefused() async {
        let gateway = healthyGateway()
        let host = host(gateway)
        host.selectedServerID = nil
        do {
            _ = try await sender(host).send(prompt: prompt, to: target())
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? AgentSessionError, .noServer)
        }
        XCTAssertEqual(host.connectCount, 0)
        XCTAssertTrue(gateway.methods.isEmpty)
    }

    func testAPlainACPServerIsRefusedWithNoRequestToTheSession() async {
        let gateway = healthyGateway()
        let host = host(gateway)
        host.connect = { throw AgentSessionError.notGateway }
        do {
            _ = try await sender(host).send(prompt: prompt, to: target())
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? AgentSessionError, .notGateway)
        }
        XCTAssertFalse(gateway.methods.contains("_acpcode/sessions/prompt"))
        XCTAssertFalse(gateway.methods.contains("session/prompt"))
        XCTAssertFalse(gateway.methods.contains("session/new"))
        XCTAssertEqual(host.selectCalls, [])
    }

    func testASessionTheGatewayDoesNotListIsRefusedWithNoPrompt() async {
        let gateway = healthyGateway()
        gateway.handlers["_acpcode/sessions/index"] = { _ in .object(["sessions": .array([self.session("other", title: nil)])]) }
        let host = host(gateway)
        do {
            _ = try await sender(host).send(prompt: prompt, to: target("s-1"))
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? SendToSessionError, .notListed)
        }
        XCTAssertEqual(gateway.count("_acpcode/sessions/prompt"), 0)
        XCTAssertEqual(host.selectCalls, [])
    }

    func testAnEmptyPromptIsRefusedBeforeConnecting() async {
        let gateway = healthyGateway()
        let host = host(gateway)
        do {
            _ = try await sender(host).send(prompt: "   \n ", to: target())
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? AgentSessionError, .emptyPrompt)
        }
        XCTAssertEqual(host.connectCount, 0)
        XCTAssertTrue(gateway.methods.isEmpty)
    }

    func testAConnectThatHangsStopsAtTheDeadlineWithNoRequest() async {
        let gateway = healthyGateway()
        let host = host(gateway)
        host.connect = {
            try await Task.sleep(for: .seconds(5))
            return GatewayClient(gateway)
        }
        let started = ContinuousClock.now
        do {
            _ = try await sender(host, connect: .milliseconds(50)).send(prompt: prompt, to: target())
            XCTFail("expected the deadline to stop the send")
        } catch {
            XCTAssertEqual(error as? AgentSessionError, .unreachable)
        }
        XCTAssertLessThan(started.duration(to: ContinuousClock.now), .seconds(2), "the send must not wait for the hung connect")
        XCTAssertTrue(gateway.methods.isEmpty)
    }

    // MARK: - Results after the request

    func testABusySessionReturnsBusyOnceWithoutRetry() async throws {
        let gateway = healthyGateway()
        gateway.handlers["_acpcode/sessions/prompt"] = { _ in
            throw ACPServiceError.rpc(id: .number(3), error: .serverError(code: -32010, message: "turn pending"))
        }
        let host = host(gateway)
        let outcome = try await sender(host).send(prompt: prompt, to: target())
        XCTAssertEqual(outcome.status, .busy)
        XCTAssertNil(outcome.turnId)
        XCTAssertNil(outcome.detail)
        XCTAssertEqual(gateway.count("_acpcode/sessions/prompt"), 1, "a busy answer is not retried or queued")
        XCTAssertTrue(SendToAgentSessionIntent.dialog(for: outcome).contains("already running"))
    }

    func testAFailureAfterTheSendReturnsFailedWithTheGatewayTextAndIsNotRetried() async throws {
        let gateway = healthyGateway()
        gateway.handlers["_acpcode/sessions/prompt"] = { _ in
            throw ACPServiceError.rpc(id: .number(4), error: .serverError(code: -32000, message: "agent exited"))
        }
        let host = host(gateway)
        let outcome = try await sender(host).send(prompt: prompt, to: target())
        XCTAssertEqual(outcome.status, .failed)
        XCTAssertEqual(outcome.detail, "agent exited")
        XCTAssertNil(outcome.turnId)
        XCTAssertEqual(gateway.count("_acpcode/sessions/prompt"), 1, "a retry could send the prompt twice")
    }

    func testAConnectionLostAfterTheSendReturnsFailedNamingTheConnection() async throws {
        let gateway = healthyGateway()
        gateway.handlers["_acpcode/sessions/prompt"] = { _ in throw ACPServiceError.disconnected }
        let host = host(gateway)
        let outcome = try await sender(host).send(prompt: prompt, to: target())
        XCTAssertEqual(outcome.status, .failed)
        XCTAssertEqual(outcome.detail, "Can't reach your Mac. Check that it is awake and connected.")
        XCTAssertEqual(gateway.count("_acpcode/sessions/prompt"), 1)
    }

    func testTheSelectionIsNeverChangedAcrossEveryOutcome() async throws {
        let gateway = healthyGateway()
        let host = host(gateway)
        _ = try await sender(host).send(prompt: prompt, to: target())
        gateway.handlers["_acpcode/sessions/prompt"] = { _ in throw ACPServiceError.disconnected }
        _ = try await sender(host).send(prompt: prompt, to: target())
        XCTAssertEqual(host.selectCalls, [])
    }

    // MARK: - Privacy of the result

    func testTheDialogNeverHoldsThePromptForAnyStatus() {
        let outcomes: [AgentSendOutcome] = [
            AgentSendOutcome(serverID: serverID, sessionId: "s-1", turnId: "t-7", status: .accepted, detail: nil),
            AgentSendOutcome(serverID: serverID, sessionId: "s-1", turnId: nil, status: .busy, detail: nil),
            AgentSendOutcome(serverID: serverID, sessionId: "s-1", turnId: nil, status: .failed, detail: "agent exited"),
        ]
        for outcome in outcomes {
            let text = SendToAgentSessionIntent.dialog(for: outcome)
            XCTAssertFalse(text.contains(secret))
            XCTAssertFalse(text.contains("t-7"), "the turn id is not spoken")
        }
        let result = AgentSendResultEntity(outcome: outcomes[0])
        XCTAssertEqual(result.id, "\(serverID.uuidString)/s-1")
        XCTAssertEqual(result.turnId, "t-7")
        XCTAssertEqual(result.status, .accepted)
    }

    func testAPromptWithASecretIsSentOnlyAsTheRequestTextAndNotInTheDialog() async throws {
        let gateway = healthyGateway()
        let host = host(gateway)
        let outcome = try await sender(host).send(prompt: "Use \(secret) here", to: target())
        XCTAssertFalse(SendToAgentSessionIntent.dialog(for: outcome).contains(secret))
        XCTAssertFalse(outcome.entityID.contains(secret))
        XCTAssertEqual(gateway.count("_acpcode/sessions/prompt"), 1)
    }

    // MARK: - Entity ids and the session list

    func testTheEntityIdParsesAndAnotherShapeIsRejected() {
        XCTAssertEqual(AgentSessionTarget(entityID: "\(serverID.uuidString)/s-1"), target("s-1"))
        XCTAssertNil(AgentSessionTarget(entityID: "not-a-uuid/s-1"))
        XCTAssertNil(AgentSessionTarget(entityID: "\(serverID.uuidString)/"))
        XCTAssertNil(AgentSessionTarget(entityID: "\(serverID.uuidString)"))
    }

    func testTheSessionListHoldsOnlyTheSelectedServersSessions() async {
        let gateway = healthyGateway()
        gateway.handlers["_acpcode/sessions/index"] = { _ in .object(["sessions": .array([
            self.session("s-1", title: "Fix build"), self.session("s-2", title: nil),
        ])]) }
        let host = host(gateway)
        let entities = await GatewaySessionCatalog.entities(host: host)
        XCTAssertEqual(entities.map(\.id), ["\(serverID.uuidString)/s-1", "\(serverID.uuidString)/s-2"])
        XCTAssertEqual(entities.map(\.title), ["Fix build", "Untitled session"])
        XCTAssertEqual(entities.first?.target, target("s-1"))
        XCTAssertEqual(host.selectCalls, [])
    }

    func testTheSessionListIsEmptyWithNoSelectedServer() async {
        let gateway = healthyGateway()
        let host = host(gateway)
        host.selectedServerID = nil
        let entities = await GatewaySessionCatalog.entities(host: host)
        XCTAssertTrue(entities.isEmpty)
        XCTAssertTrue(gateway.methods.isEmpty)
    }
}
