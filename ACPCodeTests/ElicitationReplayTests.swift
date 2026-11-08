import XCTest
import ACP
@testable import ACPCode
import ACPClient

// Replay of elicitations (FR-44, D-090). A subscribe replays the session's log: a question and, later, its
// close. The close in a replay is history, so the form it closes goes without the "answered elsewhere"
// notice, and a live close of an open form still shows it. The gateway no longer replays a question that
// is already closed, so the form is not shown for it.

private let replayElicitationId = "acpcode-elic-replay01"

private func replayRequest(id: String = replayElicitationId) -> ACP.Value {
    .object([
        "id": .string(id),
        "method": .string("elicitation/create"),
        "params": .object([
            "sessionId": .string("s1"),
            "mode": .string("form"),
            "message": .string("Accept the Bob licence?"),
            "requestedSchema": .object([
                "type": .string("object"),
                "properties": .object(["accept": .object(["type": .string("boolean")])]),
                "required": .array([.string("accept")]),
            ]),
        ]),
    ])
}

private func answeredMessage(id: String = replayElicitationId) -> ACP.Value {
    .object([
        "jsonrpc": .string("2.0"),
        "method": .string("_acpcode/elicitation_answered"),
        "params": .object([
            "sessionId": .string("s1"),
            "elicitationId": .string(id),
            "answeredBy": .string("owner/iphone-owner"),
            "action": .string("decline"),
        ]),
    ])
}

/// Accepts nothing; these tests never send an answer.
private final class SilentAnswering: ElicitationAnswering, @unchecked Sendable {
    func answerElicitation(elicitationId: String, action: ElicitationAction, content: [String: ACP.Value]?) async throws {}
}

@MainActor
final class ElicitationReplayTests: XCTestCase {
    private func present(_ inbox: ElicitationInboxModel, id: String = replayElicitationId) throws {
        inbox.present(try ElicitationRequest.parse(replayRequest(id: id)), answering: SilentAnswering())
    }

    /// A question with no answer, replayed to a new subscriber, is shown once.
    func testAQuestionWithNoAnswerIsShownOnce() throws {
        let inbox = ElicitationInboxModel()
        try present(inbox)
        try present(inbox) // a second copy from a later replay or a resubscribe

        XCTAssertEqual(inbox.forms.count, 1)
        XCTAssertEqual(inbox.current?.request.id, replayElicitationId)
        XCTAssertNil(inbox.notice)
    }

    /// A question on the list that the replay closes goes with no notice: the close is history.
    func testReplayedCloseOfAFormOnTheListGoesWithoutANotice() throws {
        let inbox = ElicitationInboxModel()
        try present(inbox)

        inbox.closedInReplay(elicitationId: replayElicitationId)

        XCTAssertNil(inbox.current, "the form is closed")
        XCTAssertTrue(inbox.forms.isEmpty)
        XCTAssertNil(inbox.notice, "a replayed close is not announced")
    }

    /// A replayed close of a question this device does not hold changes nothing and shows nothing.
    func testReplayedCloseWithNoFormShowsNothing() {
        let inbox = ElicitationInboxModel()

        inbox.closedInReplay(elicitationId: replayElicitationId)

        XCTAssertTrue(inbox.forms.isEmpty)
        XCTAssertNil(inbox.notice)
    }

    /// The same close, live, for a form that is open: the notice shows (the live path is unchanged).
    func testLiveCloseOfAnOpenFormShowsTheNotice() throws {
        let inbox = ElicitationInboxModel()
        try present(inbox)

        inbox.closed(elicitationId: replayElicitationId, answeredBy: "owner/iphone-owner")

        XCTAssertTrue(inbox.forms.isEmpty)
        XCTAssertEqual(inbox.notice, "The agent's question was answered elsewhere or closed (owner/iphone-owner).")
    }

    /// The replay flag is read from the event; a live event has none, so it is not history.
    func testGatewayEventReadsTheReplayFlag() throws {
        let live = try XCTUnwrap(GatewayEvent.parse(.object([
            "sessionId": .string("s1"),
            "seq": .int(4),
            "message": answeredMessage(),
        ])))
        XCTAssertFalse(live.isReplay)

        let replayed = try XCTUnwrap(GatewayEvent.parse(.object([
            "sessionId": .string("s1"),
            "seq": .int(4),
            "message": answeredMessage(),
            "replay": .bool(true),
        ])))
        XCTAssertTrue(replayed.isReplay)

        let notReplay = try XCTUnwrap(GatewayEvent.parse(.object([
            "sessionId": .string("s1"),
            "seq": .int(4),
            "message": answeredMessage(),
            "replay": .bool(false),
        ])))
        XCTAssertFalse(notReplay.isReplay)
    }
}
