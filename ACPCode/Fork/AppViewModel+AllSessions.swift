import Foundation

// D-113: gathers the drawer's all-sessions inputs from what the app already holds. It never connects to a
// server that is not selected, and it changes no connection behaviour.
extension AppViewModel {
    /// One input per connection. The agent name is known only where this run has initialized the connection.
    func allSessionsInputs() -> [AllSessionsServerInput] {
        servers.enumerated().map { position, server in
            let isSelected = server.id == selectedServerId
            // The selected gateway lists its sessions under their projects, so they are not repeated here.
            let listedInGatewayHome = isSelected && selectedServerIsGatewayHome
            return AllSessionsServerInput(
                serverId: server.id,
                serverName: server.name,
                agentName: serverViewModels[server.id]?.agentInfo?.name,
                isCodex: server.serverType == .codexAppServer,
                isSelected: isSelected,
                sessions: listedInGatewayHome ? [] : cachedSessionSummaries(forServerId: server.id),
                isConnected: isServerConnected(server.id),
                colourPosition: position
            )
        }
    }

    /// Whether a connection is open now. Only the selected connection is open; the others were closed when the
    /// app switched away from them (D-113).
    func isServerConnected(_ serverId: UUID) -> Bool {
        if serverId == selectedServerId {
            return connectionState == .connected
        }
        return serverViewModels[serverId]?.connectionState == .connected
    }

    /// The colour index of a connection, from its place in the connection list (`ServerColour`).
    func serverColourIndex(_ serverId: UUID) -> Int {
        let position = servers.firstIndex { $0.id == serverId } ?? 0
        return ServerColour.paletteIndex(position: position)
    }

    /// The rows for the drawer, newest first, filtered by the search text.
    func allSessionRows(query: String) -> [AllSessionRow] {
        AllSessionsList.rows(from: allSessionsInputs(), query: query)
    }
}
