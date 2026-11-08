import Foundation

/// What the send log may show. ACPClient logs every outgoing message in full, and the app's logger prints
/// it, so a message whose params carry a secret is logged by its method name only (D-105: a token is
/// never logged).
public enum ACPLogRedaction {
    /// Methods whose params hold a secret.
    public static let secretMethods: [String] = ["_acpcode/git/credentials/set"]

    /// The text to log for one outgoing message. JSON may escape the slashes of a method name, so both
    /// forms are checked.
    public static func redactedForLog(_ text: String) -> String {
        for method in secretMethods {
            let escaped = method.replacingOccurrences(of: "/", with: "\\/")
            if text.contains("\"\(method)\"") || text.contains("\"\(escaped)\"") {
                return "<\(method) message, params not logged>"
            }
        }
        return text
    }
}
