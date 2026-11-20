import Foundation

/// What a hardware-keyboard Return press does in the prompt composer.
enum PromptReturnKeyAction: Equatable {
    /// Send the prompt. The text view must not also insert a newline.
    case send
    /// Insert a newline: Shift+Return, or Return while the prompt cannot be sent yet.
    case insertNewline
    /// Not a Return press, a Return with other modifiers, or a Return that the input method owns
    /// (marked text). UIKit handles it as usual.
    case passThrough
}

/// Decides what a key press does in the composer. Pure: no UIKit, so it can be unit tested.
/// The on-screen keyboard never reaches this code; it sends text input, not key presses.
enum PromptReturnKeyPolicy {
    static func action(
        isReturnKey: Bool,
        shiftDown: Bool,
        otherModifiersDown: Bool,
        hasMarkedText: Bool,
        canSend: Bool
    ) -> PromptReturnKeyAction {
        guard isReturnKey else { return .passThrough }
        // Command, Option and Control combinations belong to shortcuts, not to the composer.
        if otherModifiersDown { return .passThrough }
        if shiftDown { return .insertNewline }
        // CJK and other input methods confirm marked text with Return. Leave that to them.
        if hasMarkedText { return .passThrough }
        return canSend ? .send : .insertNewline
    }
}
