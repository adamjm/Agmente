import Foundation
import SwiftUI

/// The entry point for MCP servers (FR-40). The row is offered only for a gateway server, and it
/// opens the same list that `mcpServersForSession()` sends with session/new and session/resume.
enum MCPEntryPoint {
    /// True when the More menu should offer "MCP Servers" for the selected server.
    static func showsServersRow(isGateway: Bool) -> Bool {
        isGateway
    }

    /// What the Settings MCP section shows for the selected connection. It uses the More menu's rule.
    static func settingsMode(hasSelection: Bool, isGateway: Bool) -> MCPSettingsMode {
        guard hasSelection else { return .selectConnection }
        return showsServersRow(isGateway: isGateway) ? .servers : .hidden
    }

    /// The list file for one gateway server. Same path as `ServerViewModel.mcpServersForSession()`.
    static func listFileURL(serverId: UUID) -> URL {
        MCPServersModel.defaultFileURL(serverId: serverId)
    }
}

/// The Settings MCP section for the selected connection.
enum MCPSettingsMode: Equatable {
    /// No connection is selected, so the section asks for one first.
    case selectConnection
    /// A gateway connection: the phone's list and the gateway's global list.
    case servers
    /// A plain ACP connection has no MCP servers, so the section is not shown.
    case hidden
}

/// Sheet that shows the MCP server list for one gateway server. It owns the model for the sheet's life.
struct GatewayMCPServersSheet: View {
    @StateObject private var model: MCPServersModel
    @Environment(\.dismiss) private var dismiss

    init(serverId: UUID) {
        _model = StateObject(wrappedValue: MCPServersModel(fileURL: MCPEntryPoint.listFileURL(serverId: serverId)))
    }

    var body: some View {
        NavigationStack {
            MCPServersView(model: model, isGateway: true)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
