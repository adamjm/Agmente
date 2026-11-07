import Foundation
import ACP

// `_agmente/project/state {projectId, agent, since}` (contract C2, D-102): the agent state of one project.
// The gateway sends it only when the state changes, and only to the sockets that listed the project. It is
// not in the event log, and nothing is sent when a socket starts listing: a project's state is unknown until
// its first change after that.

/// The agent state of a project, as the gateway reports it.
public enum GatewayAgentState: Equatable, Sendable {
    case stopped
    case starting
    case running
    case stopping
    /// A value this app does not know. It is never shown, and it clears a shown state.
    case unknown

    /// Reads the wire value. Anything other than the four known names is `.unknown`.
    public init(wire: String?) {
        switch wire {
        case "stopped": self = .stopped
        case "starting": self = .starting
        case "running": self = .running
        case "stopping": self = .stopping
        default: self = .unknown
        }
    }
}

/// One `_agmente/project/state` notification.
public struct GatewayProjectState: Equatable, Sendable {
    public static let method = "_agmente/project/state"

    public let projectId: String
    public let agent: GatewayAgentState
    /// When the gateway saw the transition. Nil when the value is missing or not an RFC 3339 time.
    public let since: Date?

    public init(projectId: String, agent: GatewayAgentState, since: Date? = nil) {
        self.projectId = projectId
        self.agent = agent
        self.since = since
    }

    /// Reads the params of the notification. Nil only when there is no project id; an unknown or missing
    /// `agent` decodes to `.unknown`, so a newer gateway never breaks the home screen.
    public static func parse(_ params: ACP.Value?) -> GatewayProjectState? {
        guard let object = params?.objectValue,
              let projectId = object["projectId"]?.stringValue, !projectId.isEmpty else { return nil }
        let agent = GatewayAgentState(wire: object["agent"]?.stringValue)
        let since = object["since"]?.stringValue.flatMap(parseStamp)
        return GatewayProjectState(projectId: projectId, agent: agent, since: since)
    }

    private static func parseStamp(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}
