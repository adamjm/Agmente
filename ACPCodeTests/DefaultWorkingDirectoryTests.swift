import XCTest
@testable import ACPCode
import ACPClient

/// A blank working directory. A gateway connection starts new sessions in the gateway's working_dir
/// project. A plain ACP connection does not start a session at all: it never falls back to "/".
/// A typed or stored "/" keeps its meaning.
final class DefaultWorkingDirectoryTests: XCTestCase {
    private let site = GatewayProject(id: "p-site", name: "Site", path: "/srv/site")
    private let workingDir = GatewayProject(
        id: "p-wd",
        name: "working_dir",
        path: "/Users/me/.acpcode/state/working_dir"
    )

    // MARK: Gateway

    func testBlankGatewayConnectionStartsInTheWorkingDirProject() {
        let chosen = gatewayNewSessionChosenProject([site, workingDir], selection: nil, blankWorkingDirectory: true)
        XCTAssertEqual(chosen?.id, "p-wd")
        XCTAssertEqual(gatewayNewSessionCwd(selectedProjectPath: chosen?.path), "/Users/me/.acpcode/state/working_dir")
        XCTAssertFalse(gatewayNewSessionBlocked(isGateway: true, selectedProjectPath: chosen?.path))
    }

    func testBlankGatewayConnectionWithoutAWorkingDirProjectFallsBackToTheFirstProject() {
        XCTAssertEqual(gatewayNewSessionChosenProject([site], selection: nil, blankWorkingDirectory: true)?.id, "p-site")
    }

    func testAGatewayConnectionWithAWorkingDirectoryKeepsTheFirstProjectDefault() {
        XCTAssertEqual(gatewayNewSessionChosenProject([site, workingDir], selection: nil, blankWorkingDirectory: false)?.id, "p-site")
    }

    func testAnExplicitProjectChoiceWinsOverTheWorkingDirProject() {
        XCTAssertEqual(gatewayNewSessionChosenProject([site, workingDir], selection: "p-site", blankWorkingDirectory: true)?.id, "p-site")
    }

    func testTheGatewayDefaultProjectNameIsWorkingDir() {
        XCTAssertEqual(gatewayDefaultProjectName, "working_dir")
    }

    // MARK: Plain ACP

    func testBlankPlainACPConnectionWithNoFolderHasNoCwdAndIsBlocked() {
        XCTAssertNil(plainACPNewSessionCwd(requested: nil, connectionWorkingDirectory: ""))
        XCTAssertNil(plainACPNewSessionCwd(requested: "  ", connectionWorkingDirectory: " \n\t"))
        XCTAssertTrue(plainACPNewSessionBlocked(isGateway: false, requested: nil, connectionWorkingDirectory: ""))
        XCTAssertTrue(plainACPNewSessionBlocked(isGateway: false, requested: "", connectionWorkingDirectory: "   "))
    }

    func testBlankPlainACPConnectionStartsInAFolderTheUserTyped() {
        XCTAssertFalse(plainACPNewSessionBlocked(isGateway: false, requested: "/Users/me/app", connectionWorkingDirectory: ""))
        XCTAssertEqual(plainACPNewSessionCwd(requested: " /Users/me/app \n", connectionWorkingDirectory: ""), "/Users/me/app")
    }

    func testTheBlockedMessageAsksForAWorkingDirectory() {
        XCTAssertEqual(
            plainACPBlankWorkingDirectoryMessage,
            "Set a working directory for this connection before starting a session."
        )
    }

    func testATypedRootIsStillAStartingFolder() {
        XCTAssertEqual(plainACPNewSessionCwd(requested: "/", connectionWorkingDirectory: ""), "/")
        XCTAssertEqual(plainACPNewSessionCwd(requested: "/", connectionWorkingDirectory: "/Users/me/app"), "/")
        XCTAssertFalse(plainACPNewSessionBlocked(isGateway: false, requested: "/", connectionWorkingDirectory: ""))
        // The root warning in the connection form still applies to a typed "/".
        XCTAssertTrue(AddServerView.isRootWorkingDirectory(" / "))
    }

    func testAnExistingRootConnectionStillStartsAtRoot() {
        XCTAssertEqual(plainACPNewSessionCwd(requested: nil, connectionWorkingDirectory: "/"), "/")
        XCTAssertEqual(plainACPNewSessionCwd(requested: "", connectionWorkingDirectory: " / "), "/")
        XCTAssertFalse(plainACPNewSessionBlocked(isGateway: false, requested: nil, connectionWorkingDirectory: "/"))
    }

    func testAPlainConnectionWithAFolderIsNotBlocked() {
        XCTAssertEqual(plainACPNewSessionCwd(requested: nil, connectionWorkingDirectory: "/Users/me/app"), "/Users/me/app")
        XCTAssertFalse(plainACPNewSessionBlocked(isGateway: false, requested: nil, connectionWorkingDirectory: "/Users/me/app"))
    }

    func testTheGatewayIsNeverBlockedByThePlainACPRule() {
        XCTAssertFalse(plainACPNewSessionBlocked(isGateway: true, requested: nil, connectionWorkingDirectory: ""))
    }
}
