import Foundation
import ACPClient

/// The gateway's projects and sessions for the selected server (FR-26, D-030). It holds what the
/// last refresh returned, and says why when a refresh failed. It starts no agent: both calls are
/// answered by the gateway from its database.
@MainActor
final class GatewayHomeModel: ObservableObject {
    @Published private(set) var projects: [GatewayProject] = []
    @Published private(set) var sessions: [GatewaySession] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasLoaded = false

    /// Resolved at each refresh, so a reconnect (a new connection) is picked up.
    private var clientProvider: (() -> GatewayClient?)?
    private var generation = 0

    /// Points the model at a server's gateway, or at none. Anything shown from another server is dropped.
    func configure(clientProvider: (() -> GatewayClient?)?) {
        generation += 1
        self.clientProvider = clientProvider
        projects = []
        sessions = []
        errorMessage = nil
        hasLoaded = false
        isLoading = false
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
            async let sessionList = client.sessions()
            let (loadedProjects, loadedSessions) = try await (projectList, sessionList)
            guard mine == generation else { return }
            projects = loadedProjects
            sessions = loadedSessions
            errorMessage = nil
            hasLoaded = true
        } catch {
            guard mine == generation else { return }
            errorMessage = (error as? GatewayError)?.message ?? error.localizedDescription
        }
    }
}
