import ACP
import ACPClient
import Combine
import Foundation
import XCTest
@testable import ACPCode

/// The MCP Servers row in the server's More menu is offered only for a gateway server.
final class MCPEntryPointTests: XCTestCase {
    func testRowIsOfferedOnlyForGatewayServer() {
        XCTAssertTrue(MCPEntryPoint.showsServersRow(isGateway: true))
        XCTAssertFalse(MCPEntryPoint.showsServersRow(isGateway: false))
    }

    /// The More menu reads `isGatewayServer` from the server view model, and AppViewModel re-renders
    /// only on that view model's objectWillChange. So learning the gateway flag must publish a change.
    @MainActor
    func testUpdateGatewayInfoPublishesChangeSoMenuRefreshes() {
        let suite = "MCPEntryPointTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)
        let serverViewModel = ServerViewModel(
            id: UUID(),
            name: "Gateway",
            scheme: "ws",
            host: "localhost:1234",
            token: "",
            workingDirectory: "/",
            connectionManager: manager,
            getService: { nil },
            append: { _ in },
            logWire: { _, _ in },
            storage: .inMemory()
        )
        XCTAssertFalse(serverViewModel.isGatewayServer)

        var changes = 0
        let cancellable = serverViewModel.objectWillChange.sink { changes += 1 }
        defer { cancellable.cancel() }

        serverViewModel.updateGatewayInfo(GatewayInfo(version: "0.3.0-dev", extensions: ["sessions"]))

        XCTAssertTrue(serverViewModel.isGatewayServer)
        XCTAssertEqual(changes, 1)
    }

    /// Settings shows the MCP section with the More menu's rule: a gateway shows the servers, a plain ACP
    /// connection shows nothing, and no selection asks the user to pick a connection first.
    func testSettingsSectionFollowsTheMoreMenuRule() {
        XCTAssertEqual(MCPEntryPoint.settingsMode(hasSelection: false, isGateway: false), .selectConnection)
        XCTAssertEqual(MCPEntryPoint.settingsMode(hasSelection: false, isGateway: true), .selectConnection)
        XCTAssertEqual(MCPEntryPoint.settingsMode(hasSelection: true, isGateway: true), .servers)
        XCTAssertEqual(MCPEntryPoint.settingsMode(hasSelection: true, isGateway: false), .hidden)
        XCTAssertEqual(MCPEntryPoint.settingsMode(hasSelection: true, isGateway: true) == .servers,
                       MCPEntryPoint.showsServersRow(isGateway: true))
        XCTAssertEqual(MCPEntryPoint.settingsMode(hasSelection: true, isGateway: false) == .servers,
                       MCPEntryPoint.showsServersRow(isGateway: false))
    }

    /// The footer says when servers are sent. A gateway sends the phone's list on session/new and session/resume.
    /// A plain ACP connection sends no MCP servers at all (`mcpServersForSession()` returns []).
    func testFooterCopyForEachConnectionKind() {
        XCTAssertEqual(
            MCPServersCopy.footer(isGateway: true),
            "Servers on this phone are sent when a session starts or resumes. A running session keeps them until it is reopened."
        )
        XCTAssertEqual(
            MCPServersCopy.footer(isGateway: false),
            "MCP servers are used only on gateway connections, so none are sent on this connection."
        )
    }

    func testListFileIsPerServerAndMatchesTheSessionPayloadFile() {
        let serverId = UUID()
        XCTAssertEqual(MCPEntryPoint.listFileURL(serverId: serverId),
                       MCPServersModel.defaultFileURL(serverId: serverId))
        XCTAssertNotEqual(MCPEntryPoint.listFileURL(serverId: serverId),
                          MCPEntryPoint.listFileURL(serverId: UUID()))
    }
}

/// The Settings row for the gateway's global list (D-107) reads the same list the session sheet reads.
final class SettingsGatewayMCPTests: XCTestCase {
    private let listedJSON = """
    {"servers":[
     {"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"filesystem","transport":"stdio","defaultEnabled":true},
     {"id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","name":"docs","transport":"http","url":"https://mcp.example.com/mcp","defaultEnabled":false},
     {"id":"cccccccccccccccccccccccccccccccc","name":"search","transport":"http","url":"https://search.example.net/","defaultEnabled":true}
    ]}
    """

    private func isolatedDefaults() -> UserDefaults {
        let suite = "SettingsGatewayMCPTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @MainActor
    func testRowCountIsTheGatewayListCount() async throws {
        let fake = GatewayMCPCallFake()
        fake.results["_acpcode/mcp/servers/list"] = try JSONDecoder().decode(ACP.Value.self, from: Data(listedJSON.utf8))
        let model = GatewayMCPCatalogModel(clientProvider: { GatewayClient(fake) }, defaults: isolatedDefaults())
        XCTAssertEqual(SettingsGatewayMCPCopy.countText(phase: model.phase, count: model.servers.count), "Loading")
        await model.load()
        XCTAssertEqual(model.servers.map(\.name), ["filesystem", "docs", "search"])
        XCTAssertEqual(SettingsGatewayMCPCopy.countText(phase: model.phase, count: model.servers.count), "3")
        XCTAssertEqual(SettingsGatewayMCPCopy.footer,
                       "Managed on the gateway. A new session starts with the servers chosen for it, or the defaults. Changing a session's servers in its header applies from the next message.")
    }

    @MainActor
    func testRowSaysWhenTheListIsNotLoadedOrNotSupported() async {
        let failing = GatewayMCPCallFake()
        failing.errors["_acpcode/mcp/servers/list"] = ACPServiceError.rpc(id: .number(1), error: .internalError("boom"))
        let failed = GatewayMCPCatalogModel(clientProvider: { GatewayClient(failing) }, defaults: isolatedDefaults())
        await failed.load()
        XCTAssertEqual(SettingsGatewayMCPCopy.countText(phase: failed.phase, count: failed.servers.count), "Not loaded")

        let unsupported = GatewayMCPCallFake()
        unsupported.errors["_acpcode/mcp/servers/list"] = ACPServiceError.rpc(id: .number(1), error: .methodNotFound(nil))
        let none = GatewayMCPCatalogModel(clientProvider: { GatewayClient(unsupported) }, defaults: isolatedDefaults())
        await none.load()
        XCTAssertEqual(SettingsGatewayMCPCopy.countText(phase: none.phase, count: none.servers.count), "Not supported")
    }
}
