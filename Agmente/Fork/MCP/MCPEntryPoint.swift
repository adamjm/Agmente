import Foundation
import SwiftUI

/// The entry point for MCP servers (FR-40). The row is offered only for a gateway server, and it
/// opens the same list that `mcpServersForSession()` sends with session/new and session/resume.
enum MCPEntryPoint {
    /// True when the More menu should offer "MCP Servers" for the selected server.
    static func showsServersRow(isGateway: Bool) -> Bool {
        isGateway
    }

    /// The list file for one gateway server. Same path as `ServerViewModel.mcpServersForSession()`.
    static func listFileURL(serverId: UUID) -> URL {
        MCPServersModel.defaultFileURL(serverId: serverId)
    }
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
            MCPServersView(model: model)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
