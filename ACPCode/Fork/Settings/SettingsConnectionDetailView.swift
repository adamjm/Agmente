import SwiftUI

/// One connection in Settings: use it, edit it, delete it, and read its facts.
/// It never shows a token, a passphrase or a key. A client certificate appears only as stored or not.
struct SettingsConnectionDetailView: View {
    @ObservedObject var model: AppViewModel
    let serverId: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var showingEdit = false
    @State private var confirmDelete = false
    @State private var hasClientCertificate = false

    private var server: ACPServerConfiguration? {
        model.servers.first { $0.id == serverId }
    }

    var body: some View {
        ScrollView {
            if let server {
                content(for: server)
            } else {
                ContentUnavailableView("This connection was removed", systemImage: "server.rack")
                    .padding(.top, 48)
            }
        }
        .background(ForkColor.surfaceGrouped.ignoresSafeArea())
        .navigationTitle(server?.name ?? "Connection")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .onAppear(perform: reloadCertificateState)
        .onChange(of: showingEdit) { _, isShowing in
            if !isShowing { reloadCertificateState() }
        }
        .sheet(isPresented: $showingEdit) {
            if let server {
                SettingsServerForms.editView(server: server, model: model)
            }
        }
        .alert("Delete Server", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                model.deleteServer(serverId)
                dismiss()
            }
        } message: {
            Text("Are you sure you want to delete \"\(server?.name ?? "")\"? This will remove all cached sessions for this server.")
        }
    }

    private func content(for server: ACPServerConfiguration) -> some View {
        let isSelected = model.selectedServerId == server.id
        let facts = SettingsConnectionFacts.make(
            server: server,
            hasClientCertificate: hasClientCertificate,
            agentName: isSelected ? model.currentAgentInfo?.name : nil,
            agentVersion: isSelected ? model.currentAgentInfo?.version : nil
        )
        return VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                SettingsCard {
                    Button {
                        model.selectServer(server.id)
                    } label: {
                        SettingsRow(
                            icon: "checkmark.circle",
                            title: "Use this connection",
                            value: isSelected ? "In use" : nil,
                            showsDivider: true
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSelected)
                    .accessibilityIdentifier("settingsUseConnection")

                    Button {
                        showingEdit = true
                    } label: {
                        SettingsRow(icon: "pencil", title: "Edit", showsChevron: true, showsDivider: true)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settingsEditConnection")

                    Button {
                        confirmDelete = true
                    } label: {
                        SettingsRow(icon: "trash", title: "Delete", iconColor: .red, titleColor: .red)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settingsDeleteConnection")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionLabel("Details")
                SettingsCard {
                    SettingsRow(icon: "lock", title: "Scheme", value: facts.scheme, showsDivider: true)
                    SettingsRow(icon: "network", title: "Host", value: facts.host.isEmpty ? "None" : facts.host, showsDivider: true)
                    SettingsRow(
                        icon: "person.badge.key",
                        title: "Client certificate",
                        value: facts.clientCertificateStored ? "Stored on this device" : "None",
                        showsDivider: true
                    )
                    SettingsRow(icon: "cpu", title: "Agent", value: facts.agent ?? "Not known until connected")
                }
            }
        }
        .readableColumn()
        .padding(16)
    }

    private func reloadCertificateState() {
        // Only whether an identity is stored is read. The identity itself is never shown.
        hasClientCertificate = ClientIdentityStore.shared.load(serverId: serverId) != nil
    }
}
