import Foundation

/// When the session screen drops the keyboard for an approval. The rule is "a new approval appeared": the screen
/// dismisses only when the number of approvals waiting on the person goes up. An approval that was already showing,
/// or one that was answered, does not trigger it, so a reply being typed to a seen approval is left alone.
enum ApprovalKeyboardRule {
    /// Tool calls the agent is waiting on the person to approve, across the transcript. This covers the running
    /// strip's approvals and the transcript-only permission cards alike, since both read the same status.
    static func awaitingApprovalCount(in messages: [ChatMessage]) -> Int {
        messages.reduce(0) { total, message in
            total + message.segments.filter { segment in
                segment.kind == .toolCall && segment.toolCall?.status == "awaiting_permission"
            }.count
        }
    }

    /// True when the count rose above the previous count, false when it stayed the same or fell.
    static func shouldDismiss(previousCount: Int, currentCount: Int) -> Bool {
        currentCount > previousCount
    }
}
