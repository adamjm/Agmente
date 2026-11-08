import XCTest
import ACP
@testable import ACPCode
import ACPClient
import ACPCodeLiveApproval

/// A fake gateway for the Live Activity answer path. It lists open approvals and records the answers sent.
private final class FakeAnswerGateway: GatewayCalling, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(method: String, params: ACP.Value?)] = []
    var approvals: [ACP.Value] = []
    var listError: Error?
    var answerError: Error?

    var answers: [ACP.Value?] { lock.lock(); defer { lock.unlock() }; return recorded.filter { $0.method == "_acpcode/approvals/answer" }.map(\.params) }

    func gatewayCall(method: String, params: ACP.Value?) async throws -> ACP.Value {
        lock.lock(); recorded.append((method, params)); lock.unlock()
        switch method {
        case "_acpcode/approvals/pending":
            if let listError { throw listError }
            return .object(["approvals": .array(approvals)])
        case "_acpcode/approvals/answer":
            if let answerError { throw answerError }
            return .object([:])
        default:
            return .null
        }
    }
}

private func openApproval(_ id: String, options: [(id: String, kind: String)]) -> ACP.Value {
    .object([
        "approvalId": .string(id), "sessionId": .string("s1"), "projectId": .string("p1"),
        "toolCall": .object(["toolCallId": .string("c-\(id)"), "title": .string("Run tests")]),
        "options": .array(options.map { .object(["optionId": .string($0.id), "name": .string($0.kind), "kind": .string($0.kind)]) }),
        "since": .string("2026-11-06T08:08:11.638Z"),
    ])
}

@MainActor
final class ApprovalAnswerServiceTests: XCTestCase {
    private func service(_ fake: FakeAnswerGateway, closed: @escaping (String) -> Void = { _ in }) -> ApprovalAnswerService {
        let service = ApprovalAnswerService()
        service.clientProvider = { GatewayClient(fake) }
        service.onClosed = closed
        return service
    }

    func testOnceAnswersTheOpenApprovalAndReportsItClosed() async {
        let fake = FakeAnswerGateway()
        fake.approvals = [openApproval("acpcode-perm-1", options: [("proceed_once", "allow_once"), ("cancel", "reject_once")])]
        var closedIds: [String] = []
        let outcome = await service(fake) { closedIds.append($0) }
            .answer(approvalId: "acpcode-perm-1", optionId: "proceed_once", role: .once)
        XCTAssertEqual(outcome, .answered)
        XCTAssertEqual(fake.answers, [.object(["approvalId": .string("acpcode-perm-1"), "optionId": .string("proceed_once")])])
        XCTAssertEqual(closedIds, ["acpcode-perm-1"])
    }

    func testDenyAnswersARejectOnceOption() async {
        let fake = FakeAnswerGateway()
        fake.approvals = [openApproval("acpcode-perm-1", options: [("proceed_once", "allow_once"), ("cancel", "reject_once")])]
        let outcome = await service(fake).answer(approvalId: "acpcode-perm-1", optionId: "cancel", role: .deny)
        XCTAssertEqual(outcome, .answered)
        XCTAssertEqual(fake.answers.count, 1)
    }

    /// The island never sends Allow Always, even if the option id is named in an intent.
    func testAnAllowAlwaysOptionIsNeverSent() async {
        let fake = FakeAnswerGateway()
        fake.approvals = [openApproval("acpcode-perm-1", options: [("always", "allow_always")])]
        let outcome = await service(fake).answer(approvalId: "acpcode-perm-1", optionId: "always", role: .once)
        guard case .notSent = outcome else { return XCTFail("Allow Always must not be sent, got \(outcome)") }
        XCTAssertTrue(fake.answers.isEmpty)
    }

    func testAnOptionWithTheWrongRoleIsNotSent() async {
        let fake = FakeAnswerGateway()
        fake.approvals = [openApproval("acpcode-perm-1", options: [("proceed_once", "allow_once"), ("cancel", "reject_once")])]
        let outcome = await service(fake).answer(approvalId: "acpcode-perm-1", optionId: "proceed_once", role: .deny)
        guard case .notSent = outcome else { return XCTFail("A once option must not answer as a deny, got \(outcome)") }
        XCTAssertTrue(fake.answers.isEmpty)
    }

    func testAnApprovalNoLongerListedIsReportedClosed() async {
        let fake = FakeAnswerGateway()
        var closedIds: [String] = []
        let outcome = await service(fake) { closedIds.append($0) }
            .answer(approvalId: "acpcode-perm-9", optionId: "proceed_once", role: .once)
        XCTAssertEqual(outcome, .alreadyClosed)
        XCTAssertTrue(fake.answers.isEmpty)
        XCTAssertEqual(closedIds, ["acpcode-perm-9"])
    }

    func testAnswerAlreadyClosedOnTheGatewayIsReportedClosed() async {
        let fake = FakeAnswerGateway()
        fake.approvals = [openApproval("acpcode-perm-1", options: [("proceed_once", "allow_once")])]
        fake.answerError = GatewayError.rpc(code: -32001, message: "answered on another device")
        let outcome = await service(fake).answer(approvalId: "acpcode-perm-1", optionId: "proceed_once", role: .once)
        XCTAssertEqual(outcome, .alreadyClosed)
    }

    func testAListFailureIsNotSentAndKeepsTheApproval() async {
        let fake = FakeAnswerGateway()
        fake.listError = GatewayError.disconnected
        var closedIds: [String] = []
        let outcome = await service(fake) { closedIds.append($0) }
            .answer(approvalId: "acpcode-perm-1", optionId: "proceed_once", role: .once)
        guard case .notSent = outcome else { return XCTFail("expected notSent, got \(outcome)") }
        XCTAssertTrue(closedIds.isEmpty)
    }

    func testNoConnectedGatewayIsNotSent() async {
        let service = ApprovalAnswerService()
        service.clientProvider = { nil }
        let outcome = await service.answer(approvalId: "acpcode-perm-1", optionId: "proceed_once", role: .once)
        guard case .notSent = outcome else { return XCTFail("expected notSent, got \(outcome)") }
    }
}
