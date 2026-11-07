import Testing
@testable import Agmente

/// C3 in the app: which tool calls and approvals are running, derived from the session's events.
struct RunningWorkTests {

    // MARK: - Tool calls

    @Test func toolCallWithNoUpdateIsRunning() {
        let work = RunningWork.derive(from: [.toolCall(toolCallId: "t1", title: "git status")], turnRunning: true)
        #expect(work.runningToolCount == 1)
        #expect(work.runningTools == [RunningWork.Tool(toolCallId: "t1", title: "git status")])
        #expect(!work.isEmpty)
    }

    @Test func completedUpdateEndsTheToolCall() {
        let work = RunningWork.derive(from: [
            .toolCall(toolCallId: "t1", title: "npm test"),
            .toolCallUpdate(toolCallId: "t1", status: "completed"),
        ], turnRunning: true)
        #expect(work.runningToolCount == 0)
        #expect(work.isEmpty)
    }

    @Test func failedUpdateEndsTheToolCall() {
        let work = RunningWork.derive(from: [
            .toolCall(toolCallId: "t1", title: "npm test"),
            .toolCallUpdate(toolCallId: "t1", status: "failed"),
        ], turnRunning: true)
        #expect(work.runningToolCount == 0)
    }

    @Test func inProgressUpdateKeepsTheToolCallRunning() {
        let work = RunningWork.derive(from: [
            .toolCall(toolCallId: "t1", title: "swift build"),
            .toolCallUpdate(toolCallId: "t1", status: "in_progress"),
        ], turnRunning: true)
        #expect(work.runningToolCount == 1)
        #expect(work.runningTools.first?.title == "swift build")
    }

    @Test func terminalUpdateWithAnotherIdDoesNotEndThisToolCall() {
        let work = RunningWork.derive(from: [
            .toolCall(toolCallId: "t1", title: "sleep 5"),
            .toolCall(toolCallId: "t2", title: "ls"),
            .toolCallUpdate(toolCallId: "t2", status: "completed"),
        ], turnRunning: true)
        #expect(work.runningTools.map(\.toolCallId) == ["t1"])
    }

    @Test func toolCallAgainAfterATerminalUpdateIsRunningAgain() {
        let work = RunningWork.derive(from: [
            .toolCall(toolCallId: "t1", title: "ls"),
            .toolCallUpdate(toolCallId: "t1", status: "completed"),
            .toolCall(toolCallId: "t1", title: "ls -la"),
        ], turnRunning: true)
        #expect(work.runningTools == [RunningWork.Tool(toolCallId: "t1", title: "ls -la")])
    }

    @Test func commandTitleIsShownAsGiven() {
        let command = "git log --oneline -n 5 | head"
        let work = RunningWork.derive(from: [.toolCall(toolCallId: "t1", title: command)], turnRunning: true)
        #expect(work.runningTools.first?.title == command)
    }

    @Test func updateWithoutIdClosesTheLatestOpenCallWithoutId() {
        let work = RunningWork.derive(from: [
            .toolCall(toolCallId: nil, title: "first"),
            .toolCall(toolCallId: nil, title: "second"),
            .toolCallUpdate(toolCallId: nil, status: "completed"),
        ], turnRunning: true)
        #expect(work.runningTools.map(\.title) == ["first"])
    }

    @Test func noRunningWorkGivesAnEmptyStrip() {
        #expect(RunningWork.derive(from: [], turnRunning: true).isEmpty)
        #expect(RunningWork.derive(from: [], turnRunning: false).isEmpty)
        let finished = RunningWork.derive(from: [
            .toolCall(toolCallId: "t1", title: "ls"),
            .toolCallUpdate(toolCallId: "t1", status: "completed"),
        ], turnRunning: true)
        #expect(finished.isEmpty)
    }

    @Test func listsAtMostFiveRunningTitles() {
        let events = (1...7).map { RunningWorkEvent.toolCall(toolCallId: "t\($0)", title: "cmd \($0)") }
        let work = RunningWork.derive(from: events, turnRunning: true)
        #expect(work.runningToolCount == 7)
        #expect(work.listedTools.count == 5)
        #expect(work.listedTools.last?.title == "cmd 5")
        #expect(work.hiddenToolCount == 2)
    }

    @Test func turnStatusIsCarriedThrough() {
        #expect(RunningWork.derive(from: [], turnRunning: true).turnRunning)
        #expect(!RunningWork.derive(from: [], turnRunning: false).turnRunning)
    }

    // MARK: - Approvals

    @Test func openApprovalIsCounted() {
        let work = RunningWork.derive(from: [
            .toolCall(toolCallId: "t1", title: "rm -rf build"),
            .approvalOpened(toolCallId: "t1"),
        ], turnRunning: true)
        #expect(work.openApprovals == 1)
        #expect(!work.isEmpty)
    }

    @Test func approvalWithNoToolCallIsCounted() {
        let work = RunningWork.derive(from: [.approvalOpened(toolCallId: nil)], turnRunning: true)
        #expect(work.openApprovals == 1)
        #expect(work.runningToolCount == 0)
        #expect(!work.isEmpty)
    }

    @Test func closedApprovalIsNotCounted() {
        let work = RunningWork.derive(from: [
            .approvalOpened(toolCallId: "t1"),
            .approvalClosed(toolCallId: "t1"),
        ], turnRunning: true)
        #expect(work.openApprovals == 0)
        #expect(work.isEmpty)
    }

    @Test func twoOpenApprovalsAreBothCounted() {
        let work = RunningWork.derive(from: [
            .approvalOpened(toolCallId: "t1"),
            .approvalOpened(toolCallId: "t2"),
            .approvalClosed(toolCallId: "t1"),
        ], turnRunning: true)
        #expect(work.openApprovals == 1)
    }
}
