import Foundation
import ACPClient

/// The gateway's projects and sessions for the selected server (FR-26, D-030). It holds what the
/// last refresh returned, and says why when a refresh failed. It starts no agent: both calls are
/// answered by the gateway from its database.
@MainActor
final class GatewayHomeModel: ObservableObject {
    @Published private(set) var projects: [GatewayProject] = []
    @Published private(set) var sessions: [GatewaySession] = []
    /// The context usage Bob reported per session, from the same index answer (D-093). A session absent here has none.
    @Published private(set) var usage: [String: GatewayUsage] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasLoaded = false
    /// The project the home has selected, such as one just created (D-091). The New Session sheet starts on it.
    @Published private(set) var selectedProjectId: String?
    /// The agent state of each listed project of the server below (D-102, `_acpcode/project/state`). A project
    /// with no entry is unknown and shows nothing. The gateway sends only changes, so a project stays unknown
    /// until its first change after the home starts listing it.
    @Published private(set) var projectStates: [String: GatewayAgentState] = [:]

    /// Resolved at each refresh, so a reconnect (a new connection) is picked up.
    private var clientProvider: (() -> GatewayClient?)?
    private var generation = 0
    /// The server the states above belong to. A state of another server clears them (D-102).
    private var stateServerId: UUID?
    /// States that arrived before the first list of this server loaded. They are kept until the list says
    /// whether the project is listed; a state for a project that is not listed is then dropped.
    private var pendingStates: [String: GatewayAgentState] = [:]

    /// Points the model at a server's gateway, or at none. Anything shown from another server is dropped.
    /// The gateway client of the connection, for an action that the home screen starts (file upload, D-115).
    func uploadClient() -> GatewayClient? { clientProvider?() }

    /// `serverId` is the server the gateway belongs to. When it differs from the server of the states held,
    /// those states are cleared (D-102). A reconnect to the same server keeps them.
    func configure(serverId: UUID? = nil, clientProvider: (() -> GatewayClient?)?) {
        generation += 1
        self.clientProvider = clientProvider
        if let serverId { adoptServer(serverId) }
        projects = []
        sessions = []
        usage = [:]
        errorMessage = nil
        hasLoaded = false
        isLoading = false
        selectedProjectId = nil
    }

    /// The agent state of a listed project, or nil when it is unknown or the project is not listed.
    func agentState(for projectId: String) -> GatewayAgentState? {
        guard projects.contains(where: { $0.id == projectId }) else { return nil }
        return projectStates[projectId]
    }

    /// Records `_acpcode/project/state` for the server it came from. A state for a project that is not on the
    /// list is ignored. `.unknown` clears the project's state, so an unreadable value never shows a stale one.
    func applyProjectState(_ state: GatewayProjectState, serverId: UUID) {
        adoptServer(serverId)
        if hasLoaded {
            guard projects.contains(where: { $0.id == state.projectId }) else { return }
            projectStates[state.projectId] = Self.stored(state.agent)
        } else {
            pendingStates[state.projectId] = Self.stored(state.agent)
        }
    }

    private static func stored(_ agent: GatewayAgentState) -> GatewayAgentState? { agent == .unknown ? nil : agent }

    /// After a list loads: the states of listed projects are kept (the pending ones too), and the rest are dropped.
    private func keepStatesOfListedProjects() {
        let listed = Set(projects.map(\.id))
        var kept = projectStates.filter { listed.contains($0.key) }
        for (projectId, agent) in pendingStates where listed.contains(projectId) { kept[projectId] = agent }
        projectStates = kept
        pendingStates = [:]
    }

    /// Starts holding the states of `serverId`. Another server's states are dropped.
    private func adoptServer(_ serverId: UUID) {
        guard stateServerId != serverId else { return }
        stateServerId = serverId
        projectStates = [:]
        pendingStates = [:]
    }

    /// Selects a project by id. A project the gateway no longer lists is handled by the sheet, which falls
    /// back to the first project.
    func select(projectId: String?) {
        selectedProjectId = projectId
    }

    func sections(search: String = "") -> [GatewayProjectSection] {
        GatewayHomeLayout.sections(projects: projects, sessions: sessions, search: search)
    }

    var activeCount: Int { GatewayHomeLayout.counts(sessions).active }
    var idleCount: Int { GatewayHomeLayout.counts(sessions).idle }
    var totalUnread: Int { sessions.reduce(0) { $0 + $1.unread } }
    var awaitingApprovalCount: Int { sessions.filter { $0.status == .awaitingApproval }.count }

    /// Reloads projects and sessions. An answer that arrives after `configure` changed the server is ignored.
    func refresh() async {
        guard let client = clientProvider?() else { return }
        let mine = generation
        isLoading = true
        defer { if mine == generation { isLoading = false } }
        do {
            async let projectList = client.projects()
            async let sessionList = client.sessionsWithUsage()
            let (loadedProjects, loaded) = try await (projectList, sessionList)
            guard mine == generation else { return }
            projects = loadedProjects
            sessions = loaded.sessions
            usage = loaded.usage
            keepStatesOfListedProjects()
            errorMessage = nil
            hasLoaded = true
        } catch {
            guard mine == generation else { return }
            errorMessage = (error as? GatewayError)?.message ?? error.localizedDescription
        }
    }
}
