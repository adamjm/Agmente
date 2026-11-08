import Foundation

enum ChatScrollAnimationPolicy {
    static let maxAnimatedInsertions = 3

    static func shouldAnimateScrollToBottom(
        from oldMessages: [ChatMessage],
        to newMessages: [ChatMessage],
        hasRendered: Bool
    ) -> Bool {
        guard hasRendered else { return false }
        guard !oldMessages.isEmpty, !newMessages.isEmpty else { return false }

        // Streaming growth commonly updates the last message in place.
        if let oldLast = oldMessages.last, let newLast = newMessages.last,
           oldLast.id == newLast.id, oldLast != newLast {
            return true
        }

        guard newMessages.count > oldMessages.count else { return false }
        let insertedCount = newMessages.count - oldMessages.count
        guard insertedCount <= maxAnimatedInsertions else { return false }

        // Only animate incremental tail appends. Session switches/history hydration
        // usually replace/reorder content and should not animate.
        for index in oldMessages.indices {
            guard oldMessages[index].id == newMessages[index].id else {
                return false
            }
        }

        return true
    }
}
