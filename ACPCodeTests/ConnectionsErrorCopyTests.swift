import XCTest
@testable import ACPCode
import ACPClient

/// The sentence a person sees for a failed gateway call on the Connections screen, and the raw text the log keeps.
@MainActor
final class ConnectionsErrorCopyTests: XCTestCase {
    private struct LocalFailure: Error {}

    private func message(for error: Error) -> (text: String, log: [String]) {
        var lines: [String] = []
        let text = GatewayConnectionsModel.userMessage(for: error, log: { lines.append($0) })
        return (text, lines)
    }

    func testMethodNotFoundGivesThePlainSentenceAndLogsTheRawText() {
        let result = message(for: GatewayError.rpc(code: -32601, message: "Method not found"))
        XCTAssertEqual(result.text, "This gateway does not support Claude connections yet.")
        XCTAssertTrue(result.log.joined().contains("Method not found"), "the raw text is kept in the log")
    }

    func testAnUnknownGatewayErrorGivesTheGenericSentenceAndLogsTheRawText() {
        let result = message(for: GatewayError.rpc(code: -32603, message: "cannot store token"))
        XCTAssertEqual(result.text, "The gateway could not finish this. Try again.")
        XCTAssertTrue(result.log.joined().contains("cannot store token"))
    }

    func testAGatewayRefusalOfTheStateKeepsItsOwnSentence() {
        let result = message(for: GatewayError.rpc(code: -32001, message: "pairing expired"))
        XCTAssertEqual(result.text, "pairing expired")
    }

    func testADroppedConnectionSaysItIsNotConnected() {
        XCTAssertEqual(message(for: GatewayError.disconnected).text, "Not connected to the gateway.")
    }

    func testAnErrorThatIsNotAGatewayErrorGivesTheGenericSentence() {
        let result = message(for: LocalFailure())
        XCTAssertEqual(result.text, "The gateway could not finish this. Try again.")
        XCTAssertEqual(result.log.count, 1)
    }

    /// The Settings row says what works and what does not, in words a person can use.
    func testTheNotificationNoteSaysWhatWorksAndWhatDoesNot() {
        let note = PushSettingsCopy.deliveryNote
        XCTAssertTrue(note.contains("in the background"), "approval alerts while the app is in the background")
        XCTAssertTrue(note.contains("closed"), "the limit for a closed app")
        for jargon in ["entitlement", "APNs", "acpcode://", "token", "gateway does not send"] {
            XCTAssertFalse(note.localizedCaseInsensitiveContains(jargon), "no developer word: \(jargon)")
        }
    }
}
