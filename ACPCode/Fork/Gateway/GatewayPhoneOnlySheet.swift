import SwiftUI
import ACPClient

/// The sessions on this phone that the gateway does not list (D-106). Opening it changes nothing. Each row can be
/// removed from this phone after a confirmation. The gateway and the agent are never changed from here.
struct GatewayPhoneOnlySheet: View {
    let actions: GatewaySessionActions
    let onClose: () -> Void
    @State private var records: [StoredSessionInfo]?
    @State private var errorMessage: String?
    @State private var pendingRemoval: StoredSessionInfo?

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("gatewayPhoneOnlyError")
                } else if let records {
                    if records.isEmpty {
                        Text("Every session on this phone is on the gateway.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("gatewayPhoneOnlyEmpty")
                    } else {
                        Section {
                            ForEach(records) { record in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(record.title ?? "New Chat")
                                            .lineLimit(1)
                                        if let cwd = record.cwd {
                                            Text(cwd)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    Button("Remove", role: .destructive) {
                                        pendingRemoval = record
                                    }
                                    .accessibilityLabel("Remove \(record.title ?? "New Chat") from this phone")
                                    .accessibilityIdentifier("gatewayPhoneOnlyRemove.\(record.sessionId)")
                                }
                            }
                        } footer: {
                            Text("These sessions are on this phone only. The gateway does not list them.")
                        }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Loading")
                        .accessibilityIdentifier("gatewayPhoneOnlyLoading")
                }
            }
            .navigationTitle("On this phone only")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onClose)
                        .accessibilityIdentifier("gatewayPhoneOnlyDone")
                }
            }
            .task { await load() }
            .confirmationDialog(
                GatewayRemovalCopy.title,
                isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                titleVisibility: .visible,
                presenting: pendingRemoval
            ) { record in
                Button(GatewayRemovalCopy.button, role: .destructive) {
                    remove(record)
                }
                .accessibilityIdentifier("gatewayPhoneOnlyRemoveConfirm")
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(GatewayRemovalCopy.message)
            }
        }
    }

    private func load() async {
        do {
            records = try await actions.phoneOnlyRecords()
        } catch {
            errorMessage = (error as? GatewayError)?.message ?? error.localizedDescription
        }
    }

    private func remove(_ record: StoredSessionInfo) {
        actions.removeFromPhone(sessionId: record.sessionId)
        records?.removeAll { $0.sessionId == record.sessionId }
    }
}
