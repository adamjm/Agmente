import AppIntents
import Foundation
import ACPClient

// App Entities for the "Start agent session" Shortcut. Ids are `<serverUUID>/<gatewayId>`, so one id names one
// session on one server. No entity holds prompt text, and none is indexed in Spotlight.

extension AgentStartStatus: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Agent status"
    static let caseDisplayRepresentations: [AgentStartStatus: DisplayRepresentation] = [
        .running: "Running",
        .waitingForApproval: "Waiting for approval",
        .createdNotSent: "Created, prompt not sent",
    ]
}

/// A session a Shortcut started. The title is the project's name, because a session's own title is not known yet
/// when it starts, and the prompt is never used as a title.
struct AgentSessionEntity: AppEntity, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Agent session"
    static let defaultQuery = AgentSessionQuery()

    let id: String
    let title: String
    let status: AgentStartStatus

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    init(outcome: AgentSessionOutcome) {
        id = outcome.entityID
        title = outcome.projectName
        status = outcome.status
    }
}

/// Sessions are not stored by the app, so a reference from an earlier run does not resolve here. The entity from the
/// run itself is what a Shortcut passes to its next step.
struct AgentSessionQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [AgentSessionEntity] {
        []
    }
}

/// A project on the selected gateway, for the Shortcut's project parameter.
struct GatewayProjectEntity: AppEntity, Identifiable, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Project"
    static let defaultQuery = GatewayProjectQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(serverID: UUID, project: GatewayProject) {
        id = "\(serverID.uuidString)/\(project.id)"
        name = project.name
    }

    /// The server and project this entity names, or nil for an id this build did not make.
    var choice: AgentProjectChoice? {
        guard let slash = id.firstIndex(of: "/"),
              let serverID = UUID(uuidString: String(id[..<slash])) else { return nil }
        let projectID = String(id[id.index(after: slash)...])
        guard !projectID.isEmpty else { return nil }
        return AgentProjectChoice(serverID: serverID, projectID: projectID)
    }
}

/// Lists the selected gateway's projects. A server that is not reachable gives an empty list, not an error, so the
/// Shortcut editor still opens.
@MainActor
enum GatewayProjectCatalog {
    static func entities() async -> [GatewayProjectEntity] {
        let model = ForkProcessModel.shared
        guard let serverID = model.selectedServerID else { return [] }
        guard let client = try? await withDeadline(AgentSessionStarter.defaultConnectDeadline, { try await model.connectSelectedGateway() }),
              let projects = try? await client.projects() else { return [] }
        return projects.map { GatewayProjectEntity(serverID: serverID, project: $0) }
    }
}

struct GatewayProjectQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [GatewayProjectEntity] {
        let all = await GatewayProjectCatalog.entities()
        return all.filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [GatewayProjectEntity] {
        let all = await GatewayProjectCatalog.entities()
        return all.filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [GatewayProjectEntity] {
        await GatewayProjectCatalog.entities()
    }
}
