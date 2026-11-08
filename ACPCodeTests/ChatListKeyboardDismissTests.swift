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

    @MainActor
    @Test func userDragOnTranscriptFiresDismissHook() {
        let list = HighPerformanceChatListView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        var fired = 0
        list.onUserDragBegan = { fired += 1 }

        list.transcriptDidBeginUserDrag()

        #expect(fired == 1)
    }

    @MainActor
    @Test func scrollViewWillBeginDraggingFiresDismissHook() {
        let list = HighPerformanceChatListView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        guard let scrollView = list.subviews.compactMap({ $0 as? UIScrollView }).first else {
            Issue.record("transcript scroll view not found")
            return
        }
        var fired = 0
        list.onUserDragBegan = { fired += 1 }

        list.scrollViewWillBeginDragging(scrollView)

        #expect(fired == 1)
    }
}
