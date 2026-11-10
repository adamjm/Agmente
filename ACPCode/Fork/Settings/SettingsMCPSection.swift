import SwiftUI

/// The MCP servers part of Settings. It links to the same `MCPServersView` the gateway sheet shows, pushed
/// here rather than in its own sheet, so no navigation stack is nested in another.
struct SettingsMCPSection: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionLabel("MCP servers")
            SettingsCard {
                if let serverId = model.selectedServerId {
                    SettingsMCPServersLink(serverId: serverId)
                        .id(serverId)
                } else {
                    SettingsRow(icon: "puzzlepiece.extension", title: "Select a connection first", titleColor: .secondary)
                        .accessibilityIdentifier("settingsMCPSelectConnectionFirst")
                }
            }
        }
    }
}

/// The row that pushes the MCP server list for one connection. The count is the number of saved entries.
private struct SettingsMCPServersLink: View {
    @StateObject private var list: MCPServersModel

    init(serverId: UUID) {
        _list = StateObject(wrappedValue: MCPServersModel(fileURL: MCPEntryPoint.listFileURL(serverId: serverId)))
    }

    var body: some View {
        NavigationLink {
            MCPServersView(model: list)
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
