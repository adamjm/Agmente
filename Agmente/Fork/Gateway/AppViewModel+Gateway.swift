import Foundation
import ACP
import ACPClient

/// Applies the gateway's `_agmente/event` notifications (D-028). A session the app has subscribed to
/// gets all of its updates and permission requests this way and no other (the gateway sends no plain
/// copy). Each event goes through the same path a plain message would: `session/update` through
/// `handleChatUpdate`, a permission request through `handlePermissionRequest`.
extension AppViewModel {
    /// `_agmente/project/state` (contract C2, D-102). The gateway sends it on the one live connection, which
    /// belongs to the selected server, so the state is recorded for that server. A state of another server
    /// (a late one from a connection being replaced) clears the held states the next time the home is configured.
    func handleGatewayProjectState(_ params: ACP.Value?) {
        guard let state = GatewayProjectState.parse(params),
              let serverId = selectedServerId,
              selectedServerViewModel?.isGatewayServer == true else { return }
        gatewayHome.applyProjectState(state, serverId: serverId)
    }

    func handleGatewayEvent(_ params: ACP.Value?) {
        guard let event = GatewayEvent.parse(params),
              let serverId = selectedServerId,
              let server = selectedServerViewModel,
              server.isGatewayServer,
              event.sessionId == sessionId else { return } // another session: opening it subscribes again

        switch server.acceptGatewayEvent(sessionId: event.sessionId, seq: event.seq) {
        case .duplicate:
            return
        case .gap:
            server.subscribeToGatewaySession(event.sessionId) // from the last event applied
            return
        case .apply:
            break
        }

        switch event.action {
        case .sessionUpdate(let updateParams):
            handleChatUpdate(updateParams)
        case .userPrompt(let updates):
            for update in updates {
                if let text = update["update"]?["content"]?["text"]?.stringValue,
                   server.consumeGatewayPromptEcho(sessionId: event.sessionId, text: text) {
                    continue // this device's own prompt, already on screen
                }
                handleChatUpdate(update)
            }
        case .permissionRequest(let request):
            sessionViewModel?.handlePermissionRequest(request)
            Task { await gatewayApprovals.refresh() }
        case .turnEnded(let stopReason, _):
            sessionViewModel?.handleStopReason(stopReason ?? "end_turn", serverId: serverId, sessionId: event.sessionId)
            if let client = server.gatewayClient {
                // Looking at the session: its finished turns are read (D-030).
                let seq = event.seq, id = event.sessionId
                Task { _ = try? await client.markRead(sessionId: id, seq: seq) }
            }
        case .approvalAnswered(let approvalId):
            sessionViewModel?.dismissPermissionRequest(id: .string(approvalId))
            gatewayApprovals.closed(approvalId: approvalId)
        case .other(let method):
            handleGatewayElicitationEvent(event, method: method, server: server) // FR-44, PLAN 6C.3
        }
    }
}


extension AppViewModel {
    /// Answers a gateway approval from the in-session card. Returns false when this is not a gateway
    /// request, and the caller sends the plain response as before.
    func answerGatewayApprovalIfNeeded(requestId: ACP.ID, optionId: String) -> Bool {
        guard let server = selectedServerViewModel, server.isGatewayServer,
              case .string(let approvalId) = requestId, approvalId.hasPrefix("agmente-perm-"),
              let client = server.gatewayClient else { return false }
        Task { @MainActor in
            do {
                try await client.answerApproval(approvalId: approvalId, optionId: optionId)
                sessionViewModel?.dismissPermissionRequest(id: requestId)
                gatewayApprovals.closed(approvalId: approvalId)
            } catch let error as GatewayError where error.isAlreadyClosed {
                sessionViewModel?.dismissPermissionRequest(id: requestId)
                gatewayApprovals.closed(approvalId: approvalId)
                sessionViewModel?.addSystemMessage("This request was already closed: \(error.message)")
            } catch {
                // The options stay on the card so the person can try again.
                sessionViewModel?.addSystemMessage("Could not send the answer: \((error as? GatewayError)?.message ?? error.localizedDescription)")
            }
        }
        return true
    }
}
