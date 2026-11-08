import Testing
@testable import ACPCode

/// The session screen drops the keyboard only when a new approval appears (ApprovalKeyboardRule).
struct ApprovalKeyboardRuleTests {

    @Test func risingFromZeroDismisses() {
        #expect(ApprovalKeyboardRule.shouldDismiss(previousCount: 0, currentCount: 1))
    }

    @Test func risingFromFewerApprovalsDismisses() {
        #expect(ApprovalKeyboardRule.shouldDismiss(previousCount: 1, currentCount: 2))
    }

    @Test func sameCountDoesNotDismiss() {
        #expect(!ApprovalKeyboardRule.shouldDismiss(previousCount: 0, currentCount: 0))
        #expect(!ApprovalKeyboardRule.shouldDismiss(previousCount: 1, currentCount: 1))
    }

    @Test func fallingCountDoesNotDismiss() {
        #expect(!ApprovalKeyboardRule.shouldDismiss(previousCount: 2, currentCount: 1))
        #expect(!ApprovalKeyboardRule.shouldDismiss(previousCount: 1, currentCount: 0))
    }

    @Test func countsOnlyToolCallsAwaitingPermission() {
        let messages = [
            ChatMessage(role: .user, content: "run it", isStreaming: false),
            ChatMessage(role: .assistant, content: "", isStreaming: true, segments: [
                toolSegment(title: "rm -rf build", status: "awaiting_permission"),
                toolSegment(title: "ls", status: "completed"),
                toolSegment(title: "npm test", status: "in_progress"),
                AssistantSegment(kind: .message, text: "text"),
            ]),
            ChatMessage(role: .assistant, content: "", isStreaming: false, segments: [
                toolSegment(title: "git push", status: "awaiting_permission"),
            ]),
        ]
        #expect(ApprovalKeyboardRule.awaitingApprovalCount(in: messages) == 2)
    }

    @Test func emptyTranscriptHasNoApprovals() {
        #expect(ApprovalKeyboardRule.awaitingApprovalCount(in: []) == 0)
    }

    private func toolSegment(title: String, status: String) -> AssistantSegment {
        AssistantSegment(kind: .toolCall, text: title, toolCall: ToolCallDisplay(toolCallId: title, title: title, kind: "execute", status: status))
    }
}
