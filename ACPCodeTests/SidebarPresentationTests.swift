import Testing
import ACPClient
@testable import ACPCode

// Sidebar presentation rules (Fork/Sidebar/SidebarPresentation.swift). Pure logic, no view.

struct SidebarPresentationTests {
    @Test func runningAndUnreadSessionsShowTheBlueDot() {
        #expect(SidebarPresentation.indicator(status: .running, unread: 0) == .dot)
        #expect(SidebarPresentation.indicator(status: .idle, unread: 2) == .dot)
    }

    @Test func idleReadSessionShowsNoIndicator() {
        #expect(SidebarPresentation.indicator(status: .idle, unread: 0) == .none)
        #expect(SidebarPresentation.indicator(status: .unknown("weird"), unread: 0) == .none)
    }

    @Test func approvalAndFailureKeepAGlyphInsteadOfTheDot() {
        #expect(SidebarPresentation.indicator(status: .awaitingApproval, unread: 3) == .approval)
        #expect(SidebarPresentation.indicator(status: .error, unread: 0) == .failed)
    }

    @Test func accessibilityLabelKeepsStatusWordsAndUnreadCount() {
        let label = SidebarPresentation.accessibilityLabel(
            title: "Fix tests",
            status: .running,
            unread: 2,
            extras: ["", "~/work"]
        )
        #expect(label == "Fix tests. Running. 2 unread. ~/work")
    }

    @Test func idleReadRowLabelIsJustTheTitle() {
        #expect(SidebarPresentation.accessibilityLabel(title: "Old chat", status: .idle, unread: 0) == "Old chat")
    }

    @Test func initialsTakeUpToTwoWords() {
        #expect(SidebarPresentation.initials(for: "Bob Gateway") == "BG")
        #expect(SidebarPresentation.initials(for: "my-home-server") == "MH")
        #expect(SidebarPresentation.initials(for: "mac") == "M")
        #expect(SidebarPresentation.initials(for: "  ") == "")
        #expect(SidebarPresentation.initials(for: "") == "")
    }
}
