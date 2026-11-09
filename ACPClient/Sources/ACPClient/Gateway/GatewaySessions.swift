import Foundation
import ACP

// Starting a session and sending a prompt through the gateway's own methods (`_acpcode/sessions/create`,
// `_acpcode/sessions/prompt`). The gateway runs `session/new` and the first prompt itself, so the answer
// comes back with a turn id. The contract is in docs/SPEC.md 6.2.

/// The answer of `_acpcode/sessions/create`: the `session/new` fields (only the id is read here) plus the turn
/// the gateway started with the prompt.
public struct GatewaySessionCreateResult: Codable, Equatable, Hashable, Sendable {
    public let sessionId: String
    public let turnId: String
    /// `accepted` when the gateway took the prompt.
    public let status: String

    public init(sessionId: String, turnId: String, status: String) {
        self.sessionId = sessionId
        self.turnId = turnId
        self.status = status
    }
}

/// The answer of `_acpcode/sessions/prompt`.
public struct GatewayPromptResult: Codable, Equatable, Hashable, Sendable {
    public let turnId: String
    public let status: String

    public init(turnId: String, status: String) {
        self.turnId = turnId
        self.status = status
    }
}

public extension GatewayError {
    /// `-32010`: the session already has a turn running, so the prompt was not sent.
    var isSessionBusy: Bool {
        if case .rpc(let code, _) = self { return code == -32010 }
        return false
    }

    /// Builds the error for a `-32015` refusal: the session was created and its prompt was not sent. Only the
    /// shape the gateway documents counts (a session id and `promptSent: false`); anything else stays a plain RPC error.
    static func promptNotSent(code: Int, message: String, data: ACP.Value) -> GatewayError? {
        guard code == -32015,
              let sessionId = data["sessionId"]?.stringValue, !sessionId.isEmpty,
              case .bool(false)? = data["promptSent"] else { return nil }
        return .sessionCreatedPromptNotSent(sessionId: sessionId, message: message)
    }
}

/// The prompt as the gateway takes it: content blocks. Only plain text is sent, which is what the app's
/// Shortcut and the phone's prompt box produce.
public enum GatewayPrompt {
    public static func text(_ text: String) -> ACP.Value {
        .array([.object(["type": .string("text"), "text": .string(text)])])
    }
}

public extension GatewayClient {
    /// `_acpcode/sessions/create`. The gateway starts `session/new` in `cwd` (a registered project's folder) and
    /// sends `prompt` as the first turn. `mcpServers` and `meta` are sent only when given.
    ///
    /// Gateway refusals come back as `GatewayError.rpc`, with the gateway's text: -32602 (not a registered
    /// project or bad params), -32012, -32000. A session that was created but whose prompt was not sent comes
    /// back as `GatewayError.sessionCreatedPromptNotSent`, carrying the session id.
    func createSession(cwd: String, prompt: String, mcpServers: [ACP.Value]? = nil, meta: [String: ACP.Value]? = nil) async throws -> GatewaySessionCreateResult {
        var params: [String: ACP.Value] = ["cwd": .string(cwd), "prompt": GatewayPrompt.text(prompt)]
        if let mcpServers { params["mcpServers"] = .array(mcpServers) }
        if let meta, !meta.isEmpty { params["_meta"] = .object(meta) }
        let result = try await call("_acpcode/sessions/create", .object(params))
        return try decode(GatewaySessionCreateResult.self, from: result, what: "session")
    }

    /// `_acpcode/sessions/prompt`. Returns when the gateway has accepted the prompt, not when the turn ends.
    /// A session that is already running a turn gives -32010 (`GatewayError.isSessionBusy`).
    func sendPrompt(sessionId: String, prompt: String) async throws -> GatewayPromptResult {
        let result = try await call("_acpcode/sessions/prompt", .object([
            "sessionId": .string(sessionId),
            "prompt": GatewayPrompt.text(prompt),
        ]))
        return try decode(GatewayPromptResult.self, from: result, what: "turn")
    }
}
