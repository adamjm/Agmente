import SwiftUI

/// The prompt composer's text field, shared by the ACP and Codex session views.
///
/// On iOS and macOS it is a native text view, so a hardware-keyboard Return can send the prompt while
/// Shift+Return inserts a newline. SwiftUI's TextEditor cannot tell those keys apart, and it inserts the
/// newline before any key handler runs. The macOS send shortcut (Cmd+Return, PromptComposerCommands) is kept.
/// Other platforms keep the TextEditor.
struct PromptComposerTextField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var canSend: Bool
    var onSend: () -> Void

    var body: some View {
#if os(iOS)
        PromptUITextViewRepresentable(
            text: $text,
            isFocused: isFocused,
            canSend: canSend,
            onSend: onSend
        )
#elseif os(macOS)
        PromptNSTextViewRepresentable(
            text: $text,
            isFocused: isFocused,
            canSend: canSend,
            onSend: onSend
        )
#else
        TextEditor(text: $text)
            .focused(isFocused)
#endif
    }
}

#if os(macOS)
import AppKit

private struct PromptNSTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var canSend: Bool
    var onSend: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PromptNSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? PromptNSTextView else { return }
        textView.canSend = canSend
        textView.onSend = onSend

        // Only an outside change (for example a send that clears the prompt) rewrites the text.
        if textView.string != text {
            textView.string = text
        }

        // Focus is set from SwiftUI and reported back by the delegate, after the update pass.
        let wantsFocus = isFocused.wrappedValue
        DispatchQueue.main.async {
            guard let window = textView.window else { return }
            if wantsFocus, window.firstResponder !== textView {
                window.makeFirstResponder(textView)
            } else if !wantsFocus, window.firstResponder === textView {
                window.makeFirstResponder(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptNSTextViewRepresentable

        init(parent: PromptNSTextViewRepresentable) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused.wrappedValue = false
        }
    }
}

/// An NSTextView that sends on a Return key press. Every other press goes to AppKit unchanged.
final class PromptNSTextView: NSTextView {
    var canSend = false
    var onSend: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        // 36 is Return and 76 is the keypad Enter key.
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let modifiers = event.modifierFlags
        let action = PromptReturnKeyPolicy.action(
            isReturnKey: isReturn,
            shiftDown: modifiers.contains(.shift),
            otherModifiersDown: !modifiers.intersection([.command, .option, .control]).isEmpty,
            hasMarkedText: hasMarkedText(),
            canSend: canSend
        )
        switch action {
        case .send:
            onSend()
        case .insertNewline, .passThrough:
            super.keyDown(with: event)
        }
    }
}
#endif

#if os(iOS)
private struct PromptUITextViewRepresentable: UIViewRepresentable {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var canSend: Bool
    var onSend: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> PromptUITextView {
        let textView = PromptUITextView()
        textView.delegate = context.coordinator
        // Same look as the TextEditor it replaces: transparent, body font, default insets (the
        // placeholder offsets in the composers assume these).
        textView.backgroundColor = .clear
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .label
        textView.isScrollEnabled = true
        textView.text = text
        return textView
    }

    func updateUIView(_ textView: PromptUITextView, context: Context) {
        context.coordinator.parent = self
        textView.canSend = canSend
        textView.onSend = onSend

        // Only an outside change (for example a send that clears the prompt) rewrites the text.
        // Typing already matches the binding, so the caret is not moved.
        if textView.text != text {
            textView.text = text
        }

        // A tap focuses the field through the delegate, and SwiftUI does not apply that to the binding, so
        // the binding stays false after a tap. Resign only when SwiftUI itself turns focus off (true to
        // false); otherwise an update pass would resign the field the person just focused.
        let wantsFocus = isFocused.wrappedValue
        let focusTurnedOff = context.coordinator.lastWantsFocus && !wantsFocus
        context.coordinator.lastWantsFocus = wantsFocus
        DispatchQueue.main.async {
            if wantsFocus, !textView.isFirstResponder {
                textView.becomeFirstResponder()
            } else if focusTurnedOff, textView.isFirstResponder {
                textView.resignFirstResponder()
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PromptUITextViewRepresentable
        /// The focus value the last update pass saw, used to detect a true-to-false change.
        var lastWantsFocus = false

        init(parent: PromptUITextViewRepresentable) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused.wrappedValue = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused.wrappedValue = false
        }
    }
}

/// A UITextView that sends on a hardware-keyboard Return. Every other press goes to UIKit unchanged.
final class PromptUITextView: UITextView {
    var canSend = false
    var onSend: () -> Void = {}

    /// Return presses this view answered with a send. Their release is swallowed too, so UIKit never
    /// sees half of a key press it did not begin.
    private var sentReturnPresses = Set<UIPress>()

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var forwarded = Set<UIPress>()
        for press in presses {
            if let key = press.key, action(for: key) == .send {
                sentReturnPresses.insert(press)
                onSend()
            } else {
                forwarded.insert(press)
            }
        }
        if !forwarded.isEmpty {
            super.pressesBegan(forwarded, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(forwardedPresses(presses), with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesCancelled(forwardedPresses(presses), with: event)
    }

    private func forwardedPresses(_ presses: Set<UIPress>) -> Set<UIPress> {
        var forwarded = Set<UIPress>()
        for press in presses where sentReturnPresses.remove(press) == nil {
            forwarded.insert(press)
        }
        return forwarded
    }

    private func action(for key: UIKey) -> PromptReturnKeyAction {
        let isReturn = key.keyCode == .keyboardReturnOrEnter || key.keyCode == .keypadEnter
        let modifiers = key.modifierFlags
        return PromptReturnKeyPolicy.action(
            isReturnKey: isReturn,
            shiftDown: modifiers.contains(.shift),
            otherModifiersDown: !modifiers.intersection([.command, .alternate, .control]).isEmpty,
            hasMarkedText: markedTextRange != nil,
            canSend: canSend
        )
    }
}
#endif
