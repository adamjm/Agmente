import Foundation
import ACP

// `_acpcode/sessions/delete` (SPEC 6.2). The gateway removes the session, its events and its read markers, so it
// leaves the index of every device. It also asks the agent to delete the session when the agent has it open.

/// The result of `_acpcode/sessions/delete`.
public struct GatewayDeleteResult: Equatable, Sendable {
    /// The gateway no longer lists the session.
    public let deleted: Bool
    /// The agent also accepted `session/delete`. False is normal: the agent may not have the session open or
    /// may not support the method. The session is gone from the gateway either way.
    public let agentDeleted: Bool

    public init(deleted: Bool, agentDeleted: Bool) {
        self.deleted = deleted
        self.agentDeleted = agentDeleted
    }
}

public extension GatewayClient {
    /// `_acpcode/sessions/delete`. Gateway refusals come back as `GatewayError.rpc`: -32001 while the session has a
    /// turn running or an approval open, -32602 for a session the gateway does not know, -32601 from a gateway that
    /// predates the method.
    func deleteSession(sessionId: String) async throws -> GatewayDeleteResult {
        let result = try await call("_acpcode/sessions/delete", .object(["sessionId": .string(sessionId)]))
        guard let deleted = result["deleted"]?.boolValue else { throw GatewayError.invalidResponse("deleted") }
        return GatewayDeleteResult(deleted: deleted, agentDeleted: result["agent"]?.boolValue ?? false)
    }
}
