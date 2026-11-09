import Foundation
import XCTest
import ACP
@testable import ACPClient

/// A fake connection that records each call and answers with a fixed value or error.
private final class PromptFakeGateway: GatewayCalling, @unchecked Sendable {
    var calls: [(method: String, params: ACP.Value?)] = []
    var result: ACP.Value = .null
    var error: Error?

    func gatewayCall(method: String, params: ACP.Value?) async throws -> ACP.Value {
        calls.append((method, params))
        if let error { throw error }
        return result
    }
}

/// `_acpcode/sessions/prompt` (SPEC 6.2, D-026 and D-031 for busy): the request shape, the answer shape, and the
/// -32010 "turn already pending" mapping that the Shortcut uses to report `busy` without retrying.
final class GatewayPromptTests: XCTestCase {
    func testTheRequestNamesOnlyTheSessionAndTheTextPrompt() async throws {
        let fake = PromptFakeGateway()
        fake.result = .object(["turnId": .string("t-1"), "status": .string("accepted")])
        _ = try await GatewayClient(fake).sendPrompt(sessionId: "s-1", prompt: "Next step")
        XCTAssertEqual(fake.calls.map(\.method), ["_acpcode/sessions/prompt"])
        let params = fake.calls.first?.params
        XCTAssertEqual(params?.objectKeys, ["prompt", "sessionId"])
        XCTAssertEqual(params?["sessionId"], .string("s-1"))
        XCTAssertEqual(params?["prompt"], .array([.object(["type": .string("text"), "text": .string("Next step")])]))
    }

    func testTheTextOfThePromptIsKeptExactlyIncludingNewlinesAndUnicode() async throws {
        let fake = PromptFakeGateway()
        fake.result = .object(["turnId": .string("t-2"), "status": .string("accepted")])
        let prompt = "Line one\nLine two \u{2713} caf\u{00E9}"
        _ = try await GatewayClient(fake).sendPrompt(sessionId: "s-1", prompt: prompt)
        XCTAssertEqual(fake.calls.first?.params?["prompt"], GatewayPrompt.text(prompt))
    }

    func testTheAnswerDecodesToTheTurnIdAndStatus() async throws {
        let fake = PromptFakeGateway()
        fake.result = .object(["turnId": .string("t-9"), "status": .string("accepted")])
        let result = try await GatewayClient(fake).sendPrompt(sessionId: "s-1", prompt: "x")
        XCTAssertEqual(result, GatewayPromptResult(turnId: "t-9", status: "accepted"))
    }

    func testAnAnswerWithoutATurnIdIsNamed() async {
        let fake = PromptFakeGateway()
        fake.result = .object(["status": .string("accepted")])
        do {
            _ = try await GatewayClient(fake).sendPrompt(sessionId: "s-1", prompt: "x")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? GatewayError, .invalidResponse("turn"))
        }
    }

    func testMinus32010FromAPlainErrorIsBusy() async {
        let fake = PromptFakeGateway()
        fake.error = ACPServiceError.rpc(id: .number(3), error: .serverError(code: -32010, message: "turn pending"))
        do {
            _ = try await GatewayClient(fake).sendPrompt(sessionId: "s-1", prompt: "x")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? GatewayError, .rpc(code: -32010, message: "turn pending"))
            XCTAssertTrue((error as? GatewayError)?.isSessionBusy == true)
        }
    }

    func testMinus32010WithDataIsBusyToo() async {
        let fake = PromptFakeGateway()
        fake.error = ACPServiceError.rpcData(
            id: .number(4),
            error: .serverError(code: -32010, message: "turn pending"),
            data: .object(["sessionId": .string("s-1")])
        )
        do {
            _ = try await GatewayClient(fake).sendPrompt(sessionId: "s-1", prompt: "x")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue((error as? GatewayError)?.isSessionBusy == true)
        }
    }

    func testOnlyMinus32010CountsAsBusy() {
        for code in [-32600, -32000, -32015, -32602, -32012, 0] {
            XCTAssertFalse(GatewayError.rpc(code: code, message: "x").isSessionBusy, "code \(code)")
        }
        XCTAssertFalse(GatewayError.disconnected.isSessionBusy)
        XCTAssertFalse(GatewayError.invalidResponse("turn").isSessionBusy)
    }

    func testADroppedConnectionDuringTheSendIsNotBusy() async {
        let fake = PromptFakeGateway()
        fake.error = ACPServiceError.disconnected
        do {
            _ = try await GatewayClient(fake).sendPrompt(sessionId: "s-1", prompt: "x")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? GatewayError, .disconnected)
            XCTAssertFalse((error as? GatewayError)?.isSessionBusy == true)
        }
    }

    func testAnOtherGatewayRefusalKeepsItsCodeAndText() async {
        let fake = PromptFakeGateway()
        fake.error = ACPServiceError.rpc(id: .number(5), error: .serverError(code: -32000, message: "agent exited"))
        do {
            _ = try await GatewayClient(fake).sendPrompt(sessionId: "s-1", prompt: "x")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? GatewayError, .rpc(code: -32000, message: "agent exited"))
        }
    }
}

private extension ACP.Value {
    /// The keys of an object value, sorted; nil for anything else.
    var objectKeys: [String]? {
        guard case .object(let fields) = self else { return nil }
        return fields.keys.sorted()
    }
}
