import XCTest
import ACP
@testable import ACPCode
import ACPClient

private final class FakeApprovals: GatewayCalling, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(method: String, params: ACP.Value?)] = []
    var approvals: [ACP.Value] = []
    var answerError: Error?
    var listError: Error?
    var answerDelay: UInt64 = 0

    var calls: [(method: String, params: ACP.Value?)] { lock.lock(); defer { lock.unlock() }; return recorded }
    func calls(_ method: String) -> [ACP.Value?] { calls.filter { $0.method == method }.map(\.params) }

    func gatewayCall(method: String, params: ACP.Value?) async throws -> ACP.Value {
        lock.lock(); recorded.append((method, params)); lock.unlock()
        switch method {
        case "_acpcode/approvals/pending":
            if let listError { throw listError }
            return .object(["approvals": .array(approvals)])
        case "_acpcode/approvals/answer":
            if answerDelay > 0 { try await Task.sleep(nanoseconds: answerDelay) }
            if let answerError { throw answerError }
            return .object([:])
        default:
            return .null
        }
    }
}

private func approvalValue(_ id: String, session: String = "s1") -> ACP.Value {
    .object([
        "approvalId": .string(id), "sessionId": .string(session), "projectId": .string("p1"),
        "toolCall": .object(["toolCallId": .string("c-\(id)"), "title": .string("Run tests"), "kind": .string("execute"), "rawInput": .object(["command": .string("npm test")])]),
        "options": .array([
            .object(["optionId": .string("proceed_once"), "name": .string("Allow once"), "kind": .string("allow_once")]),
            .object(["optionId": .string("cancel"), "name": .string("Reject"), "kind": .string("reject_once")]),
        ]),
        "since": .string("2026-11-06T08:08:11.638Z"),
    ])
}

@MainActor
final class ApprovalsInboxModelTests: XCTestCase {
    private func model(_ fake: FakeApprovals) -> ApprovalsInboxModel {
        let model = ApprovalsInboxModel()
        model.configure { GatewayClient(fake) }
        return model
    }

    func testRefreshLoadsTheOpenApprovalsAndCountsThem() async {
        let fake = FakeApprovals()
        fake.approvals = [approvalValue("acpcode-perm-1"), approvalValue("acpcode-perm-2")]
        let inbox = model(fake)
        XCTAssertEqual(inbox.count, 0)
        await inbox.refresh()
        XCTAssertEqual(inbox.approvals.map(\.approvalId), ["acpcode-perm-1", "acpcode-perm-2"])
        XCTAssertEqual(inbox.count, 2)
        XCTAssertNil(inbox.errorMessage)
        XCTAssertFalse(inbox.isLoading)
    }

    func testAnsweringSendsTheChosenOptionAndRemovesTheApproval() async throws {
        let fake = FakeApprovals()
        fake.approvals = [approvalValue("acpcode-perm-1"), approvalValue("acpcode-perm-2")]
        let inbox = model(fake)
        await inbox.refresh()
        let first = try XCTUnwrap(inbox.approvals.first)
        await inbox.answer(first, option: try XCTUnwrap(first.options.first))
        XCTAssertEqual(fake.calls("_acpcode/approvals/answer"), [.object(["approvalId": .string("acpcode-perm-1"), "optionId": .string("proceed_once")])])
        XCTAssertEqual(inbox.approvals.map(\.approvalId), ["acpcode-perm-2"])
        XCTAssertNil(inbox.notice)
        XCTAssertTrue(inbox.answering.isEmpty)
    }

    func testNothingIsAnsweredUntilAPersonChooses() async {
        let fake = FakeApprovals()
        fake.approvals = [approvalValue("acpcode-perm-1")]
        let inbox = model(fake)
        await inbox.refresh()
        await inbox.refresh()
        XCTAssertTrue(fake.calls("_acpcode/approvals/answer").isEmpty, "loading and refreshing never answer (D-009)")
    }

    func testCancelSendsCancelled() async throws {
        let fake = FakeApprovals()
        fake.approvals = [approvalValue("acpcode-perm-1")]
        let inbox = model(fake)
        await inbox.refresh()
        await inbox.cancel(try XCTUnwrap(inbox.approvals.first))
        XCTAssertEqual(fake.calls("_acpcode/approvals/answer"), [.object(["approvalId": .string("acpcode-perm-1"), "cancelled": .bool(true)])])
        XCTAssertTrue(inbox.approvals.isEmpty)
    }

