import ACP
import Foundation

/// The `mcpServers` array for `session/new` and `session/resume` (PLAN 6B.2, FR-40, D-084).
/// Only a gateway server gets the phone's list; any other ACP server gets `[]`, as before.
enum MCPSessionServers {
    /// - Parameters:
    ///   - model: the list for the server (one file per gateway server, `MCPServersModel.defaultFileURL`).
    ///   - isGateway: the server is a gateway server (`ServerViewModel.isGatewayServer`).
    ///   - agentSupportsHTTP: the agent's `initialize` result has `mcpCapabilities.http` true.
    @MainActor
    static func payload(from model: MCPServersModel, isGateway: Bool, agentSupportsHTTP: Bool) throws -> [ACP.Value] {
        try model.mcpServersPayload(for: MCPPayloadContext(isGateway: isGateway, agentSupportsHTTP: agentSupportsHTTP))
    }
}
