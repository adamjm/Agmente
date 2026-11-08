import Foundation
import ACP
import ACPClient

/// An approval the person can answer from the running strip: a tool call of the current turn that is
/// awaiting permission, with the options the agent offered for it.
struct OpenApproval: Equatable {
    let requestId: ACP.ID
    let title: String
    let options: [ACPPermissionOption]
}

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

    /// The approvals of the current turn that the person can answer now, oldest first. Empty when no turn runs.
    /// An approval without a request id or without options cannot be answered here, so it is left out; the
    /// transcript card still shows it.
    static func openApprovals(in messages: [ChatMessage]) -> [OpenApproval] {
        guard messages.contains(where: { $0.isStreaming }) else { return [] }
        let turnStart = (messages.lastIndex { $0.role == .user } ?? -1) + 1
        var approvals: [OpenApproval] = []
        for message in messages[turnStart...] where message.role == .assistant {
            for segment in message.segments where segment.kind == .toolCall {
                guard let tool = segment.toolCall,
                      tool.status == "awaiting_permission",
                      let requestId = tool.acpPermissionRequestId,
                      let options = tool.permissionOptions, !options.isEmpty else { continue }
                approvals.append(OpenApproval(requestId: requestId, title: tool.title, options: options))
            }
        }
        return approvals
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
