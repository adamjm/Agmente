import XCTest
import ACP
@testable import ACPClient

private final class SessionsFakeGateway: GatewayCalling, @unchecked Sendable {
    var calls: [(method: String, params: ACP.Value?)] = []
    var results: [String: ACP.Value] = [:]
    var error: Error?

    func gatewayCall(method: String, params: ACP.Value?) async throws -> ACP.Value {
        calls.append((method, params))
        if let error { throw error }
        return results[method] ?? .null
    }
}

final class GatewaySessionsEncodingTests: XCTestCase {
    func testCreateSendsCwdAndATextPromptAndNothingElseByDefault() async throws {
        let fake = SessionsFakeGateway()
        fake.results["_acpcode/sessions/create"] = .object([
            "sessionId": .string("s-1"), "turnId": .string("t-1"), "status": .string("accepted"),
        ])
        let result = try await GatewayClient(fake).createSession(cwd: "/srv/site", prompt: "Fix the build")
        XCTAssertEqual(result, GatewaySessionCreateResult(sessionId: "s-1", turnId: "t-1", status: "accepted"))
        XCTAssertEqual(fake.calls.map(\.method), ["_acpcode/sessions/create"])
        XCTAssertEqual(fake.calls.first?.params, .object([
            "cwd": .string("/srv/site"),
            "prompt": .array([.object(["type": .string("text"), "text": .string("Fix the build")])]),
        ]))
    }

    func testCreateSendsMcpServersAndMetaWhenGiven() async throws {
        let fake = SessionsFakeGateway()
        fake.results["_acpcode/sessions/create"] = .object([
            "sessionId": .string("s-2"), "turnId": .string("t-2"), "status": .string("accepted"),
        ])
        let server: ACP.Value = .object(["type": .string("http"), "name": .string("docs"), "url": .string("https://example.com/mcp")])
        _ = try await GatewayClient(fake).createSession(cwd: "/srv/site", prompt: "x", mcpServers: [server], meta: ["bob/mode": .string("plan")])
        XCTAssertEqual(fake.calls.first?.params?["mcpServers"], .array([server]))
        XCTAssertEqual(fake.calls.first?.params?["_meta"], .object(["bob/mode": .string("plan")]))
    }

    func testAnEmptyMetaIsLeftOut() async throws {
        let fake = SessionsFakeGateway()
        fake.results["_acpcode/sessions/create"] = .object([
            "sessionId": .string("s-3"), "turnId": .string("t-3"), "status": .string("accepted"),
        ])
        _ = try await GatewayClient(fake).createSession(cwd: "/srv/site", prompt: "x", meta: [:])
        XCTAssertNil(fake.calls.first?.params?["_meta"])
    }

    func testSendPromptEncodesTheSessionAndDecodesTheTurn() async throws {
        let fake = SessionsFakeGateway()
        fake.results["_acpcode/sessions/prompt"] = .object(["turnId": .string("t-9"), "status": .string("accepted")])
        let result = try await GatewayClient(fake).sendPrompt(sessionId: "s-1", prompt: "Next step")
        XCTAssertEqual(result, GatewayPromptResult(turnId: "t-9", status: "accepted"))
        XCTAssertEqual(fake.calls.first?.params, .object([
            "sessionId": .string("s-1"),
            "prompt": .array([.object(["type": .string("text"), "text": .string("Next step")])]),
        ]))
    }

    func testAnAnswerWithoutATurnIdIsNamed() async {
        let fake = SessionsFakeGateway()
        fake.results["_acpcode/sessions/create"] = .object(["sessionId": .string("s-1")])
        do {
            _ = try await GatewayClient(fake).createSession(cwd: "/srv", prompt: "x")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? GatewayError, .invalidResponse("session"))
        }
    }
}

final class GatewaySessionsErrorTests: XCTestCase {
    private func failing(_ error: ACPServiceError) -> SessionsFakeGateway {
        let fake = SessionsFakeGateway()
        fake.error = error
        return fake
    }

