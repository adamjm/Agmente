#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers

/// Where a copied message is written. `UIPasteboard.general` in the app; a recorder in tests.
protocol MessagePasteboard: AnyObject {
    func setItems(_ items: [[String: Any]], options: [UIPasteboard.OptionsKey: Any])
}

extension UIPasteboard: MessagePasteboard {}

/// Copy of a chat row's rendered text: the words the person sees, without markdown syntax.
enum MessageCopy {
    static let menuTitle = "Copy"
    static let accessibilityActionName = "Copy message"

    /// No options: the text is shareable, so Universal Clipboard may send it to the person's other devices, and
    /// no expiration date is set. The owner chose this (plan answer, Q5).
    static let pasteboardOptions: [UIPasteboard.OptionsKey: Any] = [:]

    /// Whether `text` has anything to copy. Whitespace-only text counts as nothing.
    static func hasText(_ text: String?) -> Bool {
        guard let text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The pasteboard items for a copy: one plain-text item holding `text` exactly as given. Nil when there is nothing to copy.
    static func pasteboardItems(for text: String) -> [[String: Any]]? {
        guard hasText(text) else { return nil }
        return [[UTType.utf8PlainText.identifier: text]]
    }

    /// Writes `text` to `pasteboard`. Returns false and writes nothing when there is no text, so an empty row never
    /// clears what the person has on the clipboard.
    @discardableResult
    static func write(_ text: String, to pasteboard: MessagePasteboard) -> Bool {
        guard let items = pasteboardItems(for: text) else { return false }
        pasteboard.setItems(items, options: pasteboardOptions)
        return true
    }
}

/// One row's copy behaviour: a long-press context menu and a VoiceOver action, both copying the row's rendered text
/// as it is at the moment of the copy. The text comes from `textProvider` when given (markdown rows read it from the
/// view that shows it), otherwise from `setText` (a plain prompt row). A reused row clears it, so it never copies
/// an older message.
final class MessageCopyController: NSObject, UIContextMenuInteractionDelegate {
    private var pushedText: String?
    private let textProvider: (() -> String?)?
    private let pasteboard: MessagePasteboard
    private let feedback: () -> Void
    private weak var accessibilityView: UIView?

    init(
        pasteboard: MessagePasteboard = UIPasteboard.general,
        feedback: @escaping () -> Void = { UINotificationFeedbackGenerator().notificationOccurred(.success) },
        textProvider: (() -> String?)? = nil
    ) {
        self.pasteboard = pasteboard
        self.feedback = feedback
        self.textProvider = textProvider
        super.init()
    }

    /// The text a copy would write right now.
    var text: String? {
        if let textProvider { return textProvider() }
        return pushedText
    }

    /// Adds the long-press Copy menu to `view`. Call once per row, in init: the menu reads the current text when it opens.
    func attachContextMenu(to view: UIView) {
        view.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    /// Exposes "Copy message" to VoiceOver on `view`. Call once per row, in init.
    func attachAccessibility(to view: UIView) {
        accessibilityView = view
        refreshAccessibility()
    }

    /// Sets the text a row copies when it has no provider. Nil or blank removes the copy action.
    func setText(_ newText: String?) {
        pushedText = newText
        refreshAccessibility()
    }

    /// Copies the current text and gives a success haptic. Returns whether anything was written.
    @discardableResult
    func copyCurrentText() -> Bool {
        guard let text, MessageCopy.write(text, to: pasteboard) else { return false }
        feedback()
        return true
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard MessageCopy.hasText(text) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.makeCopyMenu()
        }
    }

    /// The menu with its single "Copy" action. Only offered when there is text to copy.
    func makeCopyMenu() -> UIMenu {
        let copy = UIAction(
            title: MessageCopy.menuTitle,
            image: UIImage(systemName: "doc.on.doc")
        ) { [weak self] _ in
            self?.copyCurrentText()
        }
        return UIMenu(children: [copy])
    }

    /// With a provider the text can change after configure (rendering is throttled), so the action stays and
    /// copies nothing when there is no text. A plain row removes the action when it has no text.
    private func refreshAccessibility() {
        guard let view = accessibilityView else { return }
        guard textProvider != nil || MessageCopy.hasText(pushedText) else {
            view.accessibilityCustomActions = nil
            return
        }
        let action = UIAccessibilityCustomAction(name: MessageCopy.accessibilityActionName) { [weak self] _ in
            self?.copyCurrentText() ?? false
        }
        view.accessibilityCustomActions = [action]
    }
}
#endif
