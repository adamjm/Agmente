import SwiftUI
import ACPClient

/// The words the MCP screens show. Nothing here names a command, an argument, a header or a secret.
enum GatewayMCPCopy {
    static let footer = "Applies to this session only. Changing it later needs a new session."
    static let footerFailed = "MCP servers could not be loaded. The session will start without them."
    static let footerSession = "The change applies from your next message in this session."
    static let turnOpen = "Wait for the current answer to finish, then try again."
    static let unsupported = "This gateway does not support MCP servers."

    /// The line for a failed change. A refusal the gateway gives is shown as its own text.
    static func failure(_ error: Error) -> String {
        if let error = error as? GatewayError { return "Could not change the MCP servers. \(error.message)" }
        return "Could not change the MCP servers. Try again."
    }
}

/// One line per server: name, then transport and host (never a command or a path). Used by both screens.
enum GatewayMCPRowText {
    static func detail(_ server: GatewayMCPServer) -> String {
        if let host = server.host { return "\(server.transportLabel) · \(host)" }
        return server.transportLabel
    }
}

/// The toggle rows of the MCP servers. The caller puts them in a List or a stack.
struct GatewayMCPToggleRows: View {
    @ObservedObject var model: GatewayMCPCatalogModel
    let hint: String

    var body: some View {
        ForEach(model.servers) { server in
            Toggle(isOn: Binding(
                get: { model.isOn(server.id) },
                set: { model.setOn(server.id, $0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                    Text(GatewayMCPRowText.detail(server))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(minHeight: 44)
            .accessibilityHint(hint)
            .accessibilityIdentifier("gatewayMCPToggle.\(server.name)")
        }
    }
}

/// The bulk actions. Each is a 44 pt target.
struct GatewayMCPBulkActions: View {
    @ObservedObject var model: GatewayMCPCatalogModel

    var body: some View {
        HStack(spacing: 8) {
            Button("All on") { model.setAll(true) }
                .accessibilityIdentifier("gatewayMCPAllOn")
            Button("All off") { model.setAll(false) }
                .accessibilityIdentifier("gatewayMCPAllOff")
            Button("Use Mac defaults") { model.useDefaults() }
                .accessibilityIdentifier("gatewayMCPUseDefaults")
        }
        .buttonStyle(.bordered)
        .font(.subheadline)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, minHeight: 44)
    }
}

/// The MCP section of the gateway new-session sheet: a collapsed disclosure row, "MCP servers, 3 of 5 on".
/// The caller shows it only when `model.showsSection` is true.
struct GatewayMCPSessionSection: View {
    @ObservedObject var model: GatewayMCPCatalogModel
    @State private var expanded = false
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 64

    var body: some View {
        Section {
            content
        } footer: {
            Text(footer)
        }
        .onChange(of: model.phase) { _, phase in
            guard phase == .loaded, !model.servers.isEmpty else { return }
            AccessibilityNotification.Announcement("\(model.summary) MCP servers").post()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            HStack {
                Text("MCP servers")
                Spacer()
                ProgressView()
                    .accessibilityLabel("Loading MCP servers")
                Text("Loading").foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("gatewayMCPLoading")
        case .failed:
            HStack {
                Text("MCP servers")
                Spacer()
                Text("Not loaded").foregroundStyle(.secondary)
                Button("Try again") { Task { await model.load() } }
                    .frame(minHeight: 44)
                    .accessibilityHint("Loads the MCP servers again")
                    .accessibilityIdentifier("gatewayMCPRetry")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("gatewayMCPSection")
        case .loaded:
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    GatewayMCPBulkActions(model: model)
                    // A long list scrolls inside the disclosure, not the whole sheet: about six rows show.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            GatewayMCPToggleRows(model: model, hint: "Applies to this session only")
                        }
                    }
                    .frame(height: CGFloat(min(model.servers.count, 6)) * rowHeight)
                }
            } label: {
                HStack {
                    Text("MCP servers")
                    Spacer()
                    Text(model.summary).foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
                .accessibilityLabel("MCP servers, \(model.summary)")
                .accessibilityHint("Shows the servers for this session")
                .accessibilityIdentifier("gatewayMCPDisclosure")
            }
            .accessibilityIdentifier("gatewayMCPSection")
        default:
            EmptyView()
        }
    }

    private var footer: String {
        switch model.phase {
        case .failed: return GatewayMCPCopy.footerFailed
        case .loaded: return GatewayMCPCopy.footer
        default: return ""
        }
    }
}

/// The session header item "MCP N of M" (read-only in the header). Tapping it opens the toggle list, which
/// changes the session's set through `_acpcode/mcp/servers/setEnabled`.
struct GatewayMCPSessionButton: View {
    let sessionId: String
    let clientProvider: () -> GatewayClient?
    @StateObject private var model: GatewayMCPCatalogModel
    @State private var showing = false

    init(sessionId: String, clientProvider: @escaping () -> GatewayClient?) {
        self.sessionId = sessionId
        self.clientProvider = clientProvider
        _model = StateObject(wrappedValue: GatewayMCPCatalogModel(clientProvider: clientProvider))
    }

    var body: some View {
        Button {
            showing = true
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
        }
        .accessibilityLabel(accessibilityTitle)
        .accessibilityHint("Shows the MCP servers this session uses")
        .accessibilityIdentifier("sessionMCPSummary")
        .task {
            await model.load()
            resetToSaved()
        }
        .sheet(isPresented: $showing) {
            GatewayMCPSessionSheet(sessionId: sessionId, model: model)
                .onAppear { resetToSaved() }
        }
    }

    private var title: String {
        guard model.phase == .loaded, !model.servers.isEmpty else { return "MCP" }
        return "MCP \(model.enabledCount) of \(model.servers.count)"
    }

    private var accessibilityTitle: String {
        guard model.phase == .loaded, !model.servers.isEmpty else { return "MCP servers" }
        return "MCP servers, \(model.enabledCount) of \(model.servers.count) on"
    }

    /// The set the session last took, as the phone knows it. A session the phone did not create shows the defaults.
    private func resetToSaved() {
        guard let saved = GatewayMCPMemoryStore.sessionIDs(sessionId: sessionId) else { return }
        model.select(ids: saved)
    }
}

/// The toggle list for a live session. Save calls `setEnabled`; a refusal for an open turn is shown as a short message.
struct GatewayMCPSessionSheet: View {
    let sessionId: String
    @ObservedObject var model: GatewayMCPCatalogModel
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            List {
                switch model.phase {
                case .loaded where !model.servers.isEmpty:
                    Section {
                        GatewayMCPToggleRows(model: model, hint: GatewayMCPCopy.footerSession)
                        GatewayMCPBulkActions(model: model)
                    } footer: {
                        Text(GatewayMCPCopy.footerSession)
                    }
                case .loading, .idle:
                    Section { ProgressView("Loading MCP servers") }
                case .failed:
                    Section {
                        Text("MCP servers could not be loaded.").foregroundStyle(.secondary)
                        Button("Try again") { Task { await model.load() } }
                            .frame(minHeight: 44)
                    }
                case .unsupported:
                    Section { Text(GatewayMCPCopy.unsupported).foregroundStyle(.secondary) }
                case .loaded:
                    Section { Text("This gateway has no MCP servers.").foregroundStyle(.secondary) }
                }
                if let message {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("gatewayMCPSessionMessage")
                    }
                }
            }
            .navigationTitle("MCP servers")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("gatewayMCPSessionCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(saving || model.phase != .loaded || model.servers.isEmpty)
                        .accessibilityIdentifier("gatewayMCPSessionSave")
                }
            }
        }
    }

    private func save() {
        saving = true
        message = nil
        Task {
            do {
                try await model.saveSession(sessionId)
                dismiss()
            } catch GatewayMCPError.turnOpen {
                message = GatewayMCPCopy.turnOpen
            } catch {
                message = GatewayMCPCopy.failure(error)
            }
            saving = false
        }
    }
}
