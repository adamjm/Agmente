import XCTest
@testable import ACPCodeLiveApproval

/// The answer handler is process-wide, so these tests run one at a time and clear it afterwards.
final class ApprovalIntentTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(String, String, ApprovalOptionRole)] = []
        func record(_ approvalId: String, _ optionId: String, _ role: ApprovalOptionRole) {
            lock.lock(); calls.append((approvalId, optionId, role)); lock.unlock()
        }
        var all: [(String, String, ApprovalOptionRole)] { lock.lock(); defer { lock.unlock() }; return calls }
    }

    override func tearDown() {
        ApprovalAnswerRouter.handler = nil
        super.tearDown()
    }

    func testApproveOnceRequiresAuthentication() {
        guard case .requiresAuthentication = ApproveOnceIntent.authenticationPolicy else {
            return XCTFail("Once must need an unlocked phone")
        }
    }

    func testDenyRequiresAuthentication() {
        guard case .requiresAuthentication = DenyApprovalIntent.authenticationPolicy else {
            return XCTFail("Deny must need an unlocked phone")
        }
    }

    func testApproveOnceAnswersWithItsIdAndTheOnceRole() async throws {
        let recorder = Recorder()
        ApprovalAnswerRouter.handler = { approvalId, optionId, role in
            recorder.record(approvalId, optionId, role)
            return true
        }
        _ = try await ApproveOnceIntent(approvalId: "acpcode-perm-7", optionId: "proceed_once").perform()
        XCTAssertEqual(recorder.all.map { $0.0 }, ["acpcode-perm-7"])
        XCTAssertEqual(recorder.all.map { $0.1 }, ["proceed_once"])
        XCTAssertEqual(recorder.all.map { $0.2 }, [.once])
    }

    func testDenyAnswersWithItsIdAndTheDenyRole() async throws {
        let recorder = Recorder()
        ApprovalAnswerRouter.handler = { approvalId, optionId, role in
            recorder.record(approvalId, optionId, role)
            return true
        }
        _ = try await DenyApprovalIntent(approvalId: "acpcode-perm-7", optionId: "cancel").perform()
        XCTAssertEqual(recorder.all.map { $0.2 }, [.deny])
        XCTAssertEqual(recorder.all.map { $0.1 }, ["cancel"])
    }

    func testIntentWithoutAHandlerThrowsInsteadOfReportingSuccess() async {
        ApprovalAnswerRouter.handler = nil
        do {
            _ = try await ApproveOnceIntent(approvalId: "a", optionId: "o").perform()
            XCTFail("an answer that was not delivered must not report success")
        } catch let error as ApprovalAnswerError {
            XCTAssertEqual(error, .appNotReady)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        do {
            _ = try await DenyApprovalIntent(approvalId: "a", optionId: "o").perform()
            XCTFail("an answer that was not delivered must not report success")
        } catch let error as ApprovalAnswerError {
            XCTAssertEqual(error, .appNotReady)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testARefusedAnswerThrows() async {
        ApprovalAnswerRouter.handler = { _, _, _ in false }
        do {
            _ = try await ApproveOnceIntent(approvalId: "a", optionId: "o").perform()
            XCTFail("a refused answer must not report success")
        } catch let error as ApprovalAnswerError {
            XCTAssertEqual(error, .notSent)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
