import Foundation
import ACPClient

// The logic behind the "Send to agent session" Shortcut (app process only). It sends one prompt to a session that
// already exists on the selected gateway server. It refuses a session it cannot place on that server, before any
// request. It never selects a server, never changes the session on screen, and never navigates. A send is made once:
// after the prompt may have reached the gateway, a failure is reported, never retried, because a retry could send the
// prompt twice. The prompt text is never put in a notification, a dialog, a log line or an index.

/// Why a send stopped before any prompt was sent. Each case has the text the person sees (the intent throws it).
enum SendToSessionError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    /// The entity id is not `<serverUUID>/<sessionId>`.
    case malformedSession
    /// The session belongs to a server other than the selected one.
    case otherServer
    /// The gateway's session index does not list the session.
    case notListed

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .malformedSession: return "Choose a session from the list."
        case .otherServer: return "That session is on another server. Select that server in ACP Code first."
        case .notListed: return "That session is not on your Mac's gateway. It may have been deleted."
        }
    }
}

/// A session on a gateway server, named by the entity id `<serverUUID>/<sessionId>`. Ids are unique across servers.
struct AgentSessionTarget: Equatable, Sendable {
    let serverID: UUID
    let sessionId: String

    init(serverID: UUID, sessionId: String) {
        self.serverID = serverID
        self.sessionId = sessionId
    }

    /// Parses `<serverUUID>/<sessionId>`. Nil for an id this build did not make.
    init?(entityID: String) {
        guard let slash = entityID.firstIndex(of: "/"),
              let serverID = UUID(uuidString: String(entityID[..<slash])) else { return nil }
        let sessionId = String(entityID[entityID.index(after: slash)...])
        guard !sessionId.isEmpty else { return nil }
        self.init(serverID: serverID, sessionId: sessionId)
    }

    var entityID: String { "\(serverID.uuidString)/\(sessionId)" }
}

/// What a send produced once the request was made. `accepted` and `busy` are the gateway's own answers. `failed`
/// means the request failed after it was sent, so the prompt may or may not have been taken.
enum AgentSendStatus: String, CaseIterable, Equatable, Sendable {
    case accepted
    case busy
    case failed
}

struct AgentSendOutcome: Equatable, Sendable {
    let serverID: UUID
    let sessionId: String
    /// The turn the gateway started, when it answered `accepted`.
    let turnId: String?
    let status: AgentSendStatus
    /// For `failed`, the gateway's own text or a fixed text. Never the prompt. Nil otherwise.
    let detail: String?

    var entityID: String { AgentSessionTarget(serverID: serverID, sessionId: sessionId).entityID }
}

/// Sends a prompt to one existing session. The host is the same one the start uses (`AgentSessionHost`), so the
/// connect is the same as in `AgentSessionStarter`: the connect has a deadline and the selection is never changed.
@MainActor
final class AgentSessionSender {
    private let host: AgentSessionHost
    private let connectDeadline: Duration

    init(host: AgentSessionHost, connectDeadline: Duration = AgentSessionStarter.defaultConnectDeadline) {
        self.host = host
        self.connectDeadline = connectDeadline
    }

    /// Sends `prompt` to `target`. Refusals throw before any request is sent to the session. Once the send has been
    /// made, the result is returned, never thrown: busy and failed are outcomes, with a status.
    func send(prompt: String, to target: AgentSessionTarget) async throws -> AgentSendOutcome {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AgentSessionError.emptyPrompt }
        guard text.utf8.count <= AgentSessionStarter.maxPromptBytes else { throw AgentSessionError.promptTooLong }

        guard let selected = host.selectedServerID else { throw AgentSessionError.noServer }
        guard target.serverID == selected else { throw SendToSessionError.otherServer }

        let client: GatewayClient
        do {
            client = try await withDeadline(connectDeadline) { [host] in
                try await host.connectSelectedGateway()
            }
        } catch {
            throw AgentSessionStarter.translate(error)
        }
        // The selection can move while connecting. The send stays on the server it started on, or stops.
        guard host.selectedServerID == selected else { throw SendToSessionError.otherServer }

        let sessions: [GatewaySession]
        do {
            sessions = try await client.sessions()
        } catch {
            throw AgentSessionStarter.translate(error)
        }
        guard sessions.contains(where: { $0.sessionId == target.sessionId }) else { throw SendToSessionError.notListed }

        // One request, no retry (see the file comment).
        do {
            let answer = try await client.sendPrompt(sessionId: target.sessionId, prompt: text)
            return AgentSendOutcome(serverID: selected, sessionId: target.sessionId, turnId: answer.turnId,
                                    status: .accepted, detail: nil)
        } catch let error as GatewayError where error.isSessionBusy {
            return AgentSendOutcome(serverID: selected, sessionId: target.sessionId, turnId: nil,
                                    status: .busy, detail: nil)
        } catch {
            return AgentSendOutcome(serverID: selected, sessionId: target.sessionId, turnId: nil,
                                    status: .failed, detail: Self.failureText(error))
        }
    }

    /// The text for a failed send. A lost connection is named as such; any other gateway text is the gateway's own.
    static func failureText(_ error: Error) -> String {
        if let gateway = error as? GatewayError {
            if case .disconnected = gateway { return "Can't reach your Mac. Check that it is awake and connected." }
            return gateway.message
        }
        return "The request failed."
    }
}
