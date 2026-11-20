import ACP
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

    /// The longest `error.data.details` text shown after the message, in characters.
    public static let detailsLimit = 300

    /// The text to show for an error from an ACP or gateway call.
    public static func text(for error: Error) -> String {
        switch error {
        case let ACPServiceError.rpc(_, rpc):
            if isAuthenticationRequired(code: rpc.code, message: rpc.message) { return authenticationRequired }
            return rpc.message
        case let ACPServiceError.rpcData(_, rpc, data):
            if isAuthenticationRequired(code: rpc.code, message: rpc.message) { return authenticationRequired }
            return withDetails(rpc.message, data: data)
        case let GatewayError.rpc(code, message):
            if isAuthenticationRequired(code: code, message: message) { return authenticationRequired }
            return message
        case let error as GatewayError:
            return error.message
        default:
            return error.localizedDescription
        }
    }

    /// The message, then `data.details` after a colon when that is a non-empty string. The gateway
    /// passes an agent's error object through unchanged, so the cause of a generic "Internal error"
    /// is in `details`. Without a usable `details`, the message alone is returned.
    static func withDetails(_ message: String, data: ACP.Value) -> String {
        guard let raw = data.objectValue?["details"]?.stringValue else { return message }
        let details = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !details.isEmpty else { return message }
        let shown = clipped(details)
        return message.isEmpty ? shown : "\(message): \(shown)"
    }

    /// The first `detailsLimit` characters, then an ellipsis when anything was cut.
    static func clipped(_ text: String) -> String {
        guard text.count > detailsLimit else { return text }
        return String(text.prefix(detailsLimit)) + "…"
    }
}
