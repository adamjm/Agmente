import Testing
import UIKit
@testable import ACPCode

/// The transcript scroll view drops the keyboard as soon as the person scrolls (interactive dismissal).
struct ChatListKeyboardDismissTests {

    @MainActor
    @Test func transcriptScrollViewDismissesKeyboardInteractively() {
        let list = HighPerformanceChatListView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let scrollViews = list.subviews.compactMap { $0 as? UIScrollView }
        #expect(scrollViews.count == 1)
        #expect(scrollViews.first?.keyboardDismissMode == .interactive)
    }
}
