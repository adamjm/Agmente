import ACP
import Foundation

/// The call-site helper for the three `mcpServers` arguments in `ServerViewModel` (PLAN 6B.2).
extension ServerViewModel {
    /// The MCP list for this server's `session/new` or `session/resume`. A failure keeps the session
    /// going with no servers, and says so in the transcript; no partial list is ever sent.
    func mcpServersForSession() -> [ACP.Value] {
        guard isGatewayServer else { return [] }
        do {
            let model = MCPServersModel(fileURL: MCPServersModel.defaultFileURL(serverId: id))
            return try MCPSessionServers.payload(
                from: model,
                isGateway: true,
                agentSupportsHTTP: agentInfo?.capabilities.mcpHTTP ?? false
            )
        } catch {
            appendClosure("MCP servers not sent: \(error.localizedDescription)")
            return []
        }
    }
}
