#if canImport(UIKit)
import Foundation
import UIKit
import UniformTypeIdentifiers
import Testing
@testable import ACPCode

/// Records what a copy writes, instead of touching the system pasteboard.
final class RecordingPasteboard: MessagePasteboard {
    private(set) var writes: [(items: [[String: Any]], options: [UIPasteboard.OptionsKey: Any])] = []

    func setItems(_ items: [[String: Any]], options: [UIPasteboard.OptionsKey: Any]) {
        writes.append((items, options))
    }
}

struct MessageCopyTests {

    // MARK: Pasteboard item and write

    @Test func pasteboardItemHoldsTheTextExactly() {
        let text = "Title\n\n- item with emphasis  \ncode 日本語 \u{1F642}\n"
        let items = MessageCopy.pasteboardItems(for: text)

        #expect(items?.count == 1)
        #expect(items?.first?.count == 1)
        #expect(items?.first?[UTType.utf8PlainText.identifier] as? String == text)
    }

    @Test func writeIsShareableWithNoExpiry() {
        let pasteboard = RecordingPasteboard()

        let wrote = MessageCopy.write("hello", to: pasteboard)

        #expect(wrote)
        #expect(pasteboard.writes.count == 1)
        let options = pasteboard.writes.first?.options ?? [:]
        #expect(options.isEmpty)
        #expect(options[.localOnly] == nil)
        #expect(options[.expirationDate] == nil)
        #expect(pasteboard.writes.first?.items.count == 1)
    }

    @Test func emptyOrBlankTextIsNotCopied() {
        for text in ["", "   ", "\n\t"] {
            let pasteboard = RecordingPasteboard()

            #expect(MessageCopy.write(text, to: pasteboard) == false)
            #expect(pasteboard.writes.isEmpty)
            #expect(MessageCopy.pasteboardItems(for: text) == nil)
        }
    }

    // MARK: Controller: copy, haptic, reuse

    @MainActor
    @Test func copyWritesTheCurrentTextAndGivesASuccessHaptic() {
        let pasteboard = RecordingPasteboard()
        var haptics = 0
        let controller = MessageCopyController(pasteboard: pasteboard, feedback: { haptics += 1 })

        controller.setText("first")
        #expect(controller.copyCurrentText())
        #expect(haptics == 1)
        #expect(pasteboard.writes.last?.items.first?[UTType.utf8PlainText.identifier] as? String == "first")

        controller.setText("second")
        #expect(controller.copyCurrentText())
        #expect(haptics == 2)
        #expect(pasteboard.writes.last?.items.first?[UTType.utf8PlainText.identifier] as? String == "second")
    }

    @MainActor
    @Test func copyWithNoTextWritesNothingAndGivesNoHaptic() {
        let pasteboard = RecordingPasteboard()
        var haptics = 0
        let controller = MessageCopyController(pasteboard: pasteboard, feedback: { haptics += 1 })

        #expect(controller.copyCurrentText() == false)
        controller.setText("  ")
        #expect(controller.copyCurrentText() == false)
        #expect(pasteboard.writes.isEmpty)
        #expect(haptics == 0)
    }

    @MainActor
    @Test func providerTextIsReadAtCopyTime() {
        // A markdown row copies what its view shows when the copy happens, not what it showed at configure.
        let pasteboard = RecordingPasteboard()
        var shown: String? = nil
        let controller = MessageCopyController(pasteboard: pasteboard, feedback: {}, textProvider: { shown })

        #expect(controller.copyCurrentText() == false)

        shown = "rendered words"
        #expect(controller.copyCurrentText())
        #expect(pasteboard.writes.last?.items.first?[UTType.utf8PlainText.identifier] as? String == "rendered words")
    }

    // MARK: Context menu and VoiceOver

    @MainActor
    @Test func contextMenuOffersCopyOnlyWhenThereIsText() {
        let controller = MessageCopyController(pasteboard: RecordingPasteboard(), feedback: {})
        let interaction = UIContextMenuInteraction(delegate: controller)

        controller.setText(nil)
        #expect(controller.contextMenuInteraction(interaction, configurationForMenuAtLocation: .zero) == nil)

        controller.setText("  ")
        #expect(controller.contextMenuInteraction(interaction, configurationForMenuAtLocation: .zero) == nil)

        controller.setText("hello")
        #expect(controller.contextMenuInteraction(interaction, configurationForMenuAtLocation: .zero) != nil)
    }

    @MainActor
    @Test func contextMenuCopyActionWritesTheRowText() {
        let pasteboard = RecordingPasteboard()
        var haptics = 0
        let controller = MessageCopyController(pasteboard: pasteboard, feedback: { haptics += 1 })
        let interaction = UIContextMenuInteraction(delegate: controller)
        controller.setText("menu source")

        #expect(controller.contextMenuInteraction(interaction, configurationForMenuAtLocation: .zero) != nil)
        let copy = controller.makeCopyMenu().children.first as? UIAction
        #expect(copy?.title == MessageCopy.menuTitle)
        copy?.performWithSender(nil, target: nil)

        #expect(pasteboard.writes.count == 1)
        #expect(pasteboard.writes.first?.items.first?[UTType.utf8PlainText.identifier] as? String == "menu source")
        #expect(haptics == 1)
    }

    @MainActor
    @Test func voiceOverCopyActionAppearsOnlyWhenThereIsText() {
        let controller = MessageCopyController(pasteboard: RecordingPasteboard(), feedback: {})
        let label = UILabel()
        controller.attachAccessibility(to: label)
        #expect(label.accessibilityCustomActions == nil)

        controller.setText("hi")
        #expect(label.accessibilityCustomActions?.map(\.name) == [MessageCopy.accessibilityActionName])

        controller.setText("")
        #expect(label.accessibilityCustomActions == nil)
    }

    @MainActor
    @Test func providerRowKeepsTheVoiceOverActionBecauseItsTextRendersLater() {
        let controller = MessageCopyController(pasteboard: RecordingPasteboard(), feedback: {}, textProvider: { nil })
        let view = UIView()
        controller.attachAccessibility(to: view)

        #expect(view.accessibilityCustomActions?.map(\.name) == [MessageCopy.accessibilityActionName])
    }

    // MARK: Reused rows copy only what they now show

    @MainActor
    @Test func reusedUserRowCopiesOnlyTheMessageItNowShows() {
        let row = UserTextRowView(frame: CGRect(x: 0, y: 0, width: 320, height: 80))

        row.text = "first prompt"
        #expect(row.copyController.text == "first prompt")

        row.text = "second prompt"
        #expect(row.copyController.text == "second prompt")

        row.prepareForReuse()
        #expect(row.copyController.text == nil)
    }

    @MainActor
    @Test func markdownRowHasNoTextUntilItIsRendered() {
        let row = MarkdownRowView(style: .assistant)

        // A fresh row shows nothing (an empty rendered text), so it has nothing to copy.
        #expect(MessageCopy.hasText(row.copyController.text) == false)
    }
}
#endif
