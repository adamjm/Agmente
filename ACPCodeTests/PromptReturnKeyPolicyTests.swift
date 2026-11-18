import Testing
@testable import ACPCode

/// Hardware-keyboard Return in the prompt composer (iPad and iPhone). The on-screen Return key is
/// text input and never reaches this policy, so it keeps inserting a newline.
struct PromptReturnKeyPolicyTests {

    @Test func returnWithSendableDraftSends() {
        let action = PromptReturnKeyPolicy.action(
            isReturnKey: true,
            shiftDown: false,
            otherModifiersDown: false,
            hasMarkedText: false,
            canSend: true
        )
        #expect(action == .send)
    }

    @Test func returnWhileSendIsDisabledInsertsNewline() {
        // A turn is streaming, so the send button is disabled. The person is drafting the next prompt.
        let action = PromptReturnKeyPolicy.action(
            isReturnKey: true,
            shiftDown: false,
            otherModifiersDown: false,
            hasMarkedText: false,
            canSend: false
        )
        #expect(action == .insertNewline)
    }

    @Test func shiftReturnInsertsNewlineEvenWhenSendable() {
        let action = PromptReturnKeyPolicy.action(
            isReturnKey: true,
            shiftDown: true,
            otherModifiersDown: false,
            hasMarkedText: false,
            canSend: true
        )
        #expect(action == .insertNewline)
    }

    @Test func returnWithMarkedTextDoesNotSend() {
        // CJK input: Return confirms the composition, and the input method owns it.
        let action = PromptReturnKeyPolicy.action(
            isReturnKey: true,
            shiftDown: false,
            otherModifiersDown: false,
            hasMarkedText: true,
            canSend: true
        )
        #expect(action == .passThrough)
    }

    @Test func returnWithCommandOrOptionIsLeftToUIKit() {
        // Cmd+Return is the macOS and Catalyst shortcut (PromptComposerCommands). It must not send here too.
        let action = PromptReturnKeyPolicy.action(
            isReturnKey: true,
            shiftDown: false,
            otherModifiersDown: true,
            hasMarkedText: false,
            canSend: true
        )
        #expect(action == .passThrough)
    }

    @Test func otherKeysAreUnaffected() {
        for canSend in [true, false] {
            for shift in [true, false] {
                for marked in [true, false] {
                    let action = PromptReturnKeyPolicy.action(
                        isReturnKey: false,
                        shiftDown: shift,
                        otherModifiersDown: false,
                        hasMarkedText: marked,
                        canSend: canSend
                    )
                    #expect(action == .passThrough)
                }
            }
        }
    }
}
