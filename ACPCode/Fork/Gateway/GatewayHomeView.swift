import SwiftUI
import ACPClient

/// A status badge for a gateway session: idle shows nothing, the others show a colour and a word.
struct GatewayStatusBadge: View {
    let status: GatewaySessionStatus

    var body: some View {
        if let label {
            Text(label)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(color.opacity(0.18)))
                .foregroundStyle(color)
                .accessibilityIdentifier("gatewayStatus.\(status.rawValue)")
        }
    }

    private var label: String? {
        switch status {
        case .idle: return nil
        case .running: return "Running"
        case .awaitingApproval: return "Needs approval"
        case .error: return "Error"
        case .unknown(let value): return value
        }
    }

    private var color: Color {
        switch status {
        case .running: return .blue
        case .awaitingApproval: return .orange
        case .error: return .red
        default: return .gray
        }
    }
}

/// The words, accessibility text and colour of a project's agent state (D-102). Unknown has no words and
/// shows nothing.
enum GatewayAgentStatePresentation {
    static func label(_ agent: GatewayAgentState) -> String? {
        switch agent {
        case .stopped: return "Idle"
        case .starting: return "Starting"
        case .running: return "Running"
        case .stopping: return "Stopping"
        case .unknown: return nil
        }
    }

    static func accessibilityLabel(_ agent: GatewayAgentState) -> String? {
        switch agent {
        case .stopped: return "Agent idle"
        case .starting: return "Agent starting"
        case .running: return "Agent running"
        case .stopping: return "Agent stopping"
        case .unknown: return nil
        }
    }

    /// Only a running agent shows a progress indicator.
    static func showsProgress(_ agent: GatewayAgentState) -> Bool { agent == .running }
}

/// A project's agent state on its header in the gateway home.
struct GatewayAgentStateLabel: View {
    let projectId: String
    let agent: GatewayAgentState

    var body: some View {
        if let text = GatewayAgentStatePresentation.label(agent) {
            HStack(spacing: 5) {
                if GatewayAgentStatePresentation.showsProgress(agent) {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(text)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(agent == .running ? Color.blue : Color.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(GatewayAgentStatePresentation.accessibilityLabel(agent) ?? text)
            .accessibilityIdentifier("gatewayProjectState.\(projectId)")
        }
    }
}

/// Sessions grouped by project, newest first, with a status badge and an unread count (FR-26).
struct GatewayHomeSections: View {
    @ObservedObject var home: GatewayHomeModel
    let search: String
    var git: GitStore?
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let message = home.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("gatewayHomeError")
            }
            let sections = home.sections(search: search)
            if sections.isEmpty && home.hasLoaded {
                Text(search.isEmpty ? "No projects yet. Register one on the gateway to start a session." : "No matching sessions")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 28)
                    .accessibilityIdentifier("gatewayHomeEmpty")
            }
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                        Text(section.title).font(.headline)
                        if section.unread > 0 {
                            Text("\(section.unread)")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor))
                                .foregroundStyle(.white)
                        }
                        if let agent = home.agentState(for: section.id) {
                            GatewayAgentStateLabel(projectId: section.id, agent: agent)
                        }
                        Spacer()
                        if let git, section.project != nil, git.supportsGit {
                            GitHomeChip(store: git, projectId: section.id)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("gatewayProject.\(section.id)")
                    if section.sessions.isEmpty {
                        Text("No sessions yet").font(.footnote).foregroundStyle(.tertiary)
                    }
                    ForEach(section.sessions) { session in
                        Button { open(session.sessionId) } label: { GatewaySessionRow(session: session).overlay(alignment: .bottom) { GatewayContextBar(usage: home.usage[session.sessionId]) } }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("gatewaySession.\(session.sessionId)")
                    }
                }
            }
        }
    }
}

struct GatewaySessionRow: View {
    let session: GatewaySession

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title ?? "New Chat")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                if let date = session.lastActivityDate {
                    Text(date, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            GatewayStatusBadge(status: session.status)
            if session.unread > 0 {
                Text("\(session.unread)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(.white)
                    .accessibilityLabel("\(session.unread) unread")
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sessionCardStyle()
    }
}

/// New session for a gateway server: pick a project, not a path (FR-26). The first project is the
/// default; Create stays off while there is no project to start in.
struct GatewayNewSessionSheet: View {
    let projects: [GatewayProject]
    /// The chosen MCP ids (D-107), or nil to send no key. The list is loaded from the gateway.
    let onCancel: () -> Void
    let onCreate: (GatewayProject, [String]?) -> Void
    @State private var selection: String?
    @StateObject private var mcp: GatewayMCPCatalogModel

    /// `initialSelection` is the project the home has selected (D-091), when it is still listed.
    /// `mcpClient` gives the gateway client for the MCP servers section (D-107).
    init(
        projects: [GatewayProject],
        initialSelection: String? = nil,
        mcpClient: @escaping () -> GatewayClient? = { nil },
        onCancel: @escaping () -> Void,
        onCreate: @escaping (GatewayProject, [String]?) -> Void
    ) {
        self.projects = projects
        self.onCancel = onCancel
        self.onCreate = onCreate
        _selection = State(initialValue: initialSelection)
        _mcp = StateObject(wrappedValue: GatewayMCPCatalogModel(clientProvider: mcpClient))
    }

    private var chosen: GatewayProject? { gatewayNewSessionChosenProject(projects, selection: selection) }

    var body: some View {
        NavigationStack {
            List {
                ForEach(projects) { project in
                    Button {
                        selection = project.id
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.name).foregroundStyle(.primary)
                                Text(project.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if chosen?.id == project.id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                    }
                    .accessibilityIdentifier("gatewayProjectChoice.\(project.id)")
                }
                if mcp.showsSection {
                    GatewayMCPSessionSection(model: mcp)
                }
            }
            .task { await mcp.load(projectId: chosen?.id) }
            .onChange(of: chosen?.id) { _, id in mcp.selectProject(id) }
            .overlay {
                if projects.isEmpty {
                    Text("No projects. Add one on the gateway.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                        .accessibilityIdentifier("gatewayNoProjects")
                }
            }
            .navigationTitle("New Session")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        if let project = chosen, gatewayNewSessionCwd(selectedProjectPath: project.path) != nil {
                            onCreate(project, mcp.idsToSend)
                        }
                    }
                    .disabled(chosen == nil || gatewayNewSessionCwd(selectedProjectPath: chosen?.path) == nil)
                    .accessibilityIdentifier("gatewayCreateSession")
                }
            }
        }
    }
}
