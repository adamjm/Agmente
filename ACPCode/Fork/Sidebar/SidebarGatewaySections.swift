import SwiftUI
import ACPClient

// The gateway home in the sidebar style (FR-26). It uses the same model, ordering, search and actions as
// `GatewayHomeSections`: sessions grouped by project, newest first, with the agent state and git chip on
// each project header. Only the rows and headers are drawn differently.

/// The project header above a group of sessions on the gateway home: a grey folder label with the unread
/// count, the agent state and the git chip, as before.
private struct SidebarProjectHeader: View {
    let section: GatewayProjectSection
    @ObservedObject var home: GatewayHomeModel
    var git: GitStore?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.subheadline)
                .accessibilityHidden(true)
            Text(section.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if section.unread > 0 {
                Text("\(section.unread)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(.white)
                    .accessibilityLabel("\(section.unread) unread")
            }
            if let agent = home.agentState(for: section.id) {
                GatewayAgentStateLabel(projectId: section.id, agent: agent)
            }
            Spacer(minLength: 8)
            if let git, section.project != nil, git.supportsGit {
                GitHomeChip(store: git, projectId: section.id)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, SidebarStyle.rowHorizontalPadding)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gatewayProject.\(section.id)")
    }
}

/// The gateway's sessions, grouped by project. Rows open the session through `open`.
struct SidebarGatewaySections: View {
    @ObservedObject var home: GatewayHomeModel
    let search: String
    var git: GitStore?
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let message = home.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, SidebarStyle.rowHorizontalPadding)
                    .accessibilityIdentifier("gatewayHomeError")
            }
            let sections = home.sections(search: search)
            if sections.isEmpty && home.hasLoaded {
                Text(search.isEmpty ? "No projects yet. Register one on the gateway to start a session." : "No matching sessions")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 28)
                    .accessibilityIdentifier("gatewayHomeEmpty")
            }
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 2) {
                    SidebarProjectHeader(section: section, home: home, git: git)
                    if section.sessions.isEmpty {
                        Text("No sessions yet")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, SidebarStyle.rowHorizontalPadding)
                            .padding(.vertical, SidebarStyle.rowVerticalPadding)
                    }
                    ForEach(section.sessions) { session in
                        Button { open(session.sessionId) } label: {
                            SidebarSessionRow(
                                title: session.title ?? "New Chat",
                                status: ForkStatusKind(session.status),
                                unread: session.unread,
                                isHighlighted: session.status == .running
                            )
                            .overlay(alignment: .bottom) {
                                GatewayContextBar(usage: home.usage[session.sessionId])
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("gatewaySession.\(session.sessionId)")
                    }
                }
                .id(SidebarScroll.project(section.id))
            }
        }
    }
}

/// The "Projects" row's sheet: every registered project, with its session count. Choosing one closes the
/// sheet and scrolls the home to that project's group.
struct SidebarProjectsSheet: View {
    @ObservedObject var home: GatewayHomeModel
    let onPick: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List(home.projects) { project in
                let count = home.sessions.filter { $0.projectId == project.id }.count
                Button {
                    onPick(project.id)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(project.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        Text(count == 1 ? "1 session" : "\(count) sessions")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("sidebarProject.\(project.id)")
            }
            .navigationTitle("Projects")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
    }
}
