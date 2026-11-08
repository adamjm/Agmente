import Foundation
import ACP

// `_acpcode/sessions/stop` (D-106, SPEC 6.2). The gateway reports what a stop did; it never stops anything on its
// own. Scope `agent` ends the other sessions of the project too, so the caller asks the person first and sends
// `force` only after they agree.

/// What a stop did. An unknown value from a newer gateway decodes as `.unknown`, so the caller still shows a result.
public enum GatewayStopOutcome: Equatable, Hashable, Sendable {
    /// Nothing was running, so nothing was done.
    case notRunning
    /// Scope `turn`: the session's prompt ended as cancelled.
    case cancelled
    /// Scope `turn`: the prompt did not end in time. Nothing else was done.
    case stillRunning
    /// Scope `agent`: the project's agent was stopped.
    case stopped
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "not_running": self = .notRunning
        case "cancelled": self = .cancelled
        case "still_running": self = .stillRunning
        case "stopped": self = .stopped
        default: self = .unknown(rawValue)
        }
    }
}

/// The result of `_acpcode/sessions/stop`: the outcome and the sessions whose turns or approvals it ended.
public struct GatewayStopResult: Equatable, Sendable {
    public let outcome: GatewayStopOutcome
    public let stoppedSessions: [String]

    public init(outcome: GatewayStopOutcome, stoppedSessions: [String]) {
        self.outcome = outcome
        self.stoppedSessions = stoppedSessions
    }
}

/// The reach of a stop: one turn, or the project's whole agent.
public enum GatewayStopScope: String, Sendable {
    case turn
    case agent
}

public extension GatewayClient {
    /// `_acpcode/sessions/stop`. `force` is sent only when it is true, and it means something only for scope
    /// `.agent`. Gateway refusals come back as `GatewayError.rpc`: -32001 when other sessions run and `force` is not
    /// set, -32602 for an unknown session, -32000 when the agent's container could not be removed.
    func stopSession(sessionId: String, scope: GatewayStopScope, force: Bool = false) async throws -> GatewayStopResult {
        var params: [String: ACP.Value] = ["sessionId": .string(sessionId), "scope": .string(scope.rawValue)]
        if force { params["force"] = .bool(true) }
        let result = try await call("_acpcode/sessions/stop", .object(params))
        guard let raw = result["outcome"]?.stringValue else { throw GatewayError.invalidResponse("outcome") }
        let stopped = result["stoppedSessions"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return GatewayStopResult(outcome: GatewayStopOutcome(rawValue: raw), stoppedSessions: stopped)
    }
}
