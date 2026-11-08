import XCTest
import ACP
@testable import ACPCode
import ACPClient
import ACPCodeLiveApproval

/// The approval Live Activity: what the mapper puts in the content state (la-decision, sections 4 and 6).
final class ApprovalActivityStateMapperTests: XCTestCase {
    private let serverId = UUID(uuidString: "6F1C2B7E-1111-4222-8333-444455556666")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func approval(
        _ id: String,
        since: Date,
        session: String = "sess-1",
        options: [GatewayApprovalOption]? = nil,
        title: String = "Run tests",
        command: String = "npm test"
    ) -> GatewayApproval {
        GatewayApproval(
            approvalId: id,
            sessionId: session,
            projectId: "p1",
            toolCall: .object([
                "toolCallId": .string("c-\(id)"),
                "title": .string(title),
                "kind": .string("execute"),
                "rawInput": .object(["command": .string(command)]),
            ]),
            options: options ?? [
                GatewayApprovalOption(optionId: "proceed_once", name: "Allow once", kind: "allow_once"),
                GatewayApprovalOption(optionId: "cancel", name: "Reject", kind: "reject_once"),
            ],
            since: iso(since)
        )
    }

    private func content(_ approvals: [GatewayApproval], project: (String) -> String = { _ in "remote-bob" }) -> ApprovalActivityStateMapper.Content? {
        ApprovalActivityStateMapper.content(for: approvals, serverId: serverId, now: now, projectName: project)
    }

    private func json(_ state: ApprovalActivityAttributes.ContentState) throws -> String {
        String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
    }

    func testNoOpenApprovalGivesNoContentSoTheActivityEnds() {
        XCTAssertNil(content([]))
    }

    func testShowsTheCountAndTheOldestApproval() {
        let newer = approval("acpcode-perm-2", since: now.addingTimeInterval(-10))
        let older = approval("acpcode-perm-1", since: now.addingTimeInterval(-60))
        let result = content([newer, older])
        XCTAssertEqual(result?.state.pendingCount, 2)
        XCTAssertEqual(result?.state.approvalId, "acpcode-perm-1")
    }

    func testOnceAndDenyUseTheOptionsOfferedByKind() {
        let result = content([approval("acpcode-perm-1", since: now)])
        XCTAssertEqual(result?.state.allowOnceOptionId, "proceed_once")
        XCTAssertEqual(result?.state.denyOptionId, "cancel")
    }

    /// Allow Always is a standing rule. It never reaches the island, so it is never offered there.
    func testAllowAlwaysAndRejectAlwaysAreNeverOfferedOnTheIsland() {
        let always = approval("acpcode-perm-1", since: now, options: [
            GatewayApprovalOption(optionId: "always", name: "Always allow", kind: "allow_always"),
            GatewayApprovalOption(optionId: "never", name: "Never", kind: "reject_always"),
        ])
        let result = content([always])
        XCTAssertNil(result?.state.allowOnceOptionId)
        XCTAssertNil(result?.state.denyOptionId)
    }

    func testAnAlwaysOptionIsIgnoredWhenAOnceOptionIsOffered() {
        let mixed = approval("acpcode-perm-1", since: now, options: [
            GatewayApprovalOption(optionId: "always", name: "Always allow", kind: "allow_always"),
            GatewayApprovalOption(optionId: "once", name: "Allow once", kind: "allow_once"),
        ])
        XCTAssertEqual(content([mixed])?.state.allowOnceOptionId, "once")
    }

    /// Privacy: the tool title and the command never reach the content state, so never the Lock Screen.
    func testTheEncodedStateHoldsNoToolTitleOrCommand() throws {
        let secret = approval("acpcode-perm-1", since: now, title: "Delete the build folder", command: "rm -rf build/secret-token")
        let result = try XCTUnwrap(content([secret]))
        let text = try json(result.state)
        XCTAssertFalse(text.contains("Delete the build folder"))
        XCTAssertFalse(text.contains("rm -rf"))
        XCTAssertFalse(text.contains("secret-token"))
        XCTAssertFalse(text.contains("Run tests"))
    }

    func testTheProjectNameComesFromTheProjectOfTheOldestApproval() {
        var asked: [String] = []
        _ = content([approval("acpcode-perm-1", since: now)]) { id in
            asked.append(id)
            return "remote-bob"
        }
        XCTAssertEqual(asked, ["p1"])
    }

    func testAnOverlongProjectNameIsBounded() {
        let result = content([approval("acpcode-perm-1", since: now)]) { _ in String(repeating: "n", count: 600) }
        XCTAssertLessThanOrEqual(result?.state.projectName.utf8.count ?? .max, ApprovalActivityLimits.maxProjectNameBytes)
    }

    func testEncodedStateStaysUnderTheSizeLimitEvenWhenFieldsAreLong() throws {
        let long = approval(String(repeating: "a", count: 900), since: now, session: String(repeating: "s", count: 150))
        let result = try XCTUnwrap(content([long]) { _ in String(repeating: "\"", count: 900) })
        let size = try JSONEncoder().encode(result.state).count
        XCTAssertLessThan(size, ApprovalActivityLimits.maxEncodedBytes)
    }

    /// Stale: five minutes after a fresh check, or the approval's own timeout when that comes first.
    func testStaleDateIsFiveMinutesAfterTheCheck() throws {
        let result = try XCTUnwrap(content([approval("acpcode-perm-1", since: now.addingTimeInterval(-10))]))
        XCTAssertEqual(result.staleDate.timeIntervalSince(now), ApprovalActivityStateMapper.staleAfter, accuracy: 0.5)
    }

    func testStaleDateStopsAtTheApprovalTimeout() throws {
        let almostTimedOut = now.addingTimeInterval(-(ApprovalActivityStateMapper.approvalTimeout - 60))
        let result = try XCTUnwrap(content([approval("acpcode-perm-1", since: almostTimedOut)]))
        XCTAssertEqual(result.staleDate.timeIntervalSince(now), 60, accuracy: 1.0)
    }

    func testOpenLinkIsTheExistingSessionDeepLink() throws {
        let result = try XCTUnwrap(content([approval("acpcode-perm-1", since: now, session: "sess-1")]))
        let expected = DeepLink.session(serverId: serverId, sessionId: "sess-1").url
        XCTAssertEqual(result.state.openLink, expected.absoluteString)
        XCTAssertEqual(DeepLink.parse(try XCTUnwrap(URL(string: try XCTUnwrap(result.state.openLink)))), .session(serverId: serverId, sessionId: "sess-1"))
    }

    func testASessionIdThatIsNotALinkPartGivesNoOpenButton() throws {
        let result = try XCTUnwrap(content([approval("acpcode-perm-1", since: now, session: "bad/session")]))
        XCTAssertNil(result.state.openLink)
    }

    func testAlertGateLetsOneAlertThroughPerWindow() {
        var gate = ApprovalAlertGate(minimumInterval: 3)
        XCTAssertTrue(gate.allow(now: now))
        XCTAssertFalse(gate.allow(now: now.addingTimeInterval(1)))
        XCTAssertFalse(gate.allow(now: now.addingTimeInterval(2.9)))
        XCTAssertTrue(gate.allow(now: now.addingTimeInterval(3)))
    }
}
