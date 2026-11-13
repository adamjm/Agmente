import SwiftUI
import ACPClient

// The Projects view in the main area of the iOS drawer layout (D-109): every project of the gateway, the
// empty state, and the "New project" capsule. Pure sorting and counting live in `ProjectsLogic`.

/// Sorting and counting for projects and their sessions. No view state.
enum ProjectsLogic {
    /// The sessions of one project, newest activity first. A session with no readable date sorts last. Ties
    /// are broken by session id, so the order is the same on every call.
    static func sessions(in projectId: String, from sessions: [GatewaySession]) -> [GatewaySession] {
        sessions.filter { $0.projectId == projectId }.sorted(by: isNewer)
    }

    static func sessionCount(projectId: String, sessions: [GatewaySession]) -> Int {
        sessions.reduce(0) { $0 + ($1.projectId == projectId ? 1 : 0) }
    }

    static func sessionCountLabel(_ count: Int) -> String {
        count == 1 ? "1 session" : "\(count) sessions"
    }

    static func isNewer(_ lhs: GatewaySession, _ rhs: GatewaySession) -> Bool {
        switch (lhs.lastActivityDate, rhs.lastActivityDate) {
        case let (left?, right?):
            if left != right { return left > right }
            return lhs.sessionId < rhs.sessionId
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.sessionId < rhs.sessionId
        }
    }
}

/// The main area when a gateway server has no session open: its projects, or an empty state.
struct ProjectsView: View {
    @ObservedObject var home: GatewayHomeModel
    let isConnected: Bool
    let clientProvider: () -> GatewayClient?
    let connectionScheme: String
    let onOpenProject: (String) -> Void

    @State private var showingNewProject = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content
            newProjectButton
        }
        .navigationTitle("Projects")
#if os(iOS)
        .navigationBarTitleDisplayMode(.large)
#endif
        .sheet(isPresented: $showingNewProject) {
            GatewayNewProjectSheet(
                clientProvider: clientProvider,
                connectionScheme: connectionScheme,
                onCreated: { project in
                    await home.refresh()
                    home.select(projectId: project.id)
                },
                onClose: { showingNewProject = false }
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if home.projects.isEmpty {
            if home.hasLoaded {
                emptyState
            } else {
                ProgressView("Loading projects")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            projectList
        }
    }

    private var projectList: some View {
        List {
            if let message = home.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("projectsError")
            }
            ForEach(home.projects) { project in
                Button {
                    onOpenProject(project.id)
                } label: {
                    ProjectRowLabel(
                        project: project,
                        sessionCount: ProjectsLogic.sessionCount(projectId: project.id, sessions: home.sessions),
                        agent: home.agentState(for: project.id)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("projectRow.\(project.id)")
            }
        }
        .refreshable { await home.refresh() }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray.full")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 88, height: 88)
                .background(Circle().fill(Color(.systemGray5)))
                .accessibilityHidden(true)
            Text("No projects yet")
                .font(.title3.weight(.semibold))
            Text("Create one to organize sessions around a folder on your Mac.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("projectsEmpty")
    }

    private var newProjectButton: some View {
        Button {
            showingNewProject = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                Text("New project")
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.leading, 18)
            .padding(.trailing, 20)
            .frame(minHeight: 50)
            .background(Capsule().fill(SidebarStyle.pillTint(for: colorScheme)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isConnected)
        .opacity(isConnected ? 1 : 0.6)
        .padding(.trailing, 16)
        .padding(.bottom, 16)
        .accessibilityIdentifier("projectsNewProjectButton")
    }
}

/// One project in the list: name, path (middle truncated), session count and the agent state when there is one.
struct ProjectRowLabel: View {
    let project: GatewayProject
    let sessionCount: Int
    let agent: GatewayAgentState?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: SidebarStyle.rowIconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(project.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(ProjectsLogic.sessionCountLabel(sessionCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let agent, let text = GatewayAgentStatePresentation.label(agent) {
                        Text(text)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(agent == .running ? Color.blue : Color.secondary)
                    }
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, SidebarStyle.rowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// The main area for a server that is not a gateway, when no session is open (D-109). The button opens the drawer.
struct NoSessionOpenView: View {
    let onOpenDrawer: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 88, height: 88)
                .background(Circle().fill(Color(.systemGray5)))
                .accessibilityHidden(true)
            Text("No session open")
                .font(.title3.weight(.semibold))
            Button("Show sessions", action: onOpenDrawer)
                .buttonStyle(.borderedProminent)
                .forkHitTarget()
                .accessibilityIdentifier("noSessionOpenDrawerButton")
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}
