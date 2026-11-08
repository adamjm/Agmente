import Foundation

/// The two answers the Live Activity offers. Only the island's Once and Deny exist as roles.
public enum ApprovalOptionRole: Equatable, Sendable {
    /// `allow_once`: the agent runs the tool this one time.
    case once
    /// `reject_once`: the agent does not run the tool.
    case deny
}

/// Maps an ACP permission option kind to an island role, by kind and never by the agent's label.
/// `allow_always` and `reject_always` have no role: a standing rule is set in the app only, never on the
/// Dynamic Island or the Lock Screen.
public enum ApprovalOptionMapping {
    public static func role(forKind kind: String) -> ApprovalOptionRole? {
        switch kind {
        case "allow_once":
            return .once
        case "reject_once":
            return .deny
        default:
            return nil
        }
    }
}
