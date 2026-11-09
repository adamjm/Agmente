import XCTest
import ACP
@testable import ACPCode
import ACPClient

/// A gateway that answers by method name and records every call.
private final class StarterFakeGateway: GatewayCalling, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(method: String, params: ACP.Value?)] = []
    var handlers: [String: (ACP.Value?) throws -> ACP.Value] = [:]

    var methods: [String] { lock.lock(); defer { lock.unlock() }; return recorded.map(\.method) }
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

/// The app's side of the starter, as a fake. It records every call that could change the app's state.
@MainActor
private final class StarterFakeHost: AgentSessionHost {
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
final class AgentSessionStarterTests: XCTestCase {
    private let serverID = UUID(uuidString: "5F1C2E0A-7B7B-4C1D-9C3E-2A4B6D8F0A11")!
    private let otherServerID = UUID(uuidString: "0A0B0C0D-1111-2222-3333-444455556666")!
    private let prompt = "Refactor the parser and keep the tests green"

    private func project(_ id: String, _ name: String, _ path: String) -> ACP.Value {
        .object(["id": .string(id), "name": .string(name), "path": .string(path), "defaultMode": .null])
    }

    private func approval(sessionId: String) -> ACP.Value {
        .object([
            "approvalId": .string("acpcode-perm-1"), "sessionId": .string(sessionId), "projectId": .string("a1"),
            "toolCall": .object(["title": .string("Run: rm -rf build")]),
            "options": .array([.object(["optionId": .string("allow"), "name": .string("Allow"), "kind": .string("allow_once")])]),
            "since": .string("2026-11-09T08:00:00.000Z"),
        ])
    }

    /// A gateway with one project at `/srv/site`, a session that starts, and no open approvals.
    private func healthyGateway() -> StarterFakeGateway {
        let gateway = StarterFakeGateway()
        gateway.handlers["_acpcode/projects/list"] = { _ in .object(["projects": .array([self.project("a1", "Site", "/srv/site")])]) }
        gateway.handlers["_acpcode/sessions/create"] = { _ in .object([
            "sessionId": .string("s-1"), "turnId": .string("t-1"), "status": .string("accepted"),
        ]) }
        gateway.handlers["_acpcode/sessions/subscribe"] = { _ in .object(["headSeq": .number(0)]) }
        gateway.handlers["_acpcode/approvals/pending"] = { _ in .object(["approvals": .array([])]) }
        return gateway
    }

    private func host(_ gateway: StarterFakeGateway, selected: UUID? = nil) -> StarterFakeHost {
        let host = StarterFakeHost()
        host.selectedServerID = selected ?? serverID
        let client = GatewayClient(gateway)
        host.connect = { client }
        return host
    }

    private func starter(_ host: StarterFakeHost, connect: Duration = .seconds(10), window: Duration = .milliseconds(30)) -> AgentSessionStarter {
        AgentSessionStarter(host: host, connectDeadline: connect, approvalWindow: window, pollInterval: .milliseconds(5))
    }

    // MARK: - Refusals, before any session/new

    func testNoSelectedServerIsRefused() async {
        let gateway = healthyGateway()
        let host = host(gateway)
        host.selectedServerID = nil
        do {
            _ = try await starter(host).start(prompt: prompt, project: nil)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? AgentSessionError, .noServer)
        }
        XCTAssertEqual(host.connectCount, 0)
        XCTAssertTrue(gateway.methods.isEmpty)
    }

