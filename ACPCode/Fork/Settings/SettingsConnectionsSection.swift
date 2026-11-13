import SwiftUI

/// The forms behind "Add connection" and "Edit". They are the existing `AddServerView`; this only wires
/// them to the same `AppViewModel` calls that ContentView uses for its own add and edit sheets.
@MainActor
enum SettingsServerForms {
    private typealias Validator = (String, String, String, String, String, String, String, ServerType, ServerSecurityInput) async -> Result<ValidatedServerConfiguration, Error>

    private static func validator(_ model: AppViewModel) -> Validator {
        { name, scheme, host, token, cfAccessClientId, cfAccessClientSecret, workingDirectory, serverType, security in
            await model.validateServerConfiguration(
                name: name,
                scheme: scheme,
                host: host,
                token: token,
                cfAccessClientId: cfAccessClientId,
                cfAccessClientSecret: cfAccessClientSecret,
                workingDirectory: workingDirectory,
                serverType: serverType,
                security: security
            )
        }
    }

    static func addView(model: AppViewModel) -> some View {
        AddServerView(
            onValidate: validator(model),
            onInsert: { validated in
                model.addValidatedServer(validated)
            }
        )
    }

    static func editView(server: ACPServerConfiguration, model: AppViewModel) -> some View {
        // D-105: Git credentials are offered only for the gateway this server is connected to.
        let offersGitCredentials = model.selectedServerId == server.id && model.selectedServerViewModel?.isGatewayServer == true
        return AddServerView(
            editingServer: server,
            onValidate: validator(model),
            onInsert: { validated in
                model.updateServer(server.id, with: validated)
            },
            gitCredentialsClient: offersGitCredentials ? { [weak model] in model?.selectedGatewayClient() } : nil,
            gitCredentialsScheme: server.scheme
        )
    }
}

/// The Connections part of Settings: one row per connection and a row that adds one.
struct SettingsConnectionsSection: View {
    @ObservedObject var model: AppViewModel
    @State private var showingAdd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionLabel("Connections")
            SettingsCard {
                ForEach(model.servers) { server in
                    connectionLink(for: server)
                }
                Button {
                    showingAdd = true
                } label: {
                    SettingsRow(icon: "plus.circle", title: "Add connection", iconColor: .accentColor)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settingsAddConnection")
            }
        }
        .sheet(isPresented: $showingAdd) {
            SettingsServerForms.addView(model: model)
        }
    }

    private func connectionLink(for server: ACPServerConfiguration) -> some View {
        let row = SettingsConnectionRowModel.make(
            server: server,
            selectedServerId: model.selectedServerId,
            connectionState: model.connectionState,
            isGateway: model.selectedServerViewModel?.isGatewayServer == true
        )
        return NavigationLink {
            SettingsConnectionDetailView(model: model, serverId: server.id)
        } label: {
            SettingsRow(
                icon: row.iconName,
                title: row.title,
                subtitle: row.subtitle,
                showsChevron: true,
                showsDivider: true
            ) {
                HStack(spacing: 8) {
                    if let status = row.status {
                        Circle()
                            .fill(Self.dotColor(status))
                            .frame(width: 9, height: 9)
                            .accessibilityLabel(Self.statusLabel(status))
                    }
                    if row.isSelected {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.tint)
                            .accessibilityLabel("Selected")
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(row.accessibilityIdentifier)
    }

    private static func dotColor(_ status: SettingsConnectionStatus) -> Color {
        switch status {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .gray
        case .failed: return .red
        }
    }

    private static func statusLabel(_ status: SettingsConnectionStatus) -> String {
        switch status {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .disconnected: return "Disconnected"
        case .failed: return "Connection failed"
        }
    }
}
