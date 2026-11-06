import XCTest
import ACP
@testable import ACPClient

/// FR-33 to FR-36 on the wire: plan, title and usage parsing, the delete capability, `_meta` on
/// session/new, the session/delete params and the auth error text.
final class SessionMetaUpdateTests: XCTestCase {
    let handler = ACPSessionUpdateHandler()

    private func update(_ fields: [String: ACP.Value]) -> ACP.Value {
        .object([
            "sessionId": .string("session-1"),
            "update": .object(fields)
        ])
    }

    // MARK: - Plan (FR-33)

    func testPlanUpdateWithValidEntries() {
        let events = handler.handle(params: update([
            "sessionUpdate": .string("plan_update"),
            "entries": .array([
                .object(["content": .string("Read the code"), "status": .string("completed"), "priority": .string("high")]),
                .object(["content": .string("Write the fix"), "status": .string("in_progress")]),
                .object(["content": .object(["text": .string("Run tests")]), "status": .string("pending")])
            ])
        ]))

        XCTAssertEqual(events, [.planUpdate(entries: [
            ACPPlanEntry(content: "Read the code", status: .completed),
            ACPPlanEntry(content: "Write the fix", status: .inProgress),
            ACPPlanEntry(content: "Run tests", status: .pending)
        ])])
    }

    func testStandardPlanKindIsHandled() {
        let events = handler.handle(params: update([
            "sessionUpdate": .string("plan"),
            "entries": .array([.object(["content": .string("Step"), "status": .string("pending")])])
        ]))
        XCTAssertEqual(events, [.planUpdate(entries: [ACPPlanEntry(content: "Step", status: .pending)])])
    }

    func testPlanEntryStatusesAndMissingStatus() {
        let entries = ACPSessionMetaUpdateParser.planEntries(from: [
            "entries": .array([
                .object(["content": .string("A"), "status": .string("weird")]),
                .object(["content": .string("B")])
            ])
        ])
        XCTAssertEqual(entries, [
            ACPPlanEntry(content: "A", status: .unknown("weird")),
            ACPPlanEntry(content: "B", status: .pending)
        ])
    }

    func testPlanUnexpectedShapesDoNotCrash() {
        // Not an array, missing entries, non-object elements, elements without text.
        XCTAssertEqual(ACPSessionMetaUpdateParser.planEntries(from: ["entries": .string("nope")]), [])
        XCTAssertEqual(ACPSessionMetaUpdateParser.planEntries(from: [:]), [])
        XCTAssertEqual(ACPSessionMetaUpdateParser.planEntries(from: [
            "entries": .array([.string("bare"), .number(3), .object(["status": .string("completed")]), .object(["content": .string("   ")])])
        ]), [])
    }

    func testPlanIsCapped() {
        let many: [ACP.Value] = (0..<500).map { .object(["content": .string("step \($0)")]) }
        let entries = ACPSessionMetaUpdateParser.planEntries(from: ["entries": .array(many)])
        XCTAssertEqual(entries.count, ACPSessionMetaUpdateParser.maxPlanEntries)
    }

    func testPlanRemoved() {
        let events = handler.handle(params: update(["sessionUpdate": .string("plan_removed")]))
        XCTAssertEqual(events, [.planRemoved])
    }

    // MARK: - Session title (FR-33)

    func testSessionInfoTitle() {
        let events = handler.handle(params: update([
            "sessionUpdate": .string("session_info_update"),
            "title": .string("  Fix the login page  ")
        ]))
        XCTAssertEqual(events, [.sessionInfo(title: "Fix the login page")])
    }

    func testSessionInfoWithoutTitleOrEmptyTitle() {
        XCTAssertEqual(handler.handle(params: update(["sessionUpdate": .string("session_info_update")])), [.sessionInfo(title: nil)])
        XCTAssertEqual(handler.handle(params: update(["sessionUpdate": .string("session_info_update"), "title": .string("  ")])), [.sessionInfo(title: nil)])
        XCTAssertEqual(handler.handle(params: update(["sessionUpdate": .string("session_info_update"), "title": .number(4)])), [.sessionInfo(title: nil)])
    }

    // MARK: - Usage (FR-33)

