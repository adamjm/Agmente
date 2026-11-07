import ACP
import Foundation
import XCTest
@testable import Agmente

/// PLAN 6B.2 wiring: the MCP list reaches session/new and session/resume only for a gateway server,
/// HTTP entries only when the agent advertises mcpCapabilities.http, and deleting a server deletes its
/// MCP entries and header values (PLAN 6B.1).
@MainActor
final class ForkMCPWiringTests: XCTestCase {
    private var directory: URL!
    private var values: MCPHeaderStore!
    private var model: MCPServersModel!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-wiring-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        values = MCPHeaderStore(service: "com.agmente.tests.mcpwire.\(UUID().uuidString)")
        model = MCPServersModel(fileURL: directory.appendingPathComponent("servers.json"), values: values)
    }

    override func tearDown() {
        try? model.removeAll()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    @discardableResult
    private func addHTTP(name: String = "docs", enabled: Bool = true) throws -> MCPServerEntry {
        let entry = MCPServerEntry(name: name, transport: .http, isEnabled: enabled,
                                   url: "https://mcp.example.com/mcp", headerNames: ["Authorization"])
        try model.upsert(entry, headerValues: ["Authorization": "Bearer wiring-secret-value"])
        return entry
    }

    private func object(_ value: ACP.Value?) -> [String: ACP.Value] {
        value?.objectValue ?? [:]
    }

    // MARK: Call-site payload

    func testPlainACPServerSendsEmptyMCPServers() throws {
        try addHTTP()
        let payload = try MCPSessionServers.payload(from: model, isGateway: false, agentSupportsHTTP: true)
        XCTAssertEqual(payload, [])
    }

    func testGatewayServerSendsEnabledHTTPEntry() throws {
        try addHTTP(name: "docs")
        let payload = try MCPSessionServers.payload(from: model, isGateway: true, agentSupportsHTTP: true)
        XCTAssertEqual(payload.count, 1)
        let entry = object(payload.first)
        XCTAssertEqual(entry["type"]?.stringValue, "http")
        XCTAssertEqual(entry["name"]?.stringValue, "docs")
        XCTAssertEqual(entry["url"]?.stringValue, "https://mcp.example.com/mcp")
        let headers = entry["headers"]?.arrayValue ?? []
        XCTAssertEqual(object(headers.first)["value"]?.stringValue, "Bearer wiring-secret-value")
    }

    func testGatewayAgentWithoutHTTPCapabilityOmitsHTTPEntry() throws {
        try addHTTP()
        let payload = try MCPSessionServers.payload(from: model, isGateway: true, agentSupportsHTTP: false)
        XCTAssertEqual(payload, [])
    }

    func testDisabledHTTPEntryIsNotSent() throws {
        try addHTTP(enabled: false)
        let payload = try MCPSessionServers.payload(from: model, isGateway: true, agentSupportsHTTP: true)
        XCTAssertEqual(payload, [])
    }

    // MARK: Deleting a server

    func testDeletingServerRemovesItsMCPEntriesAndHeaderValues() throws {
        let serverId = UUID()
        let fileModel = MCPServersModel(fileURL: MCPServersModel.defaultFileURL(serverId: serverId))
        let entry = MCPServerEntry(name: "docs", transport: .http, url: "https://mcp.example.com/mcp", headerNames: ["Authorization"])
        try fileModel.upsert(entry, headerValues: ["Authorization": "Bearer delete-me-value"])
        defer { try? MCPServersModel.deleteStoredData(serverId: serverId) }
        XCTAssertNotNil(try MCPHeaderStore().get(entryId: entry.id, kind: .header, name: "Authorization"))

        let controller = PersistenceController(storeURL: directory.appendingPathComponent("Agmente.sqlite"))
        let storage = SessionStorage(
            container: controller.container,
            keychain: KeychainStore(service: "com.agmente.tests.mcpwire.\(UUID().uuidString)")
        )
        storage.deleteServer(id: serverId)

        XCTAssertNil(try MCPHeaderStore().get(entryId: entry.id, kind: .header, name: "Authorization"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileModel.fileURL.path))
    }
}
