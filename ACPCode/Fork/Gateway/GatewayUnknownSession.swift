import Foundation
import ACPClient

// A phone record the gateway does not know (design section 4, D-106). The app first loads the session on the agent
// again, with its stored cwd. Only when that fails does it offer removal from this phone. It never calls
// `session/delete`: the session may still exist on the agent.

/// What the app needs to re-attach a record or remove it from this phone. There is no delete on the agent here.
@MainActor
protocol GatewayRecordAccess {
    /// `session/load` for the stored cwd, through the gateway, which routes an unknown session by its cwd.
    func loadSession(sessionId: String, cwd: String) async throws
    /// Removes the record and its chat from this phone. Neither the gateway nor the agent is called.
    func removeFromPhone(sessionId: String)
}

enum GatewayUnknownSession {
    /// The gateway answers an unknown session with -32602 (subscribe and stop). The app sends valid parameters, so
    /// -32602 means unknown here. The SDK does not keep the JSON-RPC `data.reason`, so the code is the signal.
    static func isUnknown(_ error: Error) -> Bool {
        guard let gateway = error as? GatewayError, case .rpc(let code, _) = gateway else { return false }
        return code == -32602
    }

    enum Outcome: Equatable {
        case reattached
        case offerRemoval
    }

    /// Tries `session/load` first. Removal is offered when there is no cwd to load in, or when the load fails.
    @MainActor
    static func resolve(sessionId: String, cwd: String?, access: GatewayRecordAccess) async -> Outcome {
        guard let cwd, !cwd.isEmpty else { return .offerRemoval }
        do {
            try await access.loadSession(sessionId: sessionId, cwd: cwd)
            return .reattached
        } catch {
            return .offerRemoval
        }
    }
}

/// The words for removing a phone record. Shared by every confirmation that removes one.
enum GatewayRemovalCopy {
    static let title = "Remove from this phone?"
    static let message = "The chat history for this session on this phone will be deleted. This cannot be undone. The gateway and Bob are not changed."
    static let button = "Remove from Phone"
}

/// The phone's records that the gateway does not list. Pure: the caller reads both lists.
enum GatewayOrphanSessions {
    static func find(local: [StoredSessionInfo], gatewayIds: Set<String>, pending: Set<String> = []) -> [StoredSessionInfo] {
        local
            .filter { !$0.sessionId.isEmpty && !gatewayIds.contains($0.sessionId) && !pending.contains($0.sessionId) }
            .sorted { lhs, rhs in
                let l = lhs.updatedAt ?? .distantPast
                let r = rhs.updatedAt ?? .distantPast
                if l != r { return l > r }
                return lhs.sessionId < rhs.sessionId
            }
    }
}
