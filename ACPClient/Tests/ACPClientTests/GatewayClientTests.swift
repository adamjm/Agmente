import XCTest
import ACP
@testable import ACPClient

private final class FakeGateway: GatewayCalling, @unchecked Sendable {
    var calls: [(method: String, params: ACP.Value?)] = []
    var results: [String: ACP.Value] = [:]
    var error: Error?

    func gatewayCall(method: String, params: ACP.Value?) async throws -> ACP.Value {
        calls.append((method, params))
        if let error { throw error }
        return results[method] ?? .null
    }
}

final class GatewayClientTests: XCTestCase {
    func testInitializeResultCarriesGatewayInfoFromMeta() {
        let result: ACP.Value = .object([
            "protocolVersion": .number(1),
            "agentInfo": .object(["name": .string("bob"), "version": .string("2.0.9")]),
            "_meta": .object(["agmente/gateway": .object([
                "version": .string("0.3.0-dev"),
                "extensions": .array([.string("projects"), .string("sessions"), .string("git")]),
            ])]),
        ])
        let gateway = ACPInitializeParser.parse(result: result)?.gateway
        XCTAssertEqual(gateway, GatewayInfo(version: "0.3.0-dev", extensions: ["projects", "sessions", "git"]))
        XCTAssertEqual(gateway?.supports("git"), true)
        XCTAssertEqual(gateway?.supports("approvals"), false)
    }

    func testAServerWithoutTheGatewayKeyHasNoGatewayInfo() {
        for meta: ACP.Value? in [nil, .object([:]), .object(["agmente/gateway": .null]), .object(["agmente/gateway": .object(["extensions": .array([])])]), .object(["bob/extensions": .object(["version": .number(1)])])] {
            var object: [String: ACP.Value] = ["protocolVersion": .number(1), "agentInfo": .object(["name": .string("x")])]
            if let meta { object["_meta"] = meta }
            XCTAssertNil(ACPInitializeParser.parse(result: .object(object))?.gateway, "\(String(describing: meta))")
        }
    }

    func testProjectsDecodeAndSendTheMethodWithNoParams() async throws {
        let fake = FakeGateway()
        fake.results["_agmente/projects/list"] = .object(["projects": .array([
            .object(["id": .string("a1"), "name": .string("Site"), "path": .string("/srv/site"), "defaultMode": .string("plan")]),
            .object(["id": .string("b2"), "name": .string("API"), "path": .string("/srv/api"), "defaultMode": .null]),
        ])])
        let projects = try await GatewayClient(fake).projects()
        XCTAssertEqual(projects, [GatewayProject(id: "a1", name: "Site", path: "/srv/site", defaultMode: "plan"), GatewayProject(id: "b2", name: "API", path: "/srv/api", defaultMode: nil)])
        XCTAssertEqual(fake.calls.map(\.method), ["_agmente/projects/list"])
    }

    func testSessionsDecodeEveryStatusAndAnUnknownOneAndFilterByProject() async throws {
        let fake = FakeGateway()
        func row(_ id: String, _ status: String) -> ACP.Value {
            .object(["sessionId": .string(id), "projectId": .string("a1"), "title": id == "s1" ? .null : .string("Fix \(id)"),
                     "status": .string(status), "lastActivity": .string("2026-11-06T08:08:11.638Z"), "headSeq": .number(12), "unread": .number(2)])
        }
        fake.results["_agmente/sessions/index"] = .object(["sessions": .array([row("s1", "idle"), row("s2", "running"), row("s3", "awaiting_approval"), row("s4", "error"), row("s5", "paused")])])
        let sessions = try await GatewayClient(fake).sessions(projectId: "a1")
        XCTAssertEqual(sessions.map(\.status), [.idle, .running, .awaitingApproval, .error, .unknown("paused")])
        XCTAssertEqual(sessions[0].title, nil)
        XCTAssertEqual(sessions[1].title, "Fix s2")
        XCTAssertEqual(sessions[1].headSeq, 12)
        XCTAssertEqual(sessions[1].unread, 2)
        XCTAssertEqual(sessions[0].lastActivityDate, Date(timeIntervalSince1970: 1_793_952_491.638), "the gateway's millisecond ISO format parses")
        XCTAssertEqual(fake.calls.first?.params, .object(["projectId": .string("a1")]))
        _ = try await GatewayClient(fake).sessions()
        XCTAssertEqual(fake.calls.last?.params, .object([:]), "no projectId means all projects")
    }

