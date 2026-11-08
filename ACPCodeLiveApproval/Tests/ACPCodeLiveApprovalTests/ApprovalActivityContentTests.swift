import XCTest
@testable import ACPCodeLiveApproval

final class ApprovalActivityContentTests: XCTestCase {
    private func encoded(_ state: ApprovalActivityAttributes.ContentState) throws -> Data {
        try JSONEncoder().encode(state)
    }

    private func sampleState(projectName: String = "remote-bob", approvalId: String = "acpcode-perm-7") -> ApprovalActivityAttributes.ContentState {
        ApprovalActivityAttributes.ContentState(
            pendingCount: 2,
            projectName: projectName,
            approvalId: approvalId,
            allowOnceOptionId: "proceed_once",
            denyOptionId: "cancel",
            openLink: "acpcode://session/6F1C2B7E-1111-4222-8333-444455556666/sess-1"
        )
    }

    /// Privacy: the state is a fixed set of fields, and none of them is a tool title or a command.
    func testEncodedStateHasOnlyTheAllowedFields() throws {
        let object = try JSONSerialization.jsonObject(with: encoded(sampleState())) as? [String: Any]
        XCTAssertEqual(Set((object ?? [:]).keys), [
            "pendingCount", "projectName", "approvalId", "allowOnceOptionId", "denyOptionId", "openLink",
        ])
    }

    /// Size: even with every field at its longest and with characters that JSON escapes, the state stays under the limit.
    func testWorstCaseStateIsUnderTheEncodedSizeLimit() throws {
        let longName = String(repeating: "\"\\", count: 500)
        let longId = String(repeating: "ä", count: 300)
        let state = ApprovalActivityAttributes.ContentState(
            pendingCount: 999,
            projectName: longName,
            approvalId: longId,
            allowOnceOptionId: longId,
            denyOptionId: longId,
            openLink: String(repeating: "x", count: 5_000)
        )
        let size = try encoded(state).count
        XCTAssertLessThan(size, ApprovalActivityLimits.maxEncodedBytes)
    }

    func testFieldsAreClampedToTheirByteLimits() {
        let state = sampleState(projectName: String(repeating: "p", count: 1_000), approvalId: String(repeating: "a", count: 1_000))
        XCTAssertLessThanOrEqual(state.projectName.utf8.count, ApprovalActivityLimits.maxProjectNameBytes)
        XCTAssertLessThanOrEqual(state.approvalId.utf8.count, ApprovalActivityLimits.maxIdBytes)
    }

    func testControlCharactersAreRemovedFromText() {
        let clamped = ApprovalActivityLimits.clamp("ab\ncd\u{0001}ef\tg", toBytes: 100)
        XCTAssertEqual(clamped, "abcdefg")
    }

    func testClampDoesNotSplitACharacter() {
        // "é" is two UTF-8 bytes: a limit of 3 keeps one character and drops the next.
        XCTAssertEqual(ApprovalActivityLimits.clamp("ééé", toBytes: 3), "é")
        XCTAssertEqual(ApprovalActivityLimits.clamp("ééé", toBytes: 4), "éé")
    }

    func testPendingCountIsNeverNegative() {
        let state = ApprovalActivityAttributes.ContentState(
            pendingCount: -3, projectName: "p", approvalId: "a", allowOnceOptionId: nil, denyOptionId: nil, openLink: nil
        )
        XCTAssertEqual(state.pendingCount, 0)
    }

    func testEmptyOptionIdsAndLinksBecomeNil() {
        let state = ApprovalActivityAttributes.ContentState(
            pendingCount: 1, projectName: "p", approvalId: "a", allowOnceOptionId: "", denyOptionId: "", openLink: ""
        )
        XCTAssertNil(state.allowOnceOptionId)
        XCTAssertNil(state.denyOptionId)
        XCTAssertNil(state.openLink)
    }

    func testStateRoundTripsThroughCodable() throws {
        let state = sampleState()
        let decoded = try JSONDecoder().decode(ApprovalActivityAttributes.ContentState.self, from: encoded(state))
        XCTAssertEqual(decoded, state)
    }
}
