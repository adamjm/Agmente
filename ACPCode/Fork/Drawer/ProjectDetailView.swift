import SwiftUI
import ACPClient

// A project's screen in the main area (D-109): its name as the title, its sessions newest first, and a
// "New session" button that uses the same sheet as the gateway's new-session flow, with this project chosen.

struct ProjectDetailView: View {
    @ObservedObject var home: GatewayHomeModel
    let projectId: String
    let isConnected: Bool
    let mcpClient: () -> GatewayClient?
    /// Opens a session in the main area (the caller pushes it).
    let onOpenSession: (String) -> Void
    /// Starts a session in the chosen project. The caller sends it, as the gateway's new-session flow does.
    let onCreateSession: (GatewayProject, [String]?) -> Void

    @State private var showingNewSession = false
    /// The Upload File sheet for this project (D-115).
    @State private var showingUpload = false

    private var project: GatewayProject? {
        home.projects.first { $0.id == projectId }
    }

    var body: some View {
        Group {
            if let project {
                details(for: project)
            } else {
                Text("This project is no longer listed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("projectDetailMissing")
            }
        }
        .navigationTitle(project?.name ?? "Project")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .sheet(isPresented: $showingNewSession) {
            GatewayNewSessionSheet(
                projects: home.projects,
                initialSelection: projectId,
                mcpClient: mcpClient,
                onCancel: { showingNewSession = false },
                onCreate: { chosen, mcpIDs in
                    onCreateSession(chosen, mcpIDs)
                    showingNewSession = false
                }
            )
        }
        .sheet(isPresented: $showingUpload) {
            GatewayFileUploadSheet(
                projectId: projectId,
                projectName: project?.name ?? "project",
                clientProvider: { home.uploadClient() },
                onClose: { showingUpload = false }
            )
        }
    }

    private func details(for project: GatewayProject) -> some View {
        let sessions = ProjectsLogic.sessions(in: project.id, from: home.sessions)
        return List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(project.path)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if let agent = home.agentState(for: project.id), let text = GatewayAgentStatePresentation.label(agent) {
                        Text(text)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(agent == .running ? Color.blue : Color.secondary)
                    }
                }
                Button {
                    showingNewSession = true
                } label: {
                    Label("New session", systemImage: "square.and.pencil")
                        .font(.body.weight(.semibold))
                        .forkHitTarget()
                }
                .disabled(!isConnected)
                .accessibilityIdentifier("projectNewSessionButton")
                Button {
                    showingUpload = true
                } label: {
                    Label("Upload File", systemImage: "square.and.arrow.up")
                        .font(.body.weight(.semibold))
                        .forkHitTarget()
                }
                .disabled(!isConnected)
                .accessibilityIdentifier("projectUploadButton")
            }

            Section {
                if sessions.isEmpty {
                    Text("No sessions yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(sessions) { session in
                    Button {
                        onOpenSession(session.sessionId)
                    } label: {
                        SidebarSessionRow(
                            title: session.title ?? "New Chat",
                            status: ForkStatusKind(session.status),
                            unread: session.unread,
                            isHighlighted: session.status == .running
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets())
                    .accessibilityIdentifier("gatewaySession.\(session.sessionId)")
                }
            } header: {
                Text("Sessions")
            }
        }
#if os(iOS)
        .listStyle(.insetGrouped)
#endif
        .refreshable { await home.refresh() }
    }
}
