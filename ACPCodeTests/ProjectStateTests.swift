import XCTest
import ACP
import ACPClient
@testable import ACPCode

// D-102: the gateway home shows each project's agent state from `_acpcode/project/state`. The router tests send
// the notification over the same wire path the gateway uses; the home tests use a fake gateway client.

private final class ProjectStateFakeGateway: GatewayCalling, @unchecked Sendable {
    var results: [String: ACP.Value] = [:]
    func gatewayCall(method: String, params: ACP.Value?) async throws -> ACP.Value { results[method] ?? .null }
}

private func projectsList(_ projects: [(String, String)]) -> ACP.Value {
    .object(["projects": .array(projects.map {
        .object(["id": .string($0.0), "name": .string($0.1), "path": .string("/srv/\($0.1)"), "defaultMode": .null])
    })])
}

/// A home model for `serverId`, loaded with `projects` from a fake gateway.
@MainActor
private func loadedHome(_ home: GatewayHomeModel, serverId: UUID, projects: [(String, String)]) async {
    let fake = ProjectStateFakeGateway()
    fake.results["_acpcode/projects/list"] = projectsList(projects)
    fake.results["_acpcode/sessions/index"] = .object(["sessions": .array([])])
    home.configure(serverId: serverId) { GatewayClient(fake) }
    await home.refresh()
}

private func projectState(_ projectId: String, _ agent: String) -> WebSocketEvent {
    notification("_acpcode/project/state", ["projectId": projectId, "agent": agent, "since": "2026-11-08T09:14:02.250Z"])
}

private func notification(_ method: String, _ params: [String: Any]) -> WebSocketEvent {
    let data = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": method, "params": params])
    return .text(String(decoding: data, as: UTF8.self))
}

// MARK: - The home model

@MainActor
final class ProjectStateHomeTests: XCTestCase {
    private let serverA = UUID()
    private let serverB = UUID()

    func testAStateShowsOnItsListedProjectAndNowhereElse() async {
        let home = GatewayHomeModel()
        await loadedHome(home, serverId: serverA, projects: [("p-site", "Site"), ("p-api", "API")])
        home.applyProjectState(GatewayProjectState(projectId: "p-site", agent: .running), serverId: serverA)
        XCTAssertEqual(home.agentState(for: "p-site"), .running)
        XCTAssertNil(home.agentState(for: "p-api"), "a project with no state is unknown")
        home.applyProjectState(GatewayProjectState(projectId: "p-site", agent: .stopping), serverId: serverA)
        XCTAssertEqual(home.agentState(for: "p-site"), .stopping, "the latest state wins")
    }

    func testAnUnknownStateIsNotShownAndClearsAShownOne() async {
        let home = GatewayHomeModel()
        await loadedHome(home, serverId: serverA, projects: [("p-site", "Site")])
        home.applyProjectState(GatewayProjectState(projectId: "p-site", agent: .running), serverId: serverA)
        home.applyProjectState(GatewayProjectState(projectId: "p-site", agent: .unknown), serverId: serverA)
        XCTAssertNil(home.agentState(for: "p-site"), "a value this app does not know is not shown, not even the old one")
        XCTAssertNil(GatewayAgentStatePresentation.label(.unknown))
        XCTAssertNil(GatewayAgentStatePresentation.accessibilityLabel(.unknown))
    }

    func testAStateForAProjectNotOnTheListIsIgnored() async {
        let home = GatewayHomeModel()
        await loadedHome(home, serverId: serverA, projects: [("p-site", "Site")])
        home.applyProjectState(GatewayProjectState(projectId: "p-ghost", agent: .running), serverId: serverA)
        XCTAssertNil(home.agentState(for: "p-ghost"))
        XCTAssertTrue(home.projectStates.isEmpty, "nothing is kept for a project the list does not show")
    }

