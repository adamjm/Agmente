import Foundation
import ACP

// Types for the gateway's `_acpcode/*` methods (docs/SPEC.md 6.2, DECISIONS D-024 to D-037).

public struct GatewayProject: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let path: String
    public let defaultMode: String?

    public init(id: String, name: String, path: String, defaultMode: String? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.defaultMode = defaultMode
    }
}

/// A session's status in the gateway's index (D-030). An unknown value from a newer gateway decodes
/// as `.unknown`, so the list still shows.
public enum GatewaySessionStatus: Equatable, Hashable, Sendable {
    case idle
    case running
    case awaitingApproval
    case error
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .idle: return "idle"
        case .running: return "running"
        case .awaitingApproval: return "awaiting_approval"
        case .error: return "error"
        case .unknown(let value): return value
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "idle": self = .idle
        case "running": self = .running
        case "awaiting_approval": self = .awaitingApproval
        case "error": self = .error
        default: self = .unknown(rawValue)
        }
    }
}

extension GatewaySessionStatus: Codable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct GatewaySession: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let sessionId: String
    public let projectId: String
    public let title: String?
    public let status: GatewaySessionStatus
    /// ISO 8601 UTC with milliseconds.
    public let lastActivity: String
    public let headSeq: Int
    public let unread: Int
    /// The gateway flags a running turn that has had no event for a long time, with no approval open (D-106). It
    /// changes nothing by itself. Nil when an older gateway does not send the field.
    public let stalled: Bool?

    public var id: String { sessionId }

    /// True when the gateway flags this session as stalled (D-106).
    public var isStalled: Bool { stalled == true }

    public init(sessionId: String, projectId: String, title: String?, status: GatewaySessionStatus, lastActivity: String, headSeq: Int, unread: Int, stalled: Bool? = nil) {
        self.sessionId = sessionId
        self.projectId = projectId
        self.title = title
        self.status = status
        self.lastActivity = lastActivity
        self.headSeq = headSeq
        self.unread = unread
        self.stalled = stalled
    }

    /// `lastActivity` as a date, or nil when it is not in the gateway's format.
    public var lastActivityDate: Date? { GatewayDates.parse(lastActivity) }
}

enum GatewayDates {
    static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

public extension ACP.Value {
    /// Decodes this JSON value as `T`.
    func decoded<T: Decodable>(as type: T.Type = T.self) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