    func testErrorsAreMappedAndAnOddAnswerIsNamed() async {
        let fake = FakeGateway()
        fake.error = ACPServiceError.rpc(id: .number(1), error: .invalidParams("unknown project"))
        do {
            _ = try await GatewayClient(fake).sessions(projectId: "nope")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? GatewayError, .rpc(code: -32602, message: "unknown project"))
            XCTAssertEqual((error as? GatewayError)?.message, "unknown project")
        }
        fake.error = ACPServiceError.disconnected
        do {
            _ = try await GatewayClient(fake).projects()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? GatewayError, .disconnected)
        }
        fake.error = nil
        fake.results["_agmente/projects/list"] = .object(["projects": .string("not a list")])
        do {
            _ = try await GatewayClient(fake).projects()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? GatewayError, .invalidResponse("projects"))
        }
    }
}

final class GatewayEventTests: XCTestCase {
    private func event(_ seq: Int, _ message: ACP.Value, session: String = "s1") -> ACP.Value {
        .object(["sessionId": .string(session), "seq": .int(seq), "message": message])
    }

    func testParseNeedsASessionAPositiveSeqAndAMessageObject() {
        let ok = GatewayEvent.parse(event(3, .object(["method": .string("session/update")])))
        XCTAssertEqual(ok?.sessionId, "s1")
        XCTAssertEqual(ok?.seq, 3)
        XCTAssertNil(GatewayEvent.parse(nil))
        XCTAssertNil(GatewayEvent.parse(.object(["seq": .int(1), "message": .object([:])])), "no session")
        XCTAssertNil(GatewayEvent.parse(.object(["sessionId": .string("s"), "message": .object([:])])), "no seq")
        XCTAssertNil(GatewayEvent.parse(event(0, .object([:]))), "seq starts at 1")
        XCTAssertNil(GatewayEvent.parse(event(1, .string("text"))), "the message must be an object")
    }