    func testAChangeOnOneServerDoesNotChangeAnotherServersHeader() async {
        let home = GatewayHomeModel()
        await loadedHome(home, serverId: serverA, projects: [("p-site", "Site")])
        home.applyProjectState(GatewayProjectState(projectId: "p-site", agent: .running), serverId: serverA)
        XCTAssertEqual(home.agentState(for: "p-site"), .running)

        await loadedHome(home, serverId: serverB, projects: [("p-site", "Site")])
        XCTAssertNil(home.agentState(for: "p-site"), "server A's running state does not show on server B's project of the same id")
        home.applyProjectState(GatewayProjectState(projectId: "p-site", agent: .stopped), serverId: serverB)
        XCTAssertEqual(home.agentState(for: "p-site"), .stopped)

        await loadedHome(home, serverId: serverA, projects: [("p-site", "Site")])
        XCTAssertNil(home.agentState(for: "p-site"), "server B's idle state does not show on server A")
    }

    func testTheStatesClearWhenTheServerChanges() async {
        let home = GatewayHomeModel()
        await loadedHome(home, serverId: serverA, projects: [("p-site", "Site")])
        home.applyProjectState(GatewayProjectState(projectId: "p-site", agent: .running), serverId: serverA)
        home.configure(serverId: serverB, clientProvider: nil)
        XCTAssertTrue(home.projectStates.isEmpty, "cleared at once, before the new server answers")
        await loadedHome(home, serverId: serverB, projects: [("p-site", "Site")])
        XCTAssertNil(home.agentState(for: "p-site"), "server B's list shows p-site, but not server A's state of it")
    }

    func testAReconnectToTheSameServerKeepsTheStates() async {
        let home = GatewayHomeModel()
        await loadedHome(home, serverId: serverA, projects: [("p-site", "Site")])
        home.applyProjectState(GatewayProjectState(projectId: "p-site", agent: .running), serverId: serverA)
        await loadedHome(home, serverId: serverA, projects: [("p-site", "Site")])
        XCTAssertEqual(home.agentState(for: "p-site"), .running, "the gateway does not resend a state on a new socket, so it must be kept")
    }

    func testStatesThatArriveBeforeTheListLoadsWaitForIt() async {
        let home = GatewayHomeModel()
        home.configure(serverId: serverA) { nil }
        home.applyProjectState(GatewayProjectState(projectId: "p-site", agent: .running), serverId: serverA)
        home.applyProjectState(GatewayProjectState(projectId: "p-ghost", agent: .running), serverId: serverA)
        XCTAssertTrue(home.projectStates.isEmpty, "no list yet, so nothing is kept as shown")
        let fake = ProjectStateFakeGateway()
        fake.results["_acpcode/projects/list"] = projectsList([("p-site", "Site")])
        fake.results["_acpcode/sessions/index"] = .object(["sessions": .array([])])
        home.configure(serverId: serverA) { GatewayClient(fake) }
        await home.refresh()
        XCTAssertEqual(home.agentState(for: "p-site"), .running, "the list shows the project the state waited for")
        XCTAssertNil(home.agentState(for: "p-ghost"))
        XCTAssertEqual(Set(home.projectStates.keys), ["p-site"], "the state of a project the list does not show is dropped")
    }

    func testPresentationWordsAndProgress() {
        XCTAssertEqual(GatewayAgentStatePresentation.label(.running), "Running")
        XCTAssertEqual(GatewayAgentStatePresentation.label(.starting), "Starting")
        XCTAssertEqual(GatewayAgentStatePresentation.label(.stopping), "Stopping")
        XCTAssertEqual(GatewayAgentStatePresentation.label(.stopped), "Idle")
        XCTAssertEqual(GatewayAgentStatePresentation.accessibilityLabel(.running), "Agent running")
        XCTAssertTrue(GatewayAgentStatePresentation.showsProgress(.running))
        XCTAssertFalse(GatewayAgentStatePresentation.showsProgress(.stopped))
        XCTAssertFalse(GatewayAgentStatePresentation.showsProgress(.starting))
    }
}

// MARK: - The router: `_acpcode/project/state` and the notifications next to it

