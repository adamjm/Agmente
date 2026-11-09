import AppIntents
import Foundation
import ACPClient

// The session parameter of "Send to agent session". It lists the sessions of the selected gateway server only, from
// the gateway's session index (`_acpcode/sessions/index`, the same call the home screen makes). Ids are
// `<serverUUID>/<sessionId>`. Nothing here is indexed in Spotlight, and no entity holds prompt text.

/// A session on the selected gateway server, for the Shortcut's session parameter.
struct GatewaySessionEntity: AppEntity, Identifiable, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Agent session"
    static let defaultQuery = GatewaySessionQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    init(serverID: UUID, session: GatewaySession) {
        id = AgentSessionTarget(serverID: serverID, sessionId: session.sessionId).entityID
        title = session.title ?? "Untitled session"
    }

    /// The server and session this entity names, or nil for an id this build did not make.
    var target: AgentSessionTarget? { AgentSessionTarget(entityID: id) }
}

/// Lists the selected gateway's sessions. A server that is not reachable gives an empty list, not an error, so the
/// Shortcut editor still opens.
@MainActor
enum GatewaySessionCatalog {
    static func entities() async -> [GatewaySessionEntity] {
        await entities(host: ForkProcessModel.shared)
    }

    static func entities(host: AgentSessionHost) async -> [GatewaySessionEntity] {
        guard let serverID = host.selectedServerID else { return [] }
        guard let client = try? await withDeadline(AgentSessionStarter.defaultConnectDeadline, { try await host.connectSelectedGateway() }),
              let sessions = try? await client.sessions() else { return [] }
        return sessions.map { GatewaySessionEntity(serverID: serverID, session: $0) }
    }
}

struct GatewaySessionQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [GatewaySessionEntity] {
        let all = await GatewaySessionCatalog.entities()
        return all.filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [GatewaySessionEntity] {
        let all = await GatewaySessionCatalog.entities()
        return all.filter { $0.title.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [GatewaySessionEntity] {
        await GatewaySessionCatalog.entities()
    }
}