    func testSessionUpdateKeepsItsParamsUnchanged() {
        let params: ACP.Value = .object(["sessionId": .string("s1"), "update": .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("hi")])])])
        let parsed = GatewayEvent.parse(event(2, .object(["jsonrpc": .string("2.0"), "method": .string("session/update"), "params": params])))
        XCTAssertEqual(parsed?.action, .sessionUpdate(params))
    }

    func testTurnStartedBecomesOneUserMessageChunkPerPromptBlock() {
        let blocks: [ACP.Value] = [.object(["type": .string("text"), "text": .string("fix it")]), .object(["type": .string("image"), "data": .string("AAAA"), "mimeType": .string("image/png")])]
        let parsed = GatewayEvent.parse(event(1, .object(["method": .string("_agmente/turn_started"), "params": .object(["sessionId": .string("s1"), "prompt": .array(blocks)])])))
        guard case .userPrompt(let updates)? = parsed?.action else { return XCTFail("\(String(describing: parsed?.action))") }
        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates[0], .object(["sessionId": .string("s1"), "update": .object(["sessionUpdate": .string("user_message_chunk"), "content": blocks[0]])]))
        XCTAssertEqual(updates[1]["update"]?["content"], blocks[1])
        let empty = GatewayEvent.parse(event(1, .object(["method": .string("_agmente/turn_started"), "params": .object(["sessionId": .string("s1")])])))
        XCTAssertEqual(empty?.action, .userPrompt([]))
    }

    func testAPermissionRequestKeepsTheGatewayIdForTheAnswer() {
        let params: ACP.Value = .object(["sessionId": .string("s1"), "toolCall": .object(["toolCallId": .string("c1")]), "options": .array([])])
        let parsed = GatewayEvent.parse(event(4, .object(["jsonrpc": .string("2.0"), "id": .string("agmente-perm-7"), "method": .string("session/request_permission"), "params": params])))
        guard case .permissionRequest(let request)? = parsed?.action else { return XCTFail() }
        XCTAssertEqual(request.id, .string("agmente-perm-7"))
        XCTAssertEqual(request.method, "session/request_permission")
        XCTAssertEqual(request.params, params)
        let noId = GatewayEvent.parse(event(4, .object(["method": .string("session/request_permission"), "params": params])))
        XCTAssertEqual(noId?.action, .other(method: "session/request_permission"), "a permission request with no id cannot be answered")
    }

    func testTurnEndedCarriesTheStopReasonOrTheError() {
        func action(_ params: ACP.Value) -> GatewayEventAction? {
            GatewayEvent.parse(event(9, .object(["method": .string("_agmente/turn_ended"), "params": params])))?.action
        }
        XCTAssertEqual(action(.object(["sessionId": .string("s1"), "stopReason": .string("end_turn")])), .turnEnded(stopReason: "end_turn", error: nil))
        XCTAssertEqual(action(.object(["sessionId": .string("s1"), "error": .object(["code": .int(-32000), "message": .string("agent exited")])])), .turnEnded(stopReason: nil, error: "agent exited"))
    }

    func testApprovalAnsweredAndUnknownMethods() {
        let answered = GatewayEvent.parse(event(5, .object(["method": .string("_agmente/approval_answered"), "params": .object(["sessionId": .string("s1"), "approvalId": .string("agmente-perm-7"), "answeredBy": .string("owner/phone"), "outcome": .object([:])])])))
        XCTAssertEqual(answered?.action, .approvalAnswered(approvalId: "agmente-perm-7"))
        XCTAssertEqual(GatewayEvent.parse(event(6, .object(["method": .string("_agmente/future_thing")])))?.action, .other(method: "_agmente/future_thing"))
    }

    func testSequenceAppliesInOrderDropsRepeatsAndReportsGaps() {
        var seq = GatewaySequence()
        XCTAssertEqual(seq.accept(1), .apply)
        XCTAssertEqual(seq.accept(2), .apply)
        XCTAssertEqual(seq.accept(2), .duplicate, "a repeat after a resubscribe")
        XCTAssertEqual(seq.accept(1), .duplicate)
        XCTAssertEqual(seq.accept(5), .gap(expected: 3))
        XCTAssertEqual(seq.lastSeq, 2, "a gap does not move the position")
        XCTAssertEqual(seq.accept(3), .apply)
        var resumed = GatewaySequence(lastSeq: 10)
        XCTAssertEqual(resumed.accept(11), .apply)
        resumed.reset()
        XCTAssertEqual(resumed.lastSeq, 0)
    }

    func testSubscribeAndMarkReadSendTheDocumentedParams() async throws {
        let fake = FakeGateway()
        fake.results["_agmente/sessions/subscribe"] = .object(["headSeq": .int(42)])
        fake.results["_agmente/sessions/read"] = .object(["lastSeenSeq": .int(40)])
        let client = GatewayClient(fake)
        let head = try await client.subscribe(sessionId: "s1", afterSeq: 17)
        XCTAssertEqual(head, 42)
        XCTAssertEqual(fake.calls.last?.params, .object(["sessionId": .string("s1"), "afterSeq": .int(17)]))
        let seen = try await client.markRead(sessionId: "s1", seq: 41)
        XCTAssertEqual(seen, 40)
        XCTAssertEqual(fake.calls.last?.params, .object(["sessionId": .string("s1"), "seq": .int(41)]))
        fake.results["_agmente/sessions/subscribe"] = .object([:])
        do {
            _ = try await client.subscribe(sessionId: "s1", afterSeq: 0)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? GatewayError, .invalidResponse("headSeq"))
        }
    }
}

