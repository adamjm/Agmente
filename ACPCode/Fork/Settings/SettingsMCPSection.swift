import SwiftUI
import ACPClient

/// The MCP servers part of Settings. It shows for the same connections as the More menu's MCP Servers row
/// (`MCPEntryPoint.settingsMode`). A gateway connection gets two rows: the phone's own list, pushed here rather
/// than in its own sheet, and the gateway's global list, read-only (D-107).
struct SettingsMCPSection: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        let mode = MCPEntryPoint.settingsMode(
            hasSelection: model.selectedServerId != nil,
            isGateway: model.selectedServerViewModel?.isGatewayServer ?? false
        )
        if mode != .hidden {
            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionLabel("MCP servers")
                SettingsCard {
                    if mode == .servers, let serverId = model.selectedServerId {
                        SettingsMCPServersLink(serverId: serverId)
                            .id(serverId)
                        Divider()
                        SettingsGatewayMCPLink(clientProvider: { [weak model] in model?.selectedGatewayClient() })
                            .id(serverId)
                    } else {
                        SettingsRow(icon: "puzzlepiece.extension", title: "Select a connection first", titleColor: .secondary)
                            .accessibilityIdentifier("settingsMCPSelectConnectionFirst")
                    }
                }
            }
        }
    }
}

/// The row that pushes the phone's own MCP server list for one connection. The count is the number of saved entries.
private struct SettingsMCPServersLink: View {
    @StateObject private var list: MCPServersModel

    init(serverId: UUID) {
        _list = StateObject(wrappedValue: MCPServersModel(fileURL: MCPEntryPoint.listFileURL(serverId: serverId)))
    }

    var body: some View {
        NavigationLink {
            MCPServersView(model: list, isGateway: true)
        } label: {
            SettingsRow(
                icon: "puzzlepiece.extension",
                title: "MCP servers",
                value: countText,
                showsChevron: true
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settingsMCPServers")
    }

    private var countText: String {
        if list.loadError != nil { return "Unavailable" }
        return "\(list.servers.count)"
    }
}

/// The row that pushes the gateway's global MCP list. Its count is read from the same list the session sheet reads.
private struct SettingsGatewayMCPLink: View {
    @StateObject private var catalog: GatewayMCPCatalogModel

    init(clientProvider: @escaping () -> GatewayClient?) {
        _catalog = StateObject(wrappedValue: GatewayMCPCatalogModel(clientProvider: clientProvider))
    }

    var body: some View {
        NavigationLink {
            GatewayMCPReadOnlyList(model: catalog)
        } label: {
            SettingsRow(
                icon: "server.rack",
                title: "Gateway servers",
                value: SettingsGatewayMCPCopy.countText(phase: catalog.phase, count: catalog.servers.count),
                showsChevron: true
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task { await catalog.load() }
        .accessibilityIdentifier("settingsGatewayMCPServers")
    }
}

/// The words the Settings gateway row and list show. The phone never changes the gateway's list (D-107).
enum SettingsGatewayMCPCopy {
    static let footer = "Managed on the gateway. A new session starts with the servers chosen for it, or the defaults. Changing a session's servers in its header applies from the next message."

    static func countText(phase: GatewayMCPCatalogModel.Phase, count: Int) -> String {
        switch phase {
        case .loaded: return "\(count)"
        case .idle, .loading: return "Loading"
        case .failed: return "Not loaded"
        case .unsupported: return "Not supported"
        }
    }
}

/// The gateway's global MCP servers, read-only. A row shows the name, the transport and the host, never a command or a header.
struct GatewayMCPReadOnlyList: View {
    @ObservedObject var model: GatewayMCPCatalogModel

    var body: some View {
        List {
            switch model.phase {
            case .loaded:
                Section {
                    if model.servers.isEmpty {
                        Text("No servers on the gateway.").foregroundStyle(.secondary)
                    }
                    ForEach(model.servers) { server in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name)
                            Text(GatewayMCPRowText.detail(server))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                } footer: {
                    Text(SettingsGatewayMCPCopy.footer)
                }
            case .idle, .loading:
                Section { ProgressView("Loading MCP servers") }
            case .failed:
                Section {
                    Text("Gateway servers could not be loaded.").foregroundStyle(.secondary)
                    Button("Try again") { Task { await model.load() } }
                        .frame(minHeight: 44)
                }
            case .unsupported:
                Section { Text(GatewayMCPCopy.unsupported).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Gateway servers")
    }
}
