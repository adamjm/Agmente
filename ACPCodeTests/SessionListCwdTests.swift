import XCTest
import ACPClient
@testable import ACPCode

/// A gateway refuses a session/list whose cwd is outside its project roots (guard.go cwdAllowed),
/// and its list is not per folder (FR-21). So a gateway server's request carries no cwd. A plain
/// ACP server's request is unchanged.
final class SessionListCwdTests: XCTestCase {
    func testGatewayServerListRequestHasNoCwdForFallbackRoot() {
        let payload = ACPSessionListPayload.forServer(workingDirectory: "/", isGateway: true)
        XCTAssertNil(payload.workingDirectory)
    }

    func testGatewayServerListRequestHasNoCwdForProjectPath() {
        let payload = ACPSessionListPayload.forServer(
            workingDirectory: "/Users/me/projects/alpha",
            isGateway: true
        )
        XCTAssertNil(payload.workingDirectory)
    }

    func testPlainServerListRequestKeepsRootCwd() {
        let payload = ACPSessionListPayload.forServer(workingDirectory: "/", isGateway: false)
        XCTAssertEqual(payload.workingDirectory, "/")
    }

    func testPlainServerListRequestKeepsProjectCwd() {
        let payload = ACPSessionListPayload.forServer(
            workingDirectory: "/Users/me/projects/alpha",
            isGateway: false
        )
        XCTAssertEqual(payload.workingDirectory, "/Users/me/projects/alpha")
    }

    // The gateway flag is only known once the initialize result is applied. Until then no list
    // request may be built, because a guessed flag sends cwd "/" to a gateway, which refuses it.

    func testUnknownGatewayFlagBuildsNoListRequest() {
        let payload = ACPSessionListPayload.forServerIfKnown(workingDirectory: "/", isGateway: nil)
        XCTAssertNil(payload)
    }

    func testGatewayFlagSetAfterInitializeBuildsListRequestWithoutCwd() {
        let payload = ACPSessionListPayload.forServerIfKnown(workingDirectory: "/", isGateway: true)
        XCTAssertNotNil(payload)
        XCTAssertNil(payload?.workingDirectory)
    }

    func testPlainFlagSetAfterInitializeBuildsListRequestWithCwd() {
        let payload = ACPSessionListPayload.forServerIfKnown(workingDirectory: "/", isGateway: false)
        XCTAssertEqual(payload?.workingDirectory, "/")
    }
}
