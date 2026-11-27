import ACP
import ACPClient
import Foundation

/// The gateway MCP servers on a new session (D-107). Only a gateway server ever gets the MCP key; a plain ACP
/// server and Codex get exactly the `_meta` they got before.
extension ServerViewModel {
    /// The `_meta` of a session/new: the start mode (FR-34), the MCP key when a set was chosen, and the runner
    /// key when a runner other than the project's own was chosen.
    func gatewayCreateMeta(forCwd cwd: String, mcpIDs: [String]?, runner: String? = nil) async -> [String: ACP.Value] {
        let start = await gatewayStartMeta(forCwd: cwd)
        let mcp = GatewayMCPChoice.sessionNewMeta(isGateway: isGatewayServer, enabledIDs: mcpIDs)
        let runnerMeta = GatewayRunnerMeta.sessionNewMeta(isGateway: isGatewayServer, runner: runner)
        return start.merging(mcp) { _, new in new }.merging(runnerMeta) { _, new in new }
    }

    /// Remembers the set a new gateway session took. The gateway does not report a session's set, so the
    /// session header reads this record (GatewayMCPMemoryStore).
    func rememberGatewayMCPSession(_ response: ACP.AnyResponse, mcpIDs: [String]?) {
        guard isGatewayServer, let mcpIDs,
              let sessionId = response.resultValue?.objectValue?["sessionId"]?.stringValue else { return }
        GatewayMCPMemoryStore.rememberSessionIDs(mcpIDs, sessionId: sessionId)
    }
}