    func testUsageUpdateWithTokensAndCost() {
        let events = handler.handle(params: update([
            "sessionUpdate": .string("usage_update"),
            "used": .int(1200),
            "size": .int(200000),
            "cost": .object(["amount": .double(0.042), "currency": .string("USD")])
        ]))
        XCTAssertEqual(events, [.usage(ACPSessionUsage(usedTokens: 1200, contextSize: 200000, costAmount: 0.042, costCurrency: "USD"))])
    }

    func testUsageAlternativeKeysAndNumericCost() {
        let usage = ACPSessionMetaUpdateParser.usage(from: [
            "usedTokens": .double(90),
            "contextSize": .int(1000),
            "costAmount": .double(1.5),
            "costCurrency": .string("EUR")
        ])
        XCTAssertEqual(usage, ACPSessionUsage(usedTokens: 90, contextSize: 1000, costAmount: 1.5, costCurrency: "EUR"))
    }

    func testUsageWithUnexpectedFieldsIsDroppedNotCrashing() {
        // Strings for numbers, negative counts, a non-object cost, an absurd currency.
        let usage = ACPSessionMetaUpdateParser.usage(from: [
            "used": .string("many"),
            "size": .int(-5),
            "cost": .array([.int(1)])
        ])
        XCTAssertTrue(usage.isEmpty)
        let long = ACPSessionMetaUpdateParser.usage(from: ["cost": .object(["amount": .int(2), "currency": .string("ABCDEFGHIJKL")])])
        XCTAssertNil(long.costCurrency)
        XCTAssertEqual(long.costAmount, 2)
    }

    func testEmptyUsageUpdateEmitsNothing() {
        XCTAssertEqual(handler.handle(params: update(["sessionUpdate": .string("usage_update")])), [])
        XCTAssertEqual(handler.handle(params: update(["sessionUpdate": .string("usage_update"), "used": .string("x")])), [])
    }

    // MARK: - Delete capability (FR-36)

    func testDeleteCapabilityIsParsedFromInitialize() {
        let bob = AgentProfile.parse(from: [
            "agentCapabilities": .object([
                "sessionCapabilities": .object(["list": .object([:]), "delete": .object([:])])
            ])
        ])
        XCTAssertEqual(bob.capabilities.deleteSession, true)

        let none = AgentProfile.parse(from: [
            "agentCapabilities": .object(["sessionCapabilities": .object(["list": .object([:])])])
        ])
        XCTAssertEqual(none.capabilities.deleteSession, false)
    }

    func testDeleteSessionParams() {
        let params = ACPSessionDeletePayload(sessionId: "s-9").params()
        XCTAssertEqual(params, .object(["sessionId": .string("s-9")]))
    }

    // MARK: - _meta on session/new (FR-34)

    func testSessionNewSendsStartModeAsMeta() {
        let params = ACPSessionCreatePayload(
            workingDirectory: "/work",
            mcpServers: [],
            meta: ["bob/mode": .string("plan")]
        ).params()
        XCTAssertEqual(params.objectValue?["_meta"], .object(["bob/mode": .string("plan")]))
    }

    func testSessionNewWithoutMetaOmitsKey() {
        let params = ACPSessionCreatePayload(workingDirectory: "/work").params()
        XCTAssertNil(params.objectValue?["_meta"])
    }

    // MARK: - Auth error text (FR-35, T-35)

    func testAuthenticationRequiredGetsItsOwnText() {
        let error = ACPServiceError.rpc(id: .int(1), error: .serverError(code: -32000, message: "Authentication required"))
        XCTAssertEqual(ACPAgentErrorText.text(for: error), "Bob needs authentication. Set BOB_API_KEY on the gateway host.")
        XCTAssertEqual(ACPAgentErrorText.text(for: GatewayError.rpc(code: -32000, message: "Authentication required")),
                       "Bob needs authentication. Set BOB_API_KEY on the gateway host.")
    }

    func testOtherErrorsKeepTheirText() {
        let other = ACPServiceError.rpc(id: .int(1), error: .serverError(code: -32000, message: "agent exited"))
        XCTAssertEqual(ACPAgentErrorText.text(for: other), "agent exited")
        let wrongCode = ACPServiceError.rpc(id: .int(1), error: .serverError(code: -32602, message: "Authentication required"))
        XCTAssertEqual(ACPAgentErrorText.text(for: wrongCode), "Authentication required")
        XCTAssertEqual(ACPAgentErrorText.text(for: GatewayError.disconnected), "Not connected")
    }
}