@MainActor
final class ProjectStateRouterTests: XCTestCase {
    private final class Recording: WebSocketConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var events: [WebSocketEvent] = []
        private var texts: [String] = []
        func connect(headers: [String: String]) async throws {}
        func send(text: String) async throws { lock.lock(); texts.append(text); lock.unlock() }
        func receive() async throws -> WebSocketEvent {
            while true {
                lock.lock()
                if !events.isEmpty { let e = events.removeFirst(); lock.unlock(); return e }
                lock.unlock()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        func close() async {}
        func ping() async throws {}
        func enqueue(_ event: WebSocketEvent) { lock.lock(); events.append(event); lock.unlock() }
        /// Every message the app sent, parsed.
        func requests() -> [[String: Any]] {
            lock.lock(); defer { lock.unlock() }
            return texts.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        func methodsSent() -> [String] { requests().compactMap { $0["method"] as? String } }
    }

    private struct Provider: WebSocketProviding, @unchecked Sendable {
        let connection: Recording
        func makeConnection(url: URL) -> WebSocketConnection { connection }
    }

    private struct Harness {
        let model: AppViewModel
        let server: ServerViewModel
        let connection: Recording
        let responder: Task<Void, Never>
    }

    private func respond(_ id: Int, _ result: ACP.Value, on connection: Recording) {
        guard let data = try? JSONEncoder().encode(ACPWireMessage.response(.init(id: .int(id), result: result))) else { return }
        connection.enqueue(.text(String(decoding: data, as: UTF8.self)))
    }

    /// A gateway server, selected and connected over a fake socket, as GatewayOpenTests sets one up.
    private func harness() async throws -> Harness {
        let connection = Recording()
        let client = ACPClient(configuration: .init(endpoint: URL(string: "ws://localhost:1234")!, pingInterval: nil), socketProvider: Provider(connection: connection))
        let service = ACPService(client: client)
        try await service.connect()
        let suite = "ProjectStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)
        let model = AppViewModel(storage: .inMemory(), defaults: defaults, connectionManager: manager, shouldStartNetworkMonitoring: false, shouldConnectOnStartup: false)
        model.addServer(name: "Gateway", scheme: "ws", host: "localhost:1234", token: "", cfAccessClientId: "", cfAccessClientSecret: "", workingDirectory: "/tmp")
        let server = try XCTUnwrap(model.selectedServerViewModel)
        manager.setServiceForTesting(service)
        service.delegate = manager // connect() sets this (ACPClientManager.connect); the test seam does not, so notifications would never reach the router
        Task {
            for _ in 0..<500 {
                if let request = connection.requests().first(where: { $0["method"] as? String == "initialize" }), let id = request["id"] as? Int {
                    respond(id, .object(["protocolVersion": .number(1), "agentCapabilities": .object(["loadSession": .bool(true)])]), on: connection)
                    return
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        let initialized = await manager.initializeAndWait(payload: ACPInitializationPayload(clientName: "ACP Code iOS", clientVersion: "0.1.0"))
        XCTAssertTrue(initialized)
        let responder = Task { [self] in
            var answered = Set<Int>()
            while !Task.isCancelled {
                for request in connection.requests() {
                    guard let id = request["id"] as? Int, let method = request["method"] as? String, method != "initialize", !answered.contains(id) else { continue }
                    answered.insert(id)
                    switch method {
                    case "_acpcode/sessions/subscribe": respond(id, .object(["headSeq": .int(0)]), on: connection)
                    case "_acpcode/sessions/read": respond(id, .object(["lastSeenSeq": .int(0)]), on: connection)
                    default: respond(id, .object([:]), on: connection)
                    }
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        server.updateAgentInfo(AgentProfile(id: nil, name: "bob", title: "Bob", version: "2.0.9", description: nil, modes: [],
                                            capabilities: AgentCapabilityState(loadSession: true), verifications: []))
        server.updateGatewayInfo(GatewayInfo(version: "0.3.0-dev", extensions: ["projects", "sessions", "approvals", "git"]))
        return Harness(model: model, server: server, connection: connection, responder: responder)
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testAProjectStateNotificationUpdatesTheHomeOfTheSelectedServer() async throws {
        let h = try await harness()
        defer { h.responder.cancel() }
        await loadedHome(h.model.gatewayHome, serverId: h.server.id, projects: [("p-site", "Site"), ("p-api", "API")])
        h.connection.enqueue(projectState("p-ghost", "running")) // not listed: must not be kept
        h.connection.enqueue(projectState("p-site", "running"))
        h.connection.enqueue(projectState("p-api", "stopped")) // the last one: when this lands, the others have too
        await settle { h.model.gatewayHome.agentState(for: "p-api") == .stopped }
        XCTAssertEqual(h.model.gatewayHome.agentState(for: "p-site"), .running, "the router forwards the notification to the home")
        XCTAssertEqual(Set(h.model.gatewayHome.projectStates.keys), ["p-site", "p-api"], "a state for a project not on the list is not kept")
        // The wire log records the state as an incoming message, as it does for git/changed: "← <method>: <payload>".
        XCTAssertTrue(h.model.updates.contains { $0.message.hasPrefix("← _acpcode/project/state") }, "the state is logged as an incoming message")
        XCTAssertFalse(h.model.updates.contains { $0.message.hasPrefix("Notification _acpcode/project/state") }, "a state is not a Notification log line")
    }

    func testAnUnknownStateNotificationClearsTheShownState() async throws {
        let h = try await harness()
        defer { h.responder.cancel() }
        await loadedHome(h.model.gatewayHome, serverId: h.server.id, projects: [("p-site", "Site"), ("p-api", "API")])
        h.connection.enqueue(projectState("p-site", "running"))
        await settle { h.model.gatewayHome.agentState(for: "p-site") == .running }
        XCTAssertEqual(h.model.gatewayHome.agentState(for: "p-site"), .running, "the running state is shown before the unknown one arrives")
        h.connection.enqueue(projectState("p-site", "paused")) // a value this app does not know
        h.connection.enqueue(projectState("p-api", "stopped")) // the last one: when this lands, the unknown one has too
        await settle { h.model.gatewayHome.agentState(for: "p-api") == .stopped }
        XCTAssertNil(h.model.gatewayHome.agentState(for: "p-site"), "an unknown state clears the shown one")
    }

    func testAStateForAProjectNotOnTheListIsIgnoredOverTheWire() async throws {
        let h = try await harness()
        defer { h.responder.cancel() }
        await loadedHome(h.model.gatewayHome, serverId: h.server.id, projects: [("p-site", "Site")])
        h.connection.enqueue(projectState("p-ghost", "running"))
        h.connection.enqueue(projectState("p-site", "stopping"))
        await settle { h.model.gatewayHome.agentState(for: "p-site") == .stopping }
        XCTAssertNil(h.model.gatewayHome.agentState(for: "p-ghost"))
        XCTAssertEqual(Set(h.model.gatewayHome.projectStates.keys), ["p-site"])
    }

    func testAGatewayEventStillAppliesToTheOpenSession() async throws {
        let h = try await harness()
        defer { h.responder.cancel() }
        h.model.selectedServerViewModel?.openSession("sess-1")
        await settle { h.connection.methodsSent().contains("_acpcode/sessions/subscribe") }
        h.connection.enqueue(notification(GatewayEvent.method, [
            "sessionId": "sess-1", "seq": 1,
            "message": ["jsonrpc": "2.0", "method": "_acpcode/turn_started",
                        "params": ["sessionId": "sess-1", "prompt": [["type": "text", "text": "hello from the wire"]]]],
        ]))
        await settle { h.model.sessionViewModel?.chatMessages.map(\.content).contains("hello from the wire") == true }
        XCTAssertEqual(h.model.sessionViewModel?.chatMessages.map(\.content).contains("hello from the wire"), true, "_acpcode/event still reaches the chat")
    }

    func testAGitChangedNotificationStillRefreshesTheProjectStatus() async throws {
        let h = try await harness()
        defer { h.responder.cancel() }
        _ = h.model.gitStore.model(for: "p-site")
        h.connection.enqueue(notification(GatewayGitChanged.method, ["projectId": "p-site", "hash": "h-2"]))
        await settle { h.connection.methodsSent().contains("_acpcode/git/status") }
        XCTAssertTrue(h.connection.methodsSent().contains("_acpcode/git/status"), "_acpcode/git/changed still reaches the git store")
    }

    func testAGatewayNoticeStillReachesTheLog() async throws {
        let h = try await harness()
        defer { h.responder.cancel() }
        h.connection.enqueue(notification("_acpcode/notice", ["approvalId": "acpcode-perm-9", "message": "answered elsewhere"]))
        // The wire log line also contains the method ("← _acpcode/notice: ..."), so only the Notification line shows the default path ran.
        await settle { h.model.updates.contains { $0.message.hasPrefix("Notification _acpcode/notice") } }
        XCTAssertTrue(h.model.updates.contains { $0.message.hasPrefix("Notification _acpcode/notice") }, "_acpcode/notice still takes the default path")
    }
}