    func testAPlainACPServerIsRefusedBeforeSessionNew() async {
        let gateway = healthyGateway()
        let host = host(gateway)
        host.connect = { throw AgentSessionError.notGateway }
        do {
            _ = try await starter(host).start(prompt: prompt, project: nil)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? AgentSessionError, .notGateway)
        }
        XCTAssertFalse(gateway.methods.contains("_acpcode/sessions/create"))
        XCTAssertFalse(gateway.methods.contains("session/new"))
    }

    func testAProjectOnAnotherServerIsRefusedWithoutConnecting() async {
        let gateway = healthyGateway()
        let host = host(gateway)
        let choice = AgentProjectChoice(serverID: otherServerID, projectID: "a1")
        do {
            _ = try await starter(host).start(prompt: prompt, project: choice)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? AgentSessionError, .otherServer)
        }
        XCTAssertEqual(host.connectCount, 0)
        XCTAssertTrue(gateway.methods.isEmpty)
    }

    func testAnEmptyProjectListIsRefusedWithNoSession() async {
        let gateway = healthyGateway()
        gateway.handlers["_acpcode/projects/list"] = { _ in .object(["projects": .array([])]) }
        let host = host(gateway)
        do {
            _ = try await starter(host).start(prompt: prompt, project: nil)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? AgentSessionError, .noProjects)
        }
        XCTAssertFalse(gateway.methods.contains("_acpcode/sessions/create"))
    }

    func testAProjectThatIsGoneIsRefused() async {
        let gateway = healthyGateway()
        let host = host(gateway)
        let choice = AgentProjectChoice(serverID: serverID, projectID: "gone")
        do {
            _ = try await starter(host).start(prompt: prompt, project: choice)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? AgentSessionError, .projectMissing)
        }
        XCTAssertFalse(gateway.methods.contains("_acpcode/sessions/create"))
    }

    func testSeveralProjectsWithoutAChoiceAreRefusedRatherThanGuessed() async {
        let gateway = healthyGateway()
        gateway.handlers["_acpcode/projects/list"] = { _ in .object(["projects": .array([
            self.project("a1", "Site", "/srv/site"), self.project("b2", "API", "/srv/api"),
        ])]) }
        let host = host(gateway)
        do {
            _ = try await starter(host).start(prompt: prompt, project: nil)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? AgentSessionError, .projectRequired)
        }
        XCTAssertFalse(gateway.methods.contains("_acpcode/sessions/create"))
    }

    func testAnEmptyOrOversizePromptIsRefusedBeforeConnecting() async {
        let gateway = healthyGateway()
        let host = host(gateway)
        do {
            _ = try await starter(host).start(prompt: "   \n ", project: nil)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? AgentSessionError, .emptyPrompt)
        }
        do {
            _ = try await starter(host).start(prompt: String(repeating: "x", count: AgentSessionStarter.maxPromptBytes + 1), project: nil)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? AgentSessionError, .promptTooLong)
        }
        XCTAssertEqual(host.connectCount, 0)
    }

    // MARK: - Connect deadline

    func testAConnectThatHangsStopsAtTheDeadlineWithNoSession() async {
        let gateway = healthyGateway()
        let host = host(gateway)
        host.connect = {
            try await Task.sleep(for: .seconds(5))
            return GatewayClient(gateway)
        }
        let started = ContinuousClock.now
        do {
            _ = try await starter(host, connect: .milliseconds(50)).start(prompt: prompt, project: nil)
            XCTFail("expected the deadline to stop the run")
        } catch {
            XCTAssertEqual(error as? AgentSessionError, .unreachable)
        }
        XCTAssertLessThan(started.duration(to: ContinuousClock.now), .seconds(2), "the run must not wait for the hung connect")
        XCTAssertTrue(gateway.methods.isEmpty)
    }

    // MARK: - Results once a session exists

    func testASessionThatStartsReturnsRunningWithItsIdAndTheProjectName() async throws {
        let gateway = healthyGateway()
        let host = host(gateway)
        let outcome = try await starter(host).start(prompt: prompt, project: nil)
        XCTAssertEqual(outcome.status, .running)
        XCTAssertEqual(outcome.sessionId, "s-1")
        XCTAssertEqual(outcome.entityID, "\(serverID.uuidString)/s-1")
        XCTAssertEqual(outcome.projectName, "Site")
        XCTAssertEqual(gateway.params(for: "_acpcode/sessions/create").first?["cwd"], .string("/srv/site"))
        XCTAssertEqual(gateway.params(for: "_acpcode/sessions/subscribe").first?["afterSeq"], .number(0))
    }

    func testAPromptNotSentReturnsCreatedNotSentWithTheSessionId() async throws {
        let gateway = healthyGateway()
        gateway.handlers["_acpcode/sessions/create"] = { _ in
            throw ACPServiceError.rpcData(
                id: .number(4),
                error: .serverError(code: -32015, message: "the agent did not accept the prompt"),
                data: .object(["sessionId": .string("s-9"), "promptSent": .bool(false)])
            )
        }
        let host = host(gateway)
        let outcome = try await starter(host).start(prompt: prompt, project: nil)
        XCTAssertEqual(outcome.status, .createdNotSent)
        XCTAssertEqual(outcome.sessionId, "s-9")
        XCTAssertEqual(outcome.entityID, "\(serverID.uuidString)/s-9")
        XCTAssertEqual(outcome.detail, "the agent did not accept the prompt")
    }

    func testAnOpenApprovalReturnsWaitingForApproval() async throws {
        let gateway = healthyGateway()
        gateway.handlers["_acpcode/approvals/pending"] = { _ in .object(["approvals": .array([self.approval(sessionId: "s-1")])]) }
        let host = host(gateway)
        let outcome = try await starter(host).start(prompt: prompt, project: nil)
        XCTAssertEqual(outcome.status, .waitingForApproval)
        XCTAssertEqual(outcome.sessionId, "s-1")
    }

    func testAnApprovalForAnotherSessionDoesNotCount() async throws {
        let gateway = healthyGateway()
        gateway.handlers["_acpcode/approvals/pending"] = { _ in .object(["approvals": .array([self.approval(sessionId: "other")])]) }
        let host = host(gateway)
        let outcome = try await starter(host).start(prompt: prompt, project: nil)
        XCTAssertEqual(outcome.status, .running)
    }

    func testAGatewayRefusalIsThrownWithItsOwnText() async {
        let gateway = healthyGateway()
        gateway.handlers["_acpcode/sessions/create"] = { _ in
            throw ACPServiceError.rpc(id: .number(5), error: .invalidParams("That folder is not an approved project."))
        }
        let host = host(gateway)
        do {
            _ = try await starter(host).start(prompt: prompt, project: nil)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? AgentSessionError, .gateway("That folder is not an approved project."))
        }
    }

    func testTheSelectionNeverChanges() async throws {
        let gateway = healthyGateway()
        let host = host(gateway)
        _ = try await starter(host).start(prompt: prompt, project: nil)
        XCTAssertEqual(host.selectCalls, [], "the Shortcut must never select a server")
    }

    func testTheSelectionMovingWhileConnectingStopsTheRun() async {
        let gateway = healthyGateway()
        let host = host(gateway)
        let other = otherServerID
        host.connect = {
            host.selectedServerID = other
            return GatewayClient(gateway)
        }
        do {
            _ = try await starter(host).start(prompt: prompt, project: nil)
            XCTFail("expected the run to stop")
        } catch {
            XCTAssertEqual(error as? AgentSessionError, .otherServer)
        }
        XCTAssertFalse(gateway.methods.contains("_acpcode/sessions/create"))
    }

    // MARK: - Privacy of the result

    func testTheDialogNamesTheProjectAndNeverTheSecretPrompt() {
        let secret = "the-secret-launch-code-4417"
        let outcomes: [AgentSessionOutcome] = [
            AgentSessionOutcome(serverID: serverID, sessionId: "s-1", projectName: "Site", status: .running, detail: nil),
            AgentSessionOutcome(serverID: serverID, sessionId: "s-1", projectName: "Site", status: .waitingForApproval, detail: nil),
            AgentSessionOutcome(serverID: serverID, sessionId: "s-1", projectName: "Site", status: .createdNotSent, detail: "refused"),
        ]
        for outcome in outcomes {
            let text = StartAgentSessionIntent.dialog(for: outcome)
            XCTAssertTrue(text.contains("Site"))
            XCTAssertFalse(text.contains(secret))
        }
        let entity = AgentSessionEntity(outcome: outcomes[0])
        XCTAssertEqual(entity.id, "\(serverID.uuidString)/s-1")
        XCTAssertEqual(entity.title, "Site", "the title is the project name, never the prompt")
        XCTAssertEqual(entity.status, .running)
    }

    func testTheProjectEntityIdRoundTrips() {
        let entity = GatewayProjectEntity(serverID: serverID, project: GatewayProject(id: "a1", name: "Site", path: "/srv/site"))
        XCTAssertEqual(entity.id, "\(serverID.uuidString)/a1")
        XCTAssertEqual(entity.choice, AgentProjectChoice(serverID: serverID, projectID: "a1"))
    }
}
