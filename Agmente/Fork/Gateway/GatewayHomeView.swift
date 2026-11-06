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
                        Button { open(session.sessionId) } label: { GatewaySessionRow(session: session) }
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

/// New session for a gateway server: pick a project, not a path (FR-26).
struct GatewayNewSessionSheet: View {
    let projects: [GatewayProject]
    let onCancel: () -> Void
    let onCreate: (GatewayProject) -> Void
    @State private var selection: String?

    var body: some View {
        NavigationStack {
            List(projects) { project in
                Button {
                    selection = project.id
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name).foregroundStyle(.primary)
                            Text(project.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if selection == project.id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                    }
                }
                .accessibilityIdentifier("gatewayProjectChoice.\(project.id)")
            }
            .overlay {
                if projects.isEmpty {
                    Text("No projects on the gateway").foregroundStyle(.secondary)
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
                        if let project = projects.first(where: { $0.id == selection }) { onCreate(project) }
                    }
                    .disabled(selection == nil)
                    .accessibilityIdentifier("gatewayCreateSession")
                }
            }
        }
    }
}
