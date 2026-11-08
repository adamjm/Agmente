import Foundation

// Pure rules for the sidebar rows and the avatar, so they are tested without a view.

/// What trails a session row. A running or unread session gets a blue dot. Approval and failure keep a
/// glyph, because a dot cannot say either of them, and the words stay in the accessibility label.
enum SidebarRowIndicator: Equatable {
    case none
    case dot
    case approval
    case failed
}

enum SidebarPresentation {
    static func indicator(status: ForkStatusKind, unread: Int) -> SidebarRowIndicator {
        switch status {
        case .awaitingApproval: return .approval
        case .error: return .failed
        case .running: return .dot
        case .idle, .unknown: return unread > 0 ? .dot : .none
        }
    }

    /// VoiceOver text for a row: the title, then the status words, the unread count and any extra text.
    static func accessibilityLabel(title: String, status: ForkStatusKind, unread: Int, extras: [String] = []) -> String {
        var parts = [title]
        if let label = status.label { parts.append(label) }
        if unread > 0 { parts.append("\(unread) unread") }
        parts.append(contentsOf: extras.filter { !$0.isEmpty })
        return parts.joined(separator: ". ")
    }

    /// Up to two initials from a server name: "Bob Gateway" gives "BG", "my-home-server" gives "MH".
    /// Empty when the name has no letters or digits, so the caller shows a generic icon.
    static func initials(for name: String) -> String {
        let words = name
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard !words.isEmpty else { return "" }
        return words.prefix(2)
            .compactMap { $0.first }
            .map { String($0).uppercased() }
            .joined()
    }
}
