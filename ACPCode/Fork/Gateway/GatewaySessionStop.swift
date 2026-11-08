import Foundation
import ACPClient

// Stopping a gateway session (D-106): the rules (what an agent stop would end, when `force` may be sent, the copy)
// and the calls the UI makes. The agent scope is sent only after the person has seen the sessions it would end.

/// A session that another stop would end: running, or waiting for an approval, in the same project.
struct GatewayStopCandidate: Equatable, Identifiable, Sendable {
    let sessionId: String
    let title: String
    let status: GatewaySessionStatus

    var id: String { sessionId }
}

/// What the agent-scope confirmation decides: send the stop (with `force` only when the person was shown other
/// sessions), or show the list again because sessions started since.
enum AgentStopDecision: Equatable {
    case send(force: Bool)
    case listChanged([GatewayStopCandidate])
}

enum GatewayStopRules {
    /// The stalled badge shows when the gateway flags the session (D-106). The gateway flags only a running turn.
    static func showsStalledBadge(_ session: GatewaySession) -> Bool { session.isStalled }

    /// A turn can be stopped while it runs or waits for an approval.
    static func canStopTurn(_ status: GatewaySessionStatus) -> Bool {
        status == .running || status == .awaitingApproval
    }

    /// The other sessions of the project that an agent stop would end: running or waiting for an approval.
    static func otherBusySessions(in sessions: [GatewaySession], projectId: String, except sessionId: String) -> [GatewayStopCandidate] {
        sessions
            .filter { $0.projectId == projectId && $0.sessionId != sessionId && canStopTurn($0.status) }
            .sorted { $0.sessionId < $1.sessionId }
            .map { GatewayStopCandidate(sessionId: $0.sessionId, title: $0.title ?? "New Chat", status: $0.status) }
    }

    /// The decision for an agent stop after the person confirmed. `shown` is the list they confirmed, and `now` is
    /// the list read just before sending. A session in `now` that was not shown sends the caller back to the person.
    /// `force` is set only when other sessions were shown, so the gateway does not refuse a stop the person agreed to.
    static func confirmation(shown: [GatewayStopCandidate], now: [GatewayStopCandidate]) -> AgentStopDecision {
        let shownIds = Set(shown.map(\.sessionId))
        if now.contains(where: { !shownIds.contains($0.sessionId) }) { return .listChanged(now) }
        return .send(force: !shown.isEmpty)
    }
}

/// The words for the stop actions. Short, and the same wherever the action appears.
enum GatewayStopCopy {
    static let stopTitle = "Stop session"
    static let stopAgentTitle = "Stop agent"
    static let stopAgentQuestion = "Stop the agent for this project?"
    static let stopAgentButton = "Stop Agent"
    static let stalledTitle = "Stalled"
    static let stalledMessage = "No activity for a while. You can stop this session."
    static let notOnGateway = "This session is not on the gateway."
    static let notConnected = "Not connected to the gateway."
    static let otherSessionsChanged = "Other sessions started running. Nothing was stopped. Try again."

    static func turnMessage(_ outcome: GatewayStopOutcome) -> String {
        switch outcome {
        case .cancelled, .stopped: return "Stopped."
        case .notRunning: return "Nothing was running."
        case .stillRunning: return "The session did not stop."
        case .unknown: return "Request sent."
        }
    }

    static func agentMessage(_ result: GatewayStopResult) -> String {
        switch result.outcome {
        case .stopped:
            let count = result.stoppedSessions.count
            if count == 0 { return "Agent stopped." }
            return count == 1 ? "Agent stopped. 1 session ended." : "Agent stopped. \(count) sessions ended."
        case .notRunning: return "The agent was not running."
        default: return "Request sent."
        }
    }

    /// The text of the agent-scope confirmation: who else will stop.
    static func agentStopMessage(_ candidates: [GatewayStopCandidate]) -> String {
        guard !candidates.isEmpty else { return "This stops the project's agent. Nothing else is running." }
        let lines = candidates.map { candidate -> String in
            let state = candidate.status == .awaitingApproval ? "waiting for approval" : "running"
            return "\(candidate.title) (\(state))"
        }
        return "These sessions will also stop:\n" + lines.joined(separator: "\n")
    }
}

/// The calls the stop actions make. Nothing here stops an agent without the caller having shown the candidates.
enum GatewaySessionStop {
    /// Stops the session's running turn (scope turn). `force` is never sent.
    static func stopTurn(_ client: GatewayClient, sessionId: String) async throws -> GatewayStopResult {
        try await client.stopSession(sessionId: sessionId, scope: .turn)
    }

    /// The sessions an agent stop would end, read from the index. It stops nothing.
    static func agentStopCandidates(_ client: GatewayClient, sessionId: String, projectId: String) async throws -> [GatewayStopCandidate] {
        let sessions = try await client.sessions(projectId: projectId)
        return GatewayStopRules.otherBusySessions(in: sessions, projectId: projectId, except: sessionId)
    }

    enum AgentStopOutcome: Equatable {
        case done(GatewayStopResult)
        case listChanged([GatewayStopCandidate])
    }

    /// Runs the agent stop the person confirmed. It re-reads the running sessions first (see `GatewayStopRules.confirmation`).
    static func confirmAgentStop(_ client: GatewayClient, sessionId: String, projectId: String, shown: [GatewayStopCandidate]) async throws -> AgentStopOutcome {
        let now = try await agentStopCandidates(client, sessionId: sessionId, projectId: projectId)
        switch GatewayStopRules.confirmation(shown: shown, now: now) {
        case .listChanged(let list):
            return .listChanged(list)
        case .send(let force):
            return .done(try await client.stopSession(sessionId: sessionId, scope: .agent, force: force))
        }
    }
}
