import Foundation
import ACP

// The elicitation answer (FR-44, D-090). The gateway answers the agent only after a person's choice in
// the app. `call` is internal to this module, so the app reaches it through this method.

public extension GatewayClient {
    /// `_agmente/elicitation/answer {elicitationId, action, content?}`. `action` is `accept`, `decline` or
    /// `cancel`. `content` is sent only with `accept`; for any other action it is dropped here as well as
    /// by the gateway. Throws `GatewayError.rpc(-32001, reason)` when the elicitation was closed already.
    func sendElicitationAnswer(elicitationId: String, action: String, content: [String: ACP.Value]? = nil) async throws {
        var params: [String: ACP.Value] = ["elicitationId": .string(elicitationId), "action": .string(action)]
        if action == "accept", let content {
            params["content"] = .object(content)
        }
        _ = try await call("_agmente/elicitation/answer", .object(params))
    }
}
