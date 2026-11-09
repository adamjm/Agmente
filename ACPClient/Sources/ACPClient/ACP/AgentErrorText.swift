import Foundation

/// What a person reads when the agent refuses a request (FR-35, T-35).
///
/// Bob answers `session/new` without credentials with JSON-RPC error `-32000` "Authentication
/// required" (RESULTS 2026-11-05). That gets its own text, because the fix is on the gateway host,
/// not in the app. Other errors keep their own text.
public enum ACPAgentErrorText {
    public static let authenticationRequired = "Bob needs authentication. Set BOB_API_KEY on the gateway host."

    public static func isAuthenticationRequired(code: Int, message: String) -> Bool {
        code == -32000 && message.localizedCaseInsensitiveContains("Authentication required")
    }

    /// The text to show for an error from an ACP or gateway call.
    public static func text(for error: Error) -> String {
        switch error {
        case let ACPServiceError.rpc(_, rpc), let ACPServiceError.rpcData(_, rpc, _):
            if isAuthenticationRequired(code: rpc.code, message: rpc.message) { return authenticationRequired }
            return rpc.message
        case let GatewayError.rpc(code, message):
            if isAuthenticationRequired(code: code, message: message) { return authenticationRequired }
            return message
        case let error as GatewayError:
            return error.message
        default:
            return error.localizedDescription
        }
    }
}
