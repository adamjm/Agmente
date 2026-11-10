import ACPClient
import Foundation
import XCTest
@testable import ACPCode

/// The Connections rows of the Settings panel are built from a server configuration and the app state.
final class SettingsConnectionRowModelTests: XCTestCase {
    private let secretToken = "tok-do-not-show-123"
    private let secretPassphrase = "pass-do-not-show-456"

    private func makeServer(name: String = "Work Mac", host: String = "mac.example.com:8443", id: UUID = UUID()) -> ACPServerConfiguration {
        ACPServerConfiguration(
            id: id,
            name: name,
            scheme: "wss",
            host: host,
            token: secretToken,
            cfAccessClientId: "",
            cfAccessClientSecret: "",
            workingDirectory: "/work"
        )
    }

    func testTitleIsServerNameAndSubtitleIsHost() {
        let server = makeServer(name: "Work Mac", host: "mac.example.com:8443")
        let row = SettingsConnectionRowModel.make(server: server, selectedServerId: nil, connectionState: .disconnected, isGateway: false)

        XCTAssertEqual(row.title, "Work Mac")
        XCTAssertEqual(row.subtitle, "mac.example.com:8443")
        XCTAssertEqual(row.id, server.id)
    }

    func testEmptyNameFallsBackToHost() {
        let row = SettingsConnectionRowModel.make(
            server: makeServer(name: "   ", host: "mac.example.com"),
            selectedServerId: nil,
            connectionState: .disconnected,
            isGateway: false
        )

        XCTAssertEqual(row.title, "mac.example.com")
    }

    func testEmptyHostShowsNoHostAndUntitledWhenNameAlsoEmpty() {
        let row = SettingsConnectionRowModel.make(
            server: makeServer(name: "", host: " "),
            selectedServerId: nil,
            connectionState: .disconnected,
            isGateway: false
        )

        XCTAssertEqual(row.title, "Untitled connection")
        XCTAssertEqual(row.subtitle, "No host")
    }

    func testSelectedGatewayUsesDesktopIcon() {
        let server = makeServer()
        let row = SettingsConnectionRowModel.make(server: server, selectedServerId: server.id, connectionState: .connected, isGateway: true)

        XCTAssertEqual(row.iconName, "desktopcomputer")
    }

    func testSelectedNonGatewayUsesRackIcon() {
        let server = makeServer()
        let row = SettingsConnectionRowModel.make(server: server, selectedServerId: server.id, connectionState: .connected, isGateway: false)

        XCTAssertEqual(row.iconName, "server.rack")
    }

    /// The app only knows the gateway flag for the selected connection, so an unselected row never gets the gateway icon.
    func testUnselectedConnectionNeverGetsGatewayIcon() {
        let server = makeServer()
        let row = SettingsConnectionRowModel.make(server: server, selectedServerId: UUID(), connectionState: .connected, isGateway: true)

        XCTAssertEqual(row.iconName, "server.rack")
        XCTAssertFalse(row.isSelected)
    }

    func testOnlySelectedRowIsSelectedAndCarriesStatus() {
        let selected = makeServer(name: "A")
        let other = makeServer(name: "B")

        let selectedRow = SettingsConnectionRowModel.make(server: selected, selectedServerId: selected.id, connectionState: .connecting, isGateway: false)
        let otherRow = SettingsConnectionRowModel.make(server: other, selectedServerId: selected.id, connectionState: .connecting, isGateway: false)

        XCTAssertTrue(selectedRow.isSelected)
        XCTAssertEqual(selectedRow.status, .connecting)
        XCTAssertFalse(otherRow.isSelected)
        XCTAssertNil(otherRow.status)
    }

    func testStatusMapsEveryConnectionState() {
        let server = makeServer()
        let cases: [(ACPConnectionState, SettingsConnectionStatus)] = [
            (.connected, .connected),
            (.connecting, .connecting),
            (.disconnected, .disconnected),
            (.failed(NSError(domain: "SettingsTest", code: 1)), .failed),
        ]
        for (state, expected) in cases {
            let row = SettingsConnectionRowModel.make(server: server, selectedServerId: server.id, connectionState: state, isGateway: false)
            XCTAssertEqual(row.status, expected)
        }
    }

    func testRowIdentifierUsesServerId() {
        let server = makeServer()
        let row = SettingsConnectionRowModel.make(server: server, selectedServerId: nil, connectionState: .disconnected, isGateway: false)

        XCTAssertEqual(row.accessibilityIdentifier, "settingsConnection.\(server.id.uuidString)")
    }

    func testFactsShowSchemeHostAndCertificatePresenceOnly() {
        let server = makeServer(host: "mac.example.com:8443")
        let facts = SettingsConnectionFacts.make(server: server, hasClientCertificate: true, agentName: "Claude Code", agentVersion: "1.4.2")

        XCTAssertEqual(facts.scheme, "wss")
        XCTAssertEqual(facts.host, "mac.example.com:8443")
        XCTAssertTrue(facts.clientCertificateStored)
        XCTAssertEqual(facts.agent, "Claude Code 1.4.2")
    }

    func testFactsAgentIsNilWhenNotKnownAndNameWithoutVersion() {
        let server = makeServer()
        let unknown = SettingsConnectionFacts.make(server: server, hasClientCertificate: false, agentName: nil, agentVersion: nil)
        let nameOnly = SettingsConnectionFacts.make(server: server, hasClientCertificate: false, agentName: "Bob", agentVersion: nil)

        XCTAssertNil(unknown.agent)
        XCTAssertFalse(unknown.clientCertificateStored)
        XCTAssertEqual(nameOnly.agent, "Bob")
    }

    /// The detail screen must never show a token, a passphrase or a key.
    func testFactsNeverContainSecrets() {
        let server = ACPServerConfiguration(
            id: UUID(),
            name: "Work Mac",
            scheme: "wss",
            host: "mac.example.com",
            token: secretToken,
            cfAccessClientId: "cf-id",
            cfAccessClientSecret: secretPassphrase,
            workingDirectory: "/work"
        )
        let facts = SettingsConnectionFacts.make(server: server, hasClientCertificate: true, agentName: "Bob", agentVersion: "2")
        let rendered = [facts.scheme, facts.host, facts.agent ?? ""].joined(separator: "|")

        XCTAssertFalse(rendered.contains(secretToken))
        XCTAssertFalse(rendered.contains(secretPassphrase))
        XCTAssertFalse(String(describing: facts).contains(secretToken))
        XCTAssertFalse(String(describing: facts).contains(secretPassphrase))
    }
}