final class GatewayApprovalTests: XCTestCase {
    private func approval(_ id: String, session: String = "s1", input: ACP.Value? = nil) -> ACP.Value {
        var toolCall: [String: ACP.Value] = ["toolCallId": .string("call-\(id)"), "title": .string("Run echo"), "kind": .string("execute")]
        if let input { toolCall["rawInput"] = input }
        return .object([
            "approvalId": .string(id), "sessionId": .string(session), "projectId": .string("p1"),
            "toolCall": .object(toolCall),
            "options": .array([
                .object(["optionId": .string("proceed_once"), "name": .string("Allow once"), "kind": .string("allow_once")]),
                .object(["optionId": .string("cancel"), "name": .string("Reject"), "kind": .string("reject_once")]),
            ]),
            "since": .string("2026-11-06T08:08:11.638Z"),
        ])
    }

    func testPendingApprovalsDecodeWithTheirToolCallAndOptions() async throws {
        let fake = FakeGateway()
        fake.results["_agmente/approvals/pending"] = .object(["approvals": .array([
            approval("agmente-perm-1", input: .object(["command": .string("rm -rf build")])),
            approval("agmente-perm-2", session: "s2", input: .string("plain text input")),
            approval("agmente-perm-3"),
        ])])
        let list = try await GatewayClient(fake).pendingApprovals()
        XCTAssertEqual(list.map(\.approvalId), ["agmente-perm-1", "agmente-perm-2", "agmente-perm-3"])
        XCTAssertEqual(list[0].title, "Run echo")
        XCTAssertEqual(list[0].kind, "execute")
        XCTAssertEqual(list[0].detail, "rm -rf build")
        XCTAssertEqual(list[1].detail, "plain text input")
        XCTAssertNil(list[2].detail)
        XCTAssertEqual(list[1].sessionId, "s2")
        XCTAssertEqual(list[0].options.map(\.optionId), ["proceed_once", "cancel"])
        XCTAssertEqual(list[0].options.map(\.isAllow), [true, false])
        XCTAssertEqual(list[0].sinceDate, Date(timeIntervalSince1970: 1_793_952_491.638))
        XCTAssertEqual(fake.calls.last?.method, "_agmente/approvals/pending")
    }

    func testAToolCallWithNoTitleStillShows() {
        let value: ACP.Value = .object(["approvalId": .string("a"), "sessionId": .string("s"), "projectId": .string("p"), "toolCall": .object([:]), "options": .array([]), "since": .string("x")])
        let decoded = try? value.decoded(as: GatewayApproval.self)
        XCTAssertEqual(decoded?.title, "Tool call")
        XCTAssertNil(decoded?.sinceDate)
    }

    func testAnswerAndCancelSendTheDocumentedParams() async throws {
        let fake = FakeGateway()
        fake.results["_agmente/approvals/answer"] = .object([:])
        let client = GatewayClient(fake)
        try await client.answerApproval(approvalId: "agmente-perm-1", optionId: "proceed_once")
        XCTAssertEqual(fake.calls.last?.params, .object(["approvalId": .string("agmente-perm-1"), "optionId": .string("proceed_once")]))
        try await client.cancelApproval(approvalId: "agmente-perm-2")
        XCTAssertEqual(fake.calls.last?.params, .object(["approvalId": .string("agmente-perm-2"), "cancelled": .bool(true)]))
    }

    func testAnswerElsewhereIsRecognisedAndOtherErrorsAreNot() async {
        let fake = FakeGateway()
        fake.error = ACPServiceError.rpc(id: .number(1), error: .serverError(code: -32001, message: "answered elsewhere"))
        do {
            try await GatewayClient(fake).answerApproval(approvalId: "a", optionId: "o")
            XCTFail("expected an error")
        } catch {
            let gateway = error as? GatewayError
            XCTAssertEqual(gateway, .rpc(code: -32001, message: "answered elsewhere"))
            XCTAssertEqual(gateway?.isAlreadyClosed, true)
        }
        fake.error = ACPServiceError.rpc(id: .number(1), error: .invalidParams("unknown approval"))
        do {
            try await GatewayClient(fake).answerApproval(approvalId: "a", optionId: "o")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? GatewayError)?.isAlreadyClosed, false)
        }
        XCTAssertFalse(GatewayError.disconnected.isAlreadyClosed)
    }
}
