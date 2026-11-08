import Foundation
import ACP

// Types for the connector's pairing and grant methods (contract C5, DECISIONS D-095, D-097).
// A pairing is a client's request to connect; its six-digit code is shown on the client's page and
// on the phone, and the person approves only when the two match. A grant is what an approved pairing
// became: a client that may use the gateway within a scope.

public struct GatewayConnectorPairing: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let pairingId: String
    /// Six digits, as the client's page shows them.
    public let code: String
    public let clientName: String
    /// ISO 8601 UTC from the gateway.
    public let requestedAt: String
    public let expiresAt: String

    public var id: String { pairingId }

    public init(pairingId: String, code: String, clientName: String, requestedAt: String, expiresAt: String) {
        self.pairingId = pairingId
        self.code = code
        self.clientName = clientName
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
    }

    public var expiresDate: Date? { GatewayConnectorDates.parse(expiresAt) }
    public var requestedDate: Date? { GatewayConnectorDates.parse(requestedAt) }
}

/// What a grant may use (contract C5). `projects` is either every project (`"all"`) or a list of project
/// ids. `sessions` absent means every session in the listed projects; a list narrows it to those sessions.
public struct GatewayConnectorScope: Codable, Equatable, Hashable, Sendable {
    public enum Projects: Equatable, Hashable, Sendable {
        case all
        case some([String])
    }

    public let projects: Projects
    public let sessions: [String]?

    public init(projects: Projects, sessions: [String]?) {
        self.projects = projects
        self.sessions = sessions
    }

    /// Any project and any session on this gateway.
    public static let allProjects = GatewayConnectorScope(projects: .all, sessions: nil)

    /// The test scope: exactly one project (the session's own) and exactly one session.
    public static func oneSession(_ session: GatewaySession) -> GatewayConnectorScope {
        GatewayConnectorScope(projects: .some([session.projectId]), sessions: [session.sessionId])
    }

    /// The scope as the `scope` parameter of `_acpcode/connector/approve`.
    public var value: ACP.Value {
        var object: [String: ACP.Value] = [:]
        switch projects {
        case .all: object["projects"] = .string("all")
        case .some(let ids): object["projects"] = .array(ids.map { .string($0) })
        }
        if let sessions { object["sessions"] = .array(sessions.map { .string($0) }) }
        return .object(object)
    }

    /// A short line for a grant: "All projects", "1 project · 1 session".
    public var summary: String {
        let projectsText: String
        switch projects {
        case .all: projectsText = "All projects"
        case .some(let ids): projectsText = ids.count == 1 ? "1 project" : "\(ids.count) projects"
        }
        guard let sessions else { return projectsText }
        return projectsText + " · " + (sessions.count == 1 ? "1 session" : "\(sessions.count) sessions")
    }

    private enum CodingKeys: String, CodingKey {
        case projects, sessions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let word = try? container.decode(String.self, forKey: .projects) {
            guard word == "all" else {
                throw DecodingError.dataCorruptedError(forKey: .projects, in: container, debugDescription: "projects must be \"all\" or a list")
            }
            projects = .all
        } else {
            projects = .some(try container.decode([String].self, forKey: .projects))
        }
        sessions = try container.decodeIfPresent([String].self, forKey: .sessions)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch projects {
        case .all: try container.encode("all", forKey: .projects)
        case .some(let ids): try container.encode(ids, forKey: .projects)
        }
        try container.encodeIfPresent(sessions, forKey: .sessions)
    }
}

public struct GatewayConnectorGrant: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let grantId: String
    /// The name the client gave itself when it paired.
    public let label: String
    public let scope: GatewayConnectorScope
    /// ISO 8601 UTC from the gateway.
    public let createdAt: String
    public let lastUsedAt: String?

    public var id: String { grantId }

    public init(grantId: String, label: String, scope: GatewayConnectorScope, createdAt: String, lastUsedAt: String? = nil) {
        self.grantId = grantId
        self.label = label
        self.scope = scope
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    public var lastUsedDate: Date? { lastUsedAt.flatMap(GatewayConnectorDates.parse) }
}

enum GatewayConnectorDates {
    /// The gateway's millisecond format first, then a plain RFC 3339 time.
    static func parse(_ text: String) -> Date? {
        GatewayDates.parse(text) ?? ISO8601DateFormatter().date(from: text)
    }
}