    func testPromptNotSentKeepsTheSessionId() async {
        let data: ACP.Value = .object(["sessionId": .string("s-7"), "promptSent": .bool(false)])
        let fake = failing(.rpcData(id: .number(1), error: .serverError(code: -32015, message: "prompt not sent"), data: data))
        do {
            _ = try await GatewayClient(fake).createSession(cwd: "/srv", prompt: "x")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? GatewayError, .sessionCreatedPromptNotSent(sessionId: "s-7", message: "prompt not sent"))
            XCTAssertEqual((error as? GatewayError)?.message, "prompt not sent")
        }
    }

    func testMinus32015WithoutTheDocumentedDataStaysAPlainRPCError() async {
        // No session id, or promptSent is not false: the caller must not report a session that may not exist.
        let cases: [ACP.Value] = [
            .object(["promptSent": .bool(false)]),
            .object(["sessionId": .string("s-7"), "promptSent": .bool(true)]),
            .object(["sessionId": .string("s-7")]),
        ]
        for data in cases {
            let fake = failing(.rpcData(id: .number(1), error: .serverError(code: -32015, message: "x"), data: data))
            do {
                _ = try await GatewayClient(fake).createSession(cwd: "/srv", prompt: "x")
                XCTFail("expected an error for \(data)")
            } catch {
                XCTAssertEqual(error as? GatewayError, .rpc(code: -32015, message: "x"), "\(data)")
            }
        }
    }

    func testRefusalsKeepTheirCodeAndTheGatewayText() async {
        let refusals: [(ACPError, Int, String)] = [
            (.invalidParams("That folder is not an approved project."), -32602, "That folder is not an approved project."),
            (.serverError(code: -32012, message: "no such project"), -32012, "no such project"),
            (.serverError(code: -32000, message: "agent capacity reached"), -32000, "agent capacity reached"),
        ]
        for (error, code, text) in refusals {
            let fake = failing(.rpc(id: .number(2), error: error))
            do {
                _ = try await GatewayClient(fake).createSession(cwd: "/srv", prompt: "x")
                XCTFail("expected an error")
            } catch {
                XCTAssertEqual(error as? GatewayError, .rpc(code: code, message: text))
            }
        }
    }

    func testBusyPromptIsRecognised() async {
        let fake = failing(.rpc(id: .number(3), error: .serverError(code: -32010, message: "session is busy")))
        do {
            _ = try await GatewayClient(fake).sendPrompt(sessionId: "s-1", prompt: "x")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? GatewayError, .rpc(code: -32010, message: "session is busy"))
            XCTAssertTrue((error as? GatewayError)?.isSessionBusy == true)
        }
        XCTAssertFalse(GatewayError.rpc(code: -32602, message: "x").isSessionBusy)
    }

    func testDisconnectDuringCreateIsReported() async {
        let fake = failing(.disconnected)
        do {
            _ = try await GatewayClient(fake).createSession(cwd: "/srv", prompt: "x")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? GatewayError, .disconnected)
        }
    }
}

final class ACPRawErrorDataTests: XCTestCase {
    func testTheDataOfAnErrorResponseIsRead() {
        let raw = Data(#"{"jsonrpc":"2.0","id":4,"error":{"code":-32015,"message":"prompt not sent","data":{"sessionId":"s-7","promptSent":false}}}"#.utf8)
        XCTAssertEqual(ACPRawErrorData.read(from: raw), .object(["sessionId": .string("s-7"), "promptSent": .bool(false)]))
    }

    func testAnErrorWithoutDataReadsNil() {
        let raw = Data(#"{"jsonrpc":"2.0","id":4,"error":{"code":-32602,"message":"bad"}}"#.utf8)
        XCTAssertNil(ACPRawErrorData.read(from: raw))
    }

    func testAResultReadsNil() {
        let raw = Data(#"{"jsonrpc":"2.0","id":4,"result":{"turnId":"t"}}"#.utf8)
        XCTAssertNil(ACPRawErrorData.read(from: raw))
    }

    func testRpcDataCarriesTheCodeAndMessageOfTheError() {
        let error = ACPServiceError.rpcData(id: .number(1), error: .serverError(code: -32015, message: "nope"), data: .null)
        XCTAssertEqual(error.rpcCode, -32015)
        XCTAssertEqual(error.rpcMessage, "nope")
    }

    func testAPromptIsNotLoggedWhenTheMessageIsSent() {
        let secret = "launch-code-4417-keep-private"
        let create = #"{"jsonrpc":"2.0","id":3,"method":"_acpcode/sessions/create","params":{"cwd":"/srv","prompt":[{"type":"text","text":"\#(secret)"}]}}"#
        let prompt = #"{"jsonrpc":"2.0","id":4,"method":"_acpcode\/sessions\/prompt","params":{"sessionId":"s","prompt":[{"type":"text","text":"\#(secret)"}]}}"#
        XCTAssertFalse(ACPLogRedaction.redactedForLog(create).contains(secret))
        XCTAssertFalse(ACPLogRedaction.redactedForLog(prompt).contains(secret))
        XCTAssertTrue(ACPLogRedaction.redactedForLog(create).contains("_acpcode/sessions/create"))
    }

    func testThePromptBuilderSendsOneTextBlock() {
        XCTAssertEqual(GatewayPrompt.text("hi"), .array([.object(["type": .string("text"), "text": .string("hi")])]))
    }
}
