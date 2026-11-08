import Foundation
import ACPClient

// The gateway session actions (D-106): stop a turn, stop a project's agent, the stalled notice, recovery of a session
// the gateway does not know, and the phone-only check. The views call these and show what the published values say.
// Stopping an agent takes two steps: `requestAgentStop` reads the sessions it would end and stops nothing, and
// `confirmAgentStop` runs it after the person agrees.

@MainActor
final class GatewaySessionActions: ObservableObject {
    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    struct AgentStopPrompt: Identifiable, Equatable {
        let id = UUID()
        let sessionId: String
        let projectId: String
        let candidates: [GatewayStopCandidate]
    }

    struct RemovalPrompt: Identifiable, Equatable {
        let id = UUID()
        let sessionId: String
        let title: String
    }

    /// The outcome of an action, shown as one alert.
    @Published var notice: Notice?
    /// The agent-scope confirmation, while it is open.
    @Published var agentStop: AgentStopPrompt?
    /// The removal confirmation for a record the gateway does not know, while it is open.
    @Published var removal: RemovalPrompt?
    /// The phone-only sheet, while it is open.
    @Published var showingPhoneOnly = false

    private let home: GatewayHomeModel
    private let client: () -> GatewayClient?
    private let records: () -> [StoredSessionInfo]
    private let pending: () -> Set<String>
    private let access: () -> GatewayRecordAccess?
    private let reopen: (String) -> Void
    /// Sessions this run has tried to re-attach. A second unknown answer after a load offers removal, so the app never loops.
    private var reattempted: Set<String> = []

    init(home: GatewayHomeModel,
         client: @escaping () -> GatewayClient?,
         records: @escaping () -> [StoredSessionInfo],
         pending: @escaping () -> Set<String>,
         access: @escaping () -> GatewayRecordAccess?,
         reopen: @escaping (String) -> Void) {
        self.home = home
        self.client = client
        self.records = records
        self.pending = pending
        self.access = access
        self.reopen = reopen
    }

    /// Stops the session's running turn (scope turn, no force). A turn that does not end offers the agent stop.
    func stopTurn(sessionId: String) async {
        guard let client = client() else { return notify(GatewayStopCopy.stopTitle, GatewayStopCopy.notConnected) }
        do {
            let result = try await GatewaySessionStop.stopTurn(client, sessionId: sessionId)
            await home.refresh()
            if result.outcome == .stillRunning {
                await requestAgentStop(sessionId: sessionId)
            } else {
                notify(GatewayStopCopy.stopTitle, GatewayStopCopy.turnMessage(result.outcome))
            }
        } catch {
            handle(error, sessionId: sessionId, title: GatewayStopCopy.stopTitle)
        }
    }

    /// Opens the agent-scope confirmation. It reads the sessions the stop would end, and it stops nothing.
    func requestAgentStop(sessionId: String) async {
        guard let client = client() else { return notify(GatewayStopCopy.stopAgentTitle, GatewayStopCopy.notConnected) }
        do {
            guard let projectId = try await projectId(for: sessionId, client: client) else {
                return await sessionUnknown(sessionId)
            }
            let candidates = try await GatewaySessionStop.agentStopCandidates(client, sessionId: sessionId, projectId: projectId)
            agentStop = AgentStopPrompt(sessionId: sessionId, projectId: projectId, candidates: candidates)
        } catch {
            handle(error, sessionId: sessionId, title: GatewayStopCopy.stopAgentTitle)
        }
    }

    /// Runs the agent stop the person confirmed. `force` is sent only for the sessions they were shown.
    func confirmAgentStop() async {
        guard let prompt = agentStop else { return }
        agentStop = nil
        guard let client = client() else { return notify(GatewayStopCopy.stopAgentTitle, GatewayStopCopy.notConnected) }
        do {
            switch try await GatewaySessionStop.confirmAgentStop(client, sessionId: prompt.sessionId, projectId: prompt.projectId, shown: prompt.candidates) {
            case .done(let result):
                await home.refresh()
                notify(GatewayStopCopy.stopAgentTitle, GatewayStopCopy.agentMessage(result))
            case .listChanged(let now):
                // Sessions started since the person was shown the list: ask again, with the new list. Nothing was sent.
                agentStop = AgentStopPrompt(sessionId: prompt.sessionId, projectId: prompt.projectId, candidates: now)
            }
        } catch {
            handle(error, sessionId: prompt.sessionId, title: GatewayStopCopy.stopAgentTitle)
        }
    }

    /// The explanation behind the stalled flag. It changes nothing.
    func explainStalled() {
        notify(GatewayStopCopy.stalledTitle, GatewayStopCopy.stalledMessage)
    }

    /// A session the gateway does not know. It first loads the session on the agent again, with its stored cwd. Only
    /// when that fails does it offer removal from this phone. It never calls `session/delete`.
    func sessionUnknown(_ sessionId: String) async {
        guard let record = records().first(where: { $0.sessionId == sessionId }), let access = access() else {
            return notify(GatewayStopCopy.stopTitle, GatewayStopCopy.notOnGateway)
        }
        if !reattempted.contains(sessionId) {
            reattempted.insert(sessionId)
            if await GatewayUnknownSession.resolve(sessionId: sessionId, cwd: record.cwd, access: access) == .reattached {
                await home.refresh()
                reopen(sessionId)
                return
            }
        }
        removal = RemovalPrompt(sessionId: sessionId, title: record.title ?? "New Chat")
    }

    /// The person confirmed removing the phone's copy of a record. Only this phone changes.
    func confirmRemoval() {
        guard let prompt = removal else { return }
        removal = nil
        removeFromPhone(sessionId: prompt.sessionId)
    }

    /// Removes a record from this phone: its row and its chat. Neither the gateway nor the agent is called.
    func removeFromPhone(sessionId: String) {
        access()?.removeFromPhone(sessionId: sessionId)
    }

    /// The phone's records the gateway does not list. It reads the gateway's index and changes nothing.
    func phoneOnlyRecords() async throws -> [StoredSessionInfo] {
        guard let client = client() else { throw GatewayError.disconnected }
        let index = try await client.sessions()
        return GatewayOrphanSessions.find(local: records(), gatewayIds: Set(index.map(\.sessionId)), pending: pending())
    }

    private func projectId(for sessionId: String, client: GatewayClient) async throws -> String? {
        if let known = home.sessions.first(where: { $0.sessionId == sessionId }) { return known.projectId }
        return try await client.sessions().first { $0.sessionId == sessionId }?.projectId
    }

    private func handle(_ error: Error, sessionId: String, title: String) {
        if GatewayUnknownSession.isUnknown(error) {
            Task { await sessionUnknown(sessionId) }
            return
        }
        if let gateway = error as? GatewayError, case .rpc(-32001, _) = gateway {
            return notify(title, GatewayStopCopy.otherSessionsChanged)
        }
        notify(title, (error as? GatewayError)?.message ?? error.localizedDescription)
    }

    private func notify(_ title: String, _ message: String) {
        notice = Notice(title: title, message: message)
    }
}
