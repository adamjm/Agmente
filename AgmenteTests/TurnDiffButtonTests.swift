#if canImport(UIKit)
import UIKit
import Testing
@testable import Agmente

/// FR-31: the live chat list draws file changes with the UIKit row, so the "Turn diff" button must
/// exist there: hidden without a handler, visible and wired with one.
@MainActor
struct TurnDiffButtonTests {
    private static let items = [
        FileChangeSummaryItem(id: "1", title: "Edit: a.txt", path: "a.txt", verb: "Edit", status: "completed", diff: "+x")
    ]

    private static func button(in view: UIView) -> UIButton? {
        if let b = view as? UIButton, b.accessibilityIdentifier == "turnDiffButton" { return b }
        for sub in view.subviews { if let found = button(in: sub) { return found } }
        return nil
    }

    private func makeRow(onTurnDiff: (() -> Void)?) -> FileChangesRowView {
        let row = FileChangesRowView(frame: CGRect(x: 0, y: 0, width: 360, height: 120))
        row.configure(items: Self.items, onUndo: {}, onReview: { _ in }, onTurnDiff: onTurnDiff)
        row.layoutIfNeeded()
        return row
    }

    @Test func buttonIsHiddenWithoutHandler() throws {
        let row = makeRow(onTurnDiff: nil)
        let button = try #require(Self.button(in: row))
        #expect(button.isHidden)
    }

    @Test func buttonIsVisibleAndFiresHandler() throws {
        var taps = 0
        let row = makeRow(onTurnDiff: { taps += 1 })
        let button = try #require(Self.button(in: row))
        #expect(!button.isHidden)
        button.sendActions(for: .touchUpInside)
        #expect(taps == 1)
    }

    @Test func reconfiguringWithoutHandlerHidesAgain() throws {
        let row = makeRow(onTurnDiff: {})
        row.configure(items: Self.items, onUndo: {}, onReview: { _ in }, onTurnDiff: nil)
        let button = try #require(Self.button(in: row))
        #expect(button.isHidden)
    }
}
#endif
