import Foundation

// D-113: gathers the drawer's all-sessions inputs from what the app already holds. It never connects to a
// server that is not selected, and it changes no connection behaviour.
extension AppViewModel {
    /// One input per connection. The agent name is known only where this run has initialized the connection.
    func allSessionsInputs() -> [AllSessionsServerInput] {
        servers.map { server in
            let isSelected = server.id == selectedServerId
            // The selected gateway lists its sessions under their projects, so they are not repeated here.
            let listedInGatewayHome = isSelected && selectedServerIsGatewayHome
            return AllSessionsServerInput(
                serverId: server.id,
                serverName: server.name,
                agentName: serverViewModels[server.id]?.agentInfo?.name,
                isCodex: server.serverType == .codexAppServer,
                isSelected: isSelected,
                sessions: listedInGatewayHome ? [] : cachedSessionSummaries(forServerId: server.id)
            )
        }
    }

    /// The rows for the drawer, newest first, filtered by the search text.
    func allSessionRows(query: String) -> [AllSessionRow] {
        AllSessionsList.rows(from: allSessionsInputs(), query: query)
    }
}
