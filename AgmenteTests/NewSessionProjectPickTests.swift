import XCTest
@testable import Agmente
import ACPClient

/// FR-26: a gateway server starts a session in a registered project, never in a blank path ("/").
/// The plain ACP server keeps its free-text working directory.
final class NewSessionProjectPickTests: XCTestCase {
    private let site = GatewayProject(id: "p-site", name: "Site", path: "/srv/site")
    private let api = GatewayProject(id: "p-api", name: "API", path: "/srv/api")

    func testGatewayWithProjectsDefaultsToTheFirstProjectsPath() {
        let chosen = gatewayNewSessionChosenProject([site, api], selection: nil)
        XCTAssertEqual(chosen?.id, "p-site", "the first project is the default")
        XCTAssertEqual(gatewayNewSessionCwd(selectedProjectPath: chosen?.path), "/srv/site")
        XCTAssertFalse(gatewayNewSessionBlocked(isGateway: true, selectedProjectPath: chosen?.path))
    }

    func testGatewayWithNoProjectsHasNoDefaultNoCwdAndIsBlocked() {
        XCTAssertNil(gatewayNewSessionChosenProject([], selection: nil))
        XCTAssertNil(gatewayNewSessionCwd(selectedProjectPath: nil))
        XCTAssertTrue(gatewayNewSessionBlocked(isGateway: true, selectedProjectPath: nil))
    }

    func testBlankSelectionIsNeverSentAsSlashForAGateway() {
        for blank in ["", "   ", "\n\t"] {
            XCTAssertNil(gatewayNewSessionCwd(selectedProjectPath: blank), "blank \(blank.debugDescription) gives no cwd")
            XCTAssertTrue(gatewayNewSessionBlocked(isGateway: true, selectedProjectPath: blank))
        }
    }

    func testTheChosenProjectIsKeptWhileListedAndFallsBackToTheFirstOtherwise() {
        XCTAssertEqual(gatewayNewSessionChosenProject([site, api], selection: "p-api")?.id, "p-api")
        XCTAssertEqual(gatewayNewSessionChosenProject([site, api], selection: "p-gone")?.id, "p-site")
    }

    func testThePathIsTrimmedLikeTheFreeTextPath() {
        XCTAssertEqual(gatewayNewSessionCwd(selectedProjectPath: "  /srv/site \n"), "/srv/site")
    }

    func testAPlainServerIsNeverBlockedAndKeepsItsFreeTextPath() {
        XCTAssertFalse(gatewayNewSessionBlocked(isGateway: false, selectedProjectPath: nil),
                       "a plain server with no typed path still uses its own working directory, as before")
        XCTAssertFalse(gatewayNewSessionBlocked(isGateway: false, selectedProjectPath: ""))
        XCTAssertFalse(gatewayNewSessionBlocked(isGateway: false, selectedProjectPath: "/tmp/custom-project"))
    }
}
