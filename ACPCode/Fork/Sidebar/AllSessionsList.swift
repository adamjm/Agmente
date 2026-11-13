import ACPClient
import Foundation

// D-113: the drawer's all-sessions list. Pure rules, no view and no connection: the caller passes what the app
// already holds for each connection, and gets one flat list of rows, newest first.

/// One connection's sessions, as the app holds them. `isSelected` marks the connection that is open now.
struct AllSessionsServerInput: Equatable {
    let serverId: UUID
    let serverName: String
    /// The agent's name from its `initialize` response, when this run has connected to it. Nil otherwise.
    let agentName: String?
    let isCodex: Bool
    let isSelected: Bool
    let sessions: [SessionSummary]
    /// True while the connection is open. Its sessions then show a green dot.
    var isConnected: Bool = false
    /// The connection's place in the list, for `ServerColour`.
    var colourPosition: Int = 0
}

struct AllSessionRow: Equatable, Identifiable {
    let serverId: UUID
    let sessionId: String
    let title: String
    let date: Date?
    /// The connection's name, shown as the row's second line.
    let connectionName: String
    let agentName: String?
    let builder: AgentBuilder
    let isSelectedServer: Bool
    /// True while the connection is open.
    var isConnected: Bool = false
    /// The connection's colour index (`ServerColour.color(index:)`).
    var colourIndex: Int = 0

    /// `serverId/sessionId`. The same session id on two connections gives two rows with two ids.
    var id: String { AllSessionRow.key(serverId: serverId, sessionId: sessionId) }

    var accessibilityIdentifier: String { "allSessionRow_\(serverId.uuidString)_\(sessionId)" }

    static func key(serverId: UUID, sessionId: String) -> String {
        "\(serverId.uuidString)/\(sessionId)"
    }
}

enum AllSessionsList {
    static let untitledTitle = "New Chat"

    /// Rows from every connection, newest first. A session with no date goes last, in the order it came.
    /// A non-empty `query` keeps rows whose title or session id contains it, ignoring case.
    static func rows(from servers: [AllSessionsServerInput], query: String = "") -> [AllSessionRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var numbered: [(order: Int, row: AllSessionRow)] = []

        for server in servers {
            let connectionName = displayConnectionName(server.serverName)
            let builder = AgentBuilder.detect(agentName: server.agentName, serverName: server.serverName, isCodex: server.isCodex)
            for session in server.sessions {
                let title = displayTitle(session.title)
                if !needle.isEmpty,
                   !title.lowercased().contains(needle),
                   !session.id.lowercased().contains(needle) {
                    continue
                }
                let row = AllSessionRow(
                    serverId: server.serverId,
                    sessionId: session.id,
                    title: title,
                    date: session.updatedAt,
                    connectionName: connectionName,
                    agentName: server.agentName,
                    builder: builder,
                    isSelectedServer: server.isSelected,
                    isConnected: server.isConnected,
                    colourIndex: ServerColour.paletteIndex(position: server.colourPosition)
                )
                numbered.append((numbered.count, row))
            }
        }

        return numbered.sorted { lhs, rhs in
            switch (lhs.row.date, rhs.row.date) {
            case let (left?, right?):
                if left != right { return left > right }
                return lhs.order < rhs.order
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.order < rhs.order
            }
        }
        .map(\.row)
    }

    static func displayTitle(_ title: String?) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? untitledTitle : trimmed
    }

    private static func displayConnectionName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Connection" : trimmed
    }
}
