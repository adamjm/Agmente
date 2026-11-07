import Foundation

/// Builds running-work events from a session's transcript rows (the view model's tool-call state).
///
/// Only the current turn counts: the assistant rows after the last user row, and only while a turn is running.
/// A transcript restored after the app quit can hold tool calls that never got a terminal update. They belong to
/// a turn that is no longer running, so they are not shown as running.
enum RunningWorkEvents {
    static func work(in messages: [ChatMessage]) -> RunningWork {
        let turnRunning = messages.contains { $0.isStreaming }
        guard turnRunning else { return .empty }
        return RunningWork.derive(from: events(in: messages), turnRunning: true)
    }

    static func events(in messages: [ChatMessage]) -> [RunningWorkEvent] {
        let turnStart = (messages.lastIndex { $0.role == .user } ?? -1) + 1
        var events: [RunningWorkEvent] = []

        for message in messages[turnStart...] where message.role == .assistant {
            for segment in message.segments where segment.kind == .toolCall {
                guard let tool = segment.toolCall else { continue }
                events.append(.toolCall(toolCallId: tool.toolCallId, title: tool.title))
                if let status = tool.status {
                    events.append(.toolCallUpdate(toolCallId: tool.toolCallId, status: status))
                }
                if tool.permissionOptions != nil || tool.approvalRequestId != nil {
                    events.append(.approvalOpened(toolCallId: tool.toolCallId))
                }
            }
        }
        return events
    }
}
