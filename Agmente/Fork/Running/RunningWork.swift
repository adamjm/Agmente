import Foundation

/// One step of a session's event log, as far as running work needs it (contract C3).
enum RunningWorkEvent: Equatable {
    /// A `tool_call`. Its own status does not end it: only a later terminal `tool_call_update` does.
    case toolCall(toolCallId: String?, title: String)
    /// A `tool_call_update`. Only `completed` and `failed` are terminal; other statuses keep the call running.
    case toolCallUpdate(toolCallId: String?, status: String?)
    /// A permission request (or Codex-style approval) opened for a tool call.
    case approvalOpened(toolCallId: String?)
    /// The approval was answered or closed.
    case approvalClosed(toolCallId: String?)
}

/// The running work of one session, derived from its events (contract C3). A pure value type with no UI.
struct RunningWork: Equatable {
    struct Tool: Equatable {
        let toolCallId: String?
        let title: String
    }

    /// The strip lists at most this many running tool titles.
    static let listedToolLimit = 5

    /// Whether the turn is running (the session status `running`, or the transcript's live turn).
    let turnRunning: Bool
    /// Running tool calls, in the order they were first called.
    let runningTools: [Tool]
    /// Approvals waiting for the phone.
    let openApprovals: Int

    static let empty = RunningWork(turnRunning: false, runningTools: [], openApprovals: 0)

    var runningToolCount: Int { runningTools.count }
    var listedTools: [Tool] { Array(runningTools.prefix(Self.listedToolLimit)) }
    var hiddenToolCount: Int { max(0, runningTools.count - Self.listedToolLimit) }
    var isEmpty: Bool { runningTools.isEmpty && openApprovals == 0 }

    /// Derives the running work from events in log order.
    ///
    /// A tool call is running when its `toolCall` has no later terminal update (`completed` or `failed`) with the
    /// same `toolCallId`. A later `toolCall` with the same id starts it again. An update without an id closes the
    /// most recent open call that has no id.
    static func derive(from events: [RunningWorkEvent], turnRunning: Bool) -> RunningWork {
        var tools: [(toolCallId: String?, title: String, open: Bool)] = []
        var approvals: [String?] = []

        for event in events {
            switch event {
            case let .toolCall(toolCallId, title):
                if let toolCallId, let index = tools.firstIndex(where: { $0.toolCallId == toolCallId }) {
                    tools[index].title = title
                    tools[index].open = true
                } else {
                    tools.append((toolCallId: toolCallId, title: title, open: true))
                }

            case let .toolCallUpdate(toolCallId, status):
                guard let status, status == "completed" || status == "failed" else { continue }
                if let toolCallId {
                    for index in tools.indices where tools[index].toolCallId == toolCallId {
                        tools[index].open = false
                    }
                } else if let index = tools.lastIndex(where: { $0.toolCallId == nil && $0.open }) {
                    tools[index].open = false
                }

            case let .approvalOpened(toolCallId):
                approvals.append(toolCallId)

            case let .approvalClosed(toolCallId):
                if let index = approvals.firstIndex(where: { $0 == toolCallId }) {
                    approvals.remove(at: index)
                }
            }
        }

        let running = tools
            .filter { $0.open }
            .map { Tool(toolCallId: $0.toolCallId, title: $0.title) }
        return RunningWork(turnRunning: turnRunning, runningTools: running, openApprovals: approvals.count)
    }
}