    func testAnApprovalClosedElsewhereIsRemovedWithTheReason() async throws {
        let fake = FakeApprovals()
        fake.approvals = [approvalValue("acpcode-perm-1")]
        fake.answerError = ACPServiceError.rpc(id: .number(1), error: .serverError(code: -32001, message: "answered elsewhere"))
        let inbox = model(fake)
        await inbox.refresh()
        let approval = try XCTUnwrap(inbox.approvals.first)
        await inbox.answer(approval, option: approval.options[0])
        XCTAssertTrue(inbox.approvals.isEmpty)
        XCTAssertEqual(inbox.notice, "Already closed: answered elsewhere")
        XCTAssertNil(inbox.errorMessage)
        inbox.clearNotice()
        XCTAssertNil(inbox.notice)
    }

    func testAnotherFailureKeepsTheRowAndAllowsARetry() async throws {
        let fake = FakeApprovals()
        fake.approvals = [approvalValue("acpcode-perm-1")]
        fake.answerError = ACPServiceError.disconnected
        let inbox = model(fake)
        await inbox.refresh()
        let approval = try XCTUnwrap(inbox.approvals.first)
        await inbox.answer(approval, option: approval.options[0])
        XCTAssertEqual(inbox.approvals.count, 1, "the approval is still open")
        XCTAssertEqual(inbox.errorMessage, "Not connected")
        XCTAssertTrue(inbox.answering.isEmpty, "the row can be tried again")
        fake.answerError = nil
        await inbox.answer(approval, option: approval.options[0])
        XCTAssertTrue(inbox.approvals.isEmpty)
        XCTAssertNil(inbox.errorMessage)
        XCTAssertEqual(fake.calls("_acpcode/approvals/answer").count, 2)
    }

    func testASecondTapWhileTheAnswerIsOnItsWayIsIgnored() async throws {
        let fake = FakeApprovals()
        fake.approvals = [approvalValue("acpcode-perm-1")]
        fake.answerDelay = 150_000_000
        let inbox = model(fake)
        await inbox.refresh()
        let approval = try XCTUnwrap(inbox.approvals.first)
        async let first: Void = inbox.answer(approval, option: approval.options[0])
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(inbox.answering.contains("acpcode-perm-1"))
        await inbox.answer(approval, option: approval.options[1])
        await first
        XCTAssertEqual(fake.calls("_acpcode/approvals/answer").count, 1, "one answer, the first")
    }

    func testAnApprovalAnsweredEventRemovesTheRow() async {
        let fake = FakeApprovals()
        fake.approvals = [approvalValue("acpcode-perm-1"), approvalValue("acpcode-perm-2")]
        let inbox = model(fake)
        await inbox.refresh()
        inbox.closed(approvalId: "acpcode-perm-1")
        XCTAssertEqual(inbox.approvals.map(\.approvalId), ["acpcode-perm-2"])
        inbox.closed(approvalId: "acpcode-perm-9") // unknown: nothing happens
        XCTAssertEqual(inbox.count, 1)
    }

    func testAFailedRefreshKeepsTheListAndSaysWhy() async {
        let fake = FakeApprovals()
        fake.approvals = [approvalValue("acpcode-perm-1")]
        let inbox = model(fake)
        await inbox.refresh()
        fake.listError = ACPServiceError.disconnected
        await inbox.refresh()
        XCTAssertEqual(inbox.count, 1)
        XCTAssertEqual(inbox.errorMessage, "Not connected")
        fake.listError = nil
        await inbox.refresh()
        XCTAssertNil(inbox.errorMessage)
    }

    func testReconfiguringDropsTheOldListAndIgnoresALateAnswer() async throws {
        let slow = FakeApprovals()
        slow.approvals = [approvalValue("acpcode-perm-1")]
        slow.answerDelay = 150_000_000
        let inbox = model(slow)
        await inbox.refresh()
        let approval = try XCTUnwrap(inbox.approvals.first)
        let pending = Task { await inbox.answer(approval, option: approval.options[0]) }
        try await Task.sleep(nanoseconds: 30_000_000)
        // Another gateway, whose own approval has the same id (ids are per gateway).
        let other = FakeApprovals()
        other.approvals = [approvalValue("acpcode-perm-1")]
        inbox.configure { GatewayClient(other) }
        XCTAssertTrue(inbox.approvals.isEmpty)
        await inbox.refresh()
        XCTAssertEqual(inbox.approvals.map(\.approvalId), ["acpcode-perm-1"])
        await pending.value
        XCTAssertEqual(inbox.approvals.map(\.approvalId), ["acpcode-perm-1"], "the old server's late answer did not remove the new server's approval")
        XCTAssertNil(inbox.notice)
        XCTAssertEqual(other.calls("_acpcode/approvals/answer").count, 0)
    }

    func testWithNoClientNothingHappens() async {
        let inbox = ApprovalsInboxModel()
        inbox.configure(clientProvider: nil)
        await inbox.refresh()
        XCTAssertEqual(inbox.count, 0)
        XCTAssertNil(inbox.errorMessage)
    }
}
