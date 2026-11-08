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

    func testListFileIsPerServerAndMatchesTheSessionPayloadFile() {
        let serverId = UUID()
        XCTAssertEqual(MCPEntryPoint.listFileURL(serverId: serverId),
                       MCPServersModel.defaultFileURL(serverId: serverId))
        XCTAssertNotEqual(MCPEntryPoint.listFileURL(serverId: serverId),
                          MCPEntryPoint.listFileURL(serverId: UUID()))
    }
}
