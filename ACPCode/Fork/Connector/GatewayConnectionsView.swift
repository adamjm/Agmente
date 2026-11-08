import SwiftUI
import ACPClient

/// The one toolbar button on the gateway home that opens the Connections screen (D-097).
struct GatewayConnectionsButton: View {
    let clientProvider: () -> GatewayClient?
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "link")
        }
        .accessibilityLabel("Connections")
        .accessibilityIdentifier("gatewayConnections")
        .sheet(isPresented: $showing) {
            GatewayConnectionsView(clientProvider: clientProvider) { showing = false }
        }
    }
}

/// Pending client pairings (approve or deny, with the code to check against the client's page) and the
/// grants already made (revoke). Reads on appear, on pull, and every few seconds while it is on screen.
struct GatewayConnectionsView: View {
    @StateObject private var model: GatewayConnectionsModel
    let onClose: () -> Void
    @State private var approving: GatewayConnectorPairing?
    @State private var revoking: GatewayConnectorGrant?

    init(clientProvider: @escaping () -> GatewayClient?, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: GatewayConnectionsModel(clientProvider: clientProvider))
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack {
            List {
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("connectionsError")
                }
                Section("Waiting to connect") {
                    if model.pairings.isEmpty {
                        Text("No client is waiting. Add a connector in Claude, and its code will appear here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("connectionsNoPairings")
                    }
                    ForEach(model.pairings) { pairing in
                        PairingRow(
                            pairing: pairing,
                            busy: model.isBusy(pairing.pairingId),
                            onApprove: { approving = pairing },
                            onDeny: { Task { await model.deny(pairing) } }
                        )
                    }
                }
                Section("Connected clients") {
                    if model.grants.isEmpty {
                        Text("No client is connected.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("connectionsNoGrants")
                    }
                    ForEach(model.grants) { grant in
                        GrantRow(grant: grant, busy: model.isBusy(grant.grantId), onRevoke: { revoking = grant })
                    }
                }
            }
            .refreshable { await model.refresh() }
            .task {
                await model.refresh()
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: GatewayConnectionsModel.pollSeconds * 1_000_000_000)
                    guard !Task.isCancelled else { break }
                    await model.refresh()
                }
            }
            .navigationTitle("Connections")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onClose) }
            }
            .sheet(item: $approving) { pairing in
                ApproveSheet(model: model, pairing: pairing) { approving = nil }
            }
            .confirmationDialog(
                "Revoke this client?",
                isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
                presenting: revoking
            ) { grant in
                Button("Revoke", role: .destructive) { Task { await model.revoke(grant) } }
                    .accessibilityIdentifier("connectionsRevokeConfirm")
            } message: { grant in
                Text("\(grant.label) loses access now. It can connect again only after a new pairing.")
            }
        }
    }
}

private struct PairingRow: View {
    let pairing: GatewayConnectorPairing
    let busy: Bool
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pairing.clientName).font(.headline)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(GatewayConnectionsModel.timeLeftText(expiresAt: pairing.expiresDate, now: context.date))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("connectionsTimeLeft.\(pairing.pairingId)")
                    }
                }
                Spacer()
                Text(GatewayConnectionsModel.displayCode(pairing.code))
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                    .accessibilityLabel("Code \(GatewayConnectionsModel.displayCode(pairing.code))")
                    .accessibilityIdentifier("connectionsCode.\(pairing.pairingId)")
            }
            HStack(spacing: 10) {
                Button("Deny", role: .destructive, action: onDeny)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("connectionsDeny.\(pairing.pairingId)")
                Button("Approve", action: onApprove)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("connectionsApprove.\(pairing.pairingId)")
            }
            .disabled(busy)
        }
        .padding(.vertical, 4)
        .opacity(busy ? 0.6 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connectionsPairing.\(pairing.pairingId)")
    }
}

private struct GrantRow: View {
    let grant: GatewayConnectorGrant
    let busy: Bool
    let onRevoke: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(grant.label).font(.headline)
                Text(grant.scope.summary).font(.caption).foregroundStyle(.secondary)
                Text(lastUsedText).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("connectionsLastUsed.\(grant.grantId)")
            }
            Spacer()
            Button("Revoke", role: .destructive, action: onRevoke)
                .buttonStyle(.bordered)
                .disabled(busy)
                .accessibilityIdentifier("connectionsRevoke.\(grant.grantId)")
        }
        .opacity(busy ? 0.6 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connectionsGrant.\(grant.grantId)")
    }

    private var lastUsedText: String {
        guard let date = grant.lastUsedDate else { return "Never used" }
        return "Last used \(date.formatted(.relative(presentation: .named)))"
    }
}

/// The scope choice for one pairing. One session is the default and needs a session picked; all projects
/// needs nothing else. Approve sends exactly the scope shown.
private struct ApproveSheet: View {
    @ObservedObject var model: GatewayConnectionsModel
    let pairing: GatewayConnectorPairing
    let onDone: () -> Void
    @State private var choice: GatewayConnectionsModel.ScopeChoice = .oneSession
    @State private var sending = false

    private var canApprove: Bool {
        !sending && !model.isBusy(pairing.pairingId) && model.scope(for: choice) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Check that this code matches the one on the client's page.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(GatewayConnectionsModel.displayCode(pairing.code))
                        .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("connectionsApproveCode")
                }
                Section {
                    Picker("Access", selection: $choice) {
                        Text("One session").tag(GatewayConnectionsModel.ScopeChoice.oneSession)
                        Text("All projects").tag(GatewayConnectionsModel.ScopeChoice.allProjects)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("connectionsScopePicker")
                } footer: {
                    Text(choice == .oneSession
                         ? "The client may use only the session you pick below."
                         : "The client may use any project and any session on this gateway.")
                }
                if choice == .oneSession {
                    Section("Session") {
                        if model.sessions.isEmpty {
                            Text(model.sessionsMessage ?? "No sessions yet. Start one on the gateway, or choose All projects.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("connectionsNoSessions")
                        }
                        ForEach(model.sessions) { session in
                            Button {
                                model.selectedSessionId = session.sessionId
                            } label: {
                                HStack {
                                    Text(session.title ?? "New Chat").foregroundStyle(.primary).lineLimit(1)
                                    Spacer()
                                    if model.selectedSessionId == session.sessionId {
                                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            .accessibilityIdentifier("connectionsSession.\(session.sessionId)")
                        }
                    }
                }
                if let message = model.errorMessage {
                    Text(message).font(.footnote).foregroundStyle(.orange)
                        .accessibilityIdentifier("connectionsApproveError")
                }
            }
            .navigationTitle("Approve \(pairing.clientName)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Approve") {
                        Task {
                            sending = true
                            let approved = await model.approve(pairing, choice: choice)
                            sending = false
                            if approved { onDone() }
                        }
                    }
                    .disabled(!canApprove)
                    .accessibilityIdentifier("connectionsApproveConfirm")
                }
            }
            .task { await model.loadSessions() }
        }
    }
}
