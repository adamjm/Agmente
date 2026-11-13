import Foundation

/// The text of an approval notification (D-111): "Approval needed: <summary>", where the summary is the
/// tool call's title with a verb for its kind. The same rules as the gateway's push.Summary and
/// push.BuildApproval, so a phone alert and a remote push read the same. Pure: no UIKit, no state.
enum ApprovalNotificationText {
    /// The body with no summary, as before D-111.
    static let emptyBody = "Approval needed"
    /// The most characters a summary keeps, the ellipsis included.
    static let maxCharacters = 80

    static let verbs: [String: String] = [
        "execute": "Run",
        "edit": "Edit",
        "delete": "Delete",
        "read": "Read",
        "fetch": "Fetch",
        "move": "Move",
    ]

    /// The title with the verb for its kind in front ("Run: npm test"). With no known kind, the title
    /// alone. A title that already starts with the verb is not given it again ("Run echo"). An empty
    /// title gives "". Not cut: `body` cuts it.
    static func summary(kind: String?, title: String) -> String {
        let text = squash(title)
        if text.isEmpty { return "" }
        guard let kind, let verb = verbs[kind] else { return text }
        let first = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        if first.lowercased() == verb.lowercased() { return text }
        return "\(verb): \(text)"
    }

    /// The notification body for a tool call: "Approval needed: <summary>", or "Approval needed" when the
    /// summary is empty.
    static func body(kind: String?, title: String) -> String {
        let text = cut(summary(kind: kind, title: title))
        return text.isEmpty ? emptyBody : "\(emptyBody): \(text)"
    }

    /// Every space, tab and newline becomes a space, control and format characters are dropped, and runs
    /// of spaces collapse to one.
    static func squash(_ input: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in input.unicodeScalars {
            if scalar.properties.isWhitespace {
                kept.append(" ")
            } else {
                switch scalar.properties.generalCategory {
                case .control, .format: continue
                default: kept.append(scalar)
                }
            }
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// Keeps the first 79 characters of a text longer than 80, then adds an ellipsis.
    static func cut(_ text: String) -> String {
        let scalars = text.unicodeScalars
        if scalars.count <= maxCharacters { return text }
        var head = String(String.UnicodeScalarView(scalars.prefix(maxCharacters - 1)))
        while head.hasSuffix(" ") { head.removeLast() }
        return head + "…"
    }
}
