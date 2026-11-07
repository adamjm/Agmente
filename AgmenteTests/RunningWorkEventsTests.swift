import Testing
import ACP
import ACPClient
@testable import Agmente

/// C3 in the app: running work read from the transcript rows (the view model's tool-call state).
struct RunningWorkEventsTests {

    private func toolSegment(id: String?, title: String, status: String?) -> AssistantSegment {
        AssistantSegment(kind: .toolCall, text: title, toolCall: ToolCallDisplay(toolCallId: id, title: title, kind: "execute", status: status))
    }

    private func assistant(streaming: Bool, _ segments: [AssistantSegment]) -> ChatMessage {
        ChatMessage(role: .assistant, content: "", isStreaming: streaming, segments: segments)
    }

    private var userRow: ChatMessage {
        ChatMessage(role: .user, content: "run it", isStreaming: false)
    }

    @Test func runningTurnShowsToolCallsWithNoTerminalUpdate() {
        let messages = [
            userRow,
            assistant(streaming: true, [
                toolSegment(id: "t1", title: "npm test", status: "in_progress"),
                toolSegment(id: "t2", title: "ls", status: "completed"),
            ]),
        ]
        let work = RunningWorkEvents.work(in: messages)
        #expect(work.turnRunning)
        #expect(work.runningTools.map(\.title) == ["npm test"])
    }

    @Test func toolCallWithNoUpdateIsRunningInTheLiveTurn() {
        let messages = [
            userRow,
            assistant(streaming: true, [toolSegment(id: "t1", title: "git status", status: "pending")]),
        ]
        #expect(RunningWorkEvents.work(in: messages).runningToolCount == 1)
    }

    @Test func failedToolIsNotRunning() {
        let messages = [
            userRow,
            assistant(streaming: true, [toolSegment(id: "t1", title: "make", status: "failed")]),
        ]
        #expect(RunningWorkEvents.work(in: messages).isEmpty)
    }

    @Test func restoredTranscriptWithoutALiveTurnShowsNothing() {
        let messages = [
            userRow,
            assistant(streaming: false, [toolSegment(id: "t1", title: "sleep 100", status: "pending")]),
        ]
        let work = RunningWorkEvents.work(in: messages)
        #expect(!work.turnRunning)
        #expect(work.isEmpty)
    }

    @Test func toolsFromAnEarlierTurnAreNotRunning() {
        let messages = [
            userRow,
            assistant(streaming: false, [toolSegment(id: "old", title: "old command", status: "pending")]),
            ChatMessage(role: .user, content: "next", isStreaming: false),
            assistant(streaming: true, [toolSegment(id: "new", title: "new command", status: "in_progress")]),
        ]
        let work = RunningWorkEvents.work(in: messages)
        #expect(work.runningTools.map(\.title) == ["new command"])
    }

    @Test func openPermissionRequestIsCountedAsAnApproval() {
        var waiting = toolSegment(id: "t1", title: "rm -rf build", status: "awaiting_permission")
        // Options come from a real session/request_permission payload, parsed as the app does.
        let params: ACP.Value = .object([
            "toolCall": .object(["toolCallId": .string("t1"), "title": .string("rm -rf build")]),
            "options": .array([.object(["optionId": .string("allow"), "name": .string("Allow"), "kind": .string("allow_once")])]),
        ])
        waiting.toolCall?.permissionOptions = ACPPermissionRequestParser.parse(params: params)?.options
        let messages = [userRow, assistant(streaming: true, [waiting])]

        let work = RunningWorkEvents.work(in: messages)
        #expect(work.openApprovals == 1)
        #expect(work.runningToolCount == 1)
    }

    @Test func answeredPermissionRequestIsNotCounted() {
        let answered = toolSegment(id: "t1", title: "ls", status: "pending")
        let messages = [userRow, assistant(streaming: true, [answered])]
        #expect(RunningWorkEvents.work(in: messages).openApprovals == 0)
    }

    @Test func emptyTranscriptGivesAnEmptyStrip() {
        #expect(RunningWorkEvents.work(in: []).isEmpty)
    }
}
