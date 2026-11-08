import Foundation
import ACPClient

// Pure rules for Git at project creation and git credentials (D-105). No view or network code here, so
// the tests run them on plain values. The gateway checks every value again, in the same order; these
// rules say what is wrong before anything is sent, and the gateway's text is what the person sees when
// they disagree.

/// The remote URL typed in the New Project sheet. https only (D-105).
enum GatewayGitRemoteRules {
    static let maxLength = 2048
    private static let scheme = "https://"

    /// The first rule the URL breaks, as text for the person. Nil when the URL is empty (no remote) or valid.
    /// `allowedHosts` is the gateway's allow-list when it reports one. The gateway reports none today, so the
    /// app passes nil: the shape is checked here and the host is left to the gateway's refusal.
    static func problem(with raw: String, allowedHosts: [String]? = nil) -> String? {
        if raw.isEmpty { return nil }
        if raw.utf8.count > maxLength { return "Use at most 2048 characters." }
        if raw.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value >= 0x7f }) {
            return "The URL has spaces or characters that are not allowed. Check it and try again."
        }
        guard raw.hasPrefix(scheme) else { return "Use https:// for the remote." }
        let (authority, path) = split(raw)
        if authority.contains("@") { return "Remove the user name and password from the URL. Choose a credential instead." }
        if authority.contains(":") { return "Remove the port from the URL." }
        if raw.contains("?") || raw.contains("#") { return "Remove the query or fragment from the URL." }
        let host = authority.lowercased()
        if host.isEmpty || !host.unicodeScalars.allSatisfy({ isHostCharacter($0) }) {
            return "Enter a host such as github.com."
        }
        if path.isEmpty || path == "/" || path.hasSuffix("/") || raw.contains("..") {
            return "Name the repository, such as https://github.com/owner/repo.git."
        }
        if let allowedHosts, !allowedHosts.map({ $0.lowercased() }).contains(host) {
            return "This host is not on the gateway's allow-list."
        }
        return nil
    }

    /// The host of a remote that the rules accept, lowercased. Nil when the URL is empty or not valid.
    static func host(of raw: String) -> String? {
        guard !raw.isEmpty, problem(with: raw) == nil else { return nil }
        return split(raw).authority.lowercased()
    }

    /// Everything after `https://`, cut at the first slash: the authority and the path.
    private static func split(_ raw: String) -> (authority: String, path: String) {
        let rest = String(raw.dropFirst(scheme.count))
        guard let slash = rest.firstIndex(of: "/") else { return (rest, "") }
        return (String(rest[..<slash]), String(rest[slash...]))
    }

    private static func isHostCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "0"..."9", ".", "-": return true
        default: return false
        }
    }
}

/// The picker's rows: the profiles whose host is the remote's host (D-105, the gateway enforces it too).
enum GatewayGitCredentialRows {
    /// Only profiles whose host equals `remoteHost` (case-insensitive). No remote host, no rows.
    static func matching(_ credentials: [GatewayGitCredential], remoteHost: String?) -> [GatewayGitCredential] {
        guard let remoteHost, !remoteHost.isEmpty else { return [] }
        let wanted = remoteHost.lowercased()
        return credentials.filter { $0.host.lowercased() == wanted }
    }
}

/// Whether a secret may be sent over a connection (D-105). Only wss carries a token; ws:// sends it unencrypted.
enum GatewayGitSecretPolicy {
    static let insecureMessage = "Credentials can be added only over a secure connection (wss://)."

    /// True only for `wss`. The scheme is the app's own server setting, the signal the phone has.
    static func allowsSecret(overScheme scheme: String) -> Bool {
        scheme.lowercased() == "wss"
    }
}

/// Checks for a credential profile's name, host and token, as the form shows them. The gateway checks
/// the same things again, so these only say what is wrong before a request is sent.
enum GatewayGitCredentialRules {
    static let maxNameLength = 40
    static let maxTokenLength = 4096

    /// The first problem with a name, or nil. `replacing` is the profile being replaced, which may keep its name.
    static func nameProblem(_ name: String, existing: [GatewayGitCredential], replacing id: String?) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter a name." }
        if trimmed.count > maxNameLength { return "Use at most \(maxNameLength) characters." }
        let clash = existing.contains { $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        if clash { return "A credential named “\(trimmed)” already exists." }
        return nil
    }

    /// A bare host: lowercase letters, digits, dots and hyphens. No scheme, path, port or spaces.
    static func hostProblem(_ host: String) -> String? {
        if host.isEmpty { return "Enter a host such as github.com." }
        let allowed = host.lowercased().unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "0"..."9", ".", "-": return true
            default: return false
            }
        }
        if !allowed { return "Enter a host such as github.com. No scheme, path or port." }
        return nil
    }

    /// A token: 1 to 4096 bytes, no spaces, control characters or non-ASCII (the gateway's rule, D-105).
    /// The text never repeats the token.
    static func tokenProblem(_ token: String) -> String? {
        if token.isEmpty { return "Enter a token or password." }
        if token.utf8.count > maxTokenLength { return "Use at most \(maxTokenLength) characters." }
        if token.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value >= 0x7f }) {
            return "A token has no spaces or special characters. Check it and try again."
        }
        return nil
    }
}

/// The branch line of a repository: "No commits yet" when the gateway says the repository is unborn,
/// "Detached HEAD" when there is no branch, and otherwise the branch name.
enum GatewayGitHeadText {
    static func label(branch: String?, unborn: Bool) -> String {
        if unborn { return "No commits yet" }
        return branch ?? "Detached HEAD"
    }
}

/// Text for a stored credential's row.
enum GatewayGitCredentialText {
    /// "Created 8 Nov 2026", or nil when the gateway's timestamp does not parse.
    static func createdLabel(_ iso: String) -> String? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = withFraction.date(from: iso) ?? plain.date(from: iso) else { return nil }
        return "Created " + date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
