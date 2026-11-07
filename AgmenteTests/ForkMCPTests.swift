import ACP
import Foundation
import XCTest
@testable import Agmente

/// PLAN 6B.2 (FR-40): the MCP server list, the ACP payload for session/new and session/resume,
/// and the rule that headers and env values never reach a file.
@MainActor
final class ForkMCPTests: XCTestCase {
    private var directory: URL!
    private var values: MCPHeaderStore!
    private var model: MCPServersModel!

    private let gateway = MCPPayloadContext(isGateway: true, agentSupportsHTTP: true)

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-tests-\(UUID().uuidString)", isDirectory: true)
        values = MCPHeaderStore(service: "com.agmente.tests.mcp.\(UUID().uuidString)")
        model = MCPServersModel(fileURL: directory.appendingPathComponent("servers.json"), values: values)
    }

    override func tearDown() {
        try? model.removeAll()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func http(name: String = "docs", url: String = "https://mcp.example.com/mcp", headers: [String: String] = ["Authorization": "Bearer s3cret-value"], enabled: Bool = true, alwaysAllow: [String] = []) throws -> MCPServerEntry {
        let entry = MCPServerEntry(name: name, transport: .http, isEnabled: enabled, url: url,
                                   headerNames: headers.keys.sorted(), alwaysAllow: alwaysAllow)
        try model.upsert(entry, headerValues: headers)
        return entry
    }

    private func stdio(name: String = "local", enabled: Bool = true, acknowledged: Bool = true, env: [String: String] = ["API_TOKEN": "env-value-xyz"], alwaysAllow: [String] = []) throws -> MCPServerEntry {
        let entry = MCPServerEntry(name: name, transport: .stdio, isEnabled: enabled, command: "npx",
                                   args: ["-y", "some-server"], envNames: env.keys.sorted(),
                                   alwaysAllow: alwaysAllow, stdioAcknowledged: acknowledged)
        try model.upsert(entry, envValues: env)
        return entry
    }

    private func object(_ value: ACP.Value?) -> [String: ACP.Value] {
        value?.objectValue ?? [:]
    }

    // MARK: Payload shapes

    func testHTTPEntryPayloadShape() throws {
        _ = try http(alwaysAllow: [])
        let payload = try model.mcpServersPayload(for: gateway)
        XCTAssertEqual(payload.count, 1)
        let entry = object(payload[0])
        XCTAssertEqual(Set(entry.keys), ["type", "name", "url", "headers"])
        XCTAssertEqual(entry["type"]?.stringValue, "http")
        XCTAssertEqual(entry["name"]?.stringValue, "docs")
        XCTAssertEqual(entry["url"]?.stringValue, "https://mcp.example.com/mcp")
        let headers = entry["headers"]?.arrayValue ?? []
        XCTAssertEqual(headers.count, 1)
        XCTAssertEqual(object(headers[0])["name"]?.stringValue, "Authorization")
        XCTAssertEqual(object(headers[0])["value"]?.stringValue, "Bearer s3cret-value")
    }

    func testStdioEntryPayloadShape() throws {
        _ = try stdio()
        let payload = try model.mcpServersPayload(for: gateway)
        XCTAssertEqual(payload.count, 1)
        let entry = object(payload[0])
        // ACP stdio shape: no type, no url, no headers.
        XCTAssertEqual(Set(entry.keys), ["name", "command", "args", "env"])
        XCTAssertEqual(entry["name"]?.stringValue, "local")
        XCTAssertEqual(entry["command"]?.stringValue, "npx")
        XCTAssertEqual((entry["args"]?.arrayValue ?? []).compactMap { $0.stringValue }, ["-y", "some-server"])
        let env = entry["env"]?.arrayValue ?? []
        XCTAssertEqual(env.count, 1)
        XCTAssertEqual(object(env[0])["name"]?.stringValue, "API_TOKEN")
        XCTAssertEqual(object(env[0])["value"]?.stringValue, "env-value-xyz")
    }

    func testStdioEntryWithoutConfirmedWarningIsRefusedOnSave() {
        let entry = MCPServerEntry(name: "local", transport: .stdio, command: "npx", stdioAcknowledged: false)
        XCTAssertThrowsError(try model.upsert(entry)) { error in
            XCTAssertEqual(error as? MCPServerEntryError, .stdioNotAcknowledged)
        }
        XCTAssertEqual(model.servers, [])
    }

    /// An unconfirmed stdio entry already on disk (written by hand or by an older build) is still
    /// left out of the payload.
    func testStdioEntryWithoutConfirmedWarningIsLeftOutOfPayload() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = """
        {"version":1,"servers":[{"id":"\(UUID().uuidString)","name":"local","transport":"stdio",
        "isEnabled":true,"url":null,"headerNames":[],"command":"npx","args":[],"envNames":[],
        "alwaysAllow":[],"stdioAcknowledged":false}]}
        """
        try Data(json.utf8).write(to: model.fileURL)
        let reloaded = MCPServersModel(fileURL: model.fileURL, values: values)
        XCTAssertNil(reloaded.loadError)
        XCTAssertEqual(reloaded.servers.count, 1)
        XCTAssertEqual(try reloaded.mcpServersPayload(for: gateway).count, 0)
    }

    func testHeadersAppearInPayloadAndNowhereOnDisk() throws {
        let marker = "hdr-\(UUID().uuidString)"
        _ = try http(headers: ["Authorization": "Bearer \(marker)"])

        let payload = try model.mcpServersPayload(for: gateway)
        let headers = object(payload.first)["headers"]?.arrayValue ?? []
        XCTAssertEqual(object(headers.first)["value"]?.stringValue, "Bearer \(marker)")

        // The file holds the name and the URL, never the value.
        let file = try String(contentsOf: model.fileURL, encoding: .utf8)
        XCTAssertTrue(file.contains("Authorization"))
        XCTAssertFalse(file.contains(marker))
        for root in [directory!, FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]] {
            XCTAssertFalse(try fileContains(marker, under: root), "a header value was written under \(root.lastPathComponent)")
        }
    }

    func testDisabledEntryIsLeftOut() throws {
        _ = try http(name: "on")
        _ = try http(name: "off", url: "https://other.example.com/mcp", enabled: false)
        let names = try model.mcpServersPayload(for: gateway).map { object($0)["name"]?.stringValue }
        XCTAssertEqual(names, ["on"])
    }

    func testAlwaysAllowAppearsOnlyWhenSet() throws {
        _ = try http(name: "with", alwaysAllow: ["search", "fetch"])
        _ = try http(name: "without", url: "https://b.example.com/mcp", alwaysAllow: [])
        let payload = try model.mcpServersPayload(for: gateway)
        let withList = object(payload[0])["alwaysAllow"]?.arrayValue?.compactMap { $0.stringValue }
        XCTAssertEqual(withList, ["search", "fetch"])
        XCTAssertNil(object(payload[1])["alwaysAllow"])
    }

    func testAlwaysAllowOnStdioEntry() throws {
        _ = try stdio(alwaysAllow: ["read_file"])
        let entry = object(try model.mcpServersPayload(for: gateway)[0])
        XCTAssertEqual(entry["alwaysAllow"]?.arrayValue?.compactMap { $0.stringValue }, ["read_file"])
    }

    // MARK: Who gets the list

    func testNonGatewayServerGetsNoList() throws {
        _ = try http()
        _ = try stdio()
        XCTAssertEqual(try model.mcpServersPayload(for: MCPPayloadContext(isGateway: false, agentSupportsHTTP: true)), [])
    }

    func testHTTPOmittedWhenAgentLacksHTTPButStdioStays() throws {
        _ = try http()
        _ = try stdio()
        let payload = try model.mcpServersPayload(for: MCPPayloadContext(isGateway: true, agentSupportsHTTP: false))
        XCTAssertEqual(payload.count, 1)
        XCTAssertEqual(object(payload[0])["command"]?.stringValue, "npx")
    }

    func testMissingStoredValueThrowsInsteadOfSendingWithoutIt() throws {
        let entry = MCPServerEntry(name: "needs-key", transport: .http, url: "https://k.example.com/mcp", headerNames: ["X-Key"])
        XCTAssertThrowsError(try model.upsert(entry)) { error in
            XCTAssertEqual(error as? MCPServerEntryError, .missingValue("X-Key"))
        }
        XCTAssertEqual(model.servers, [])
    }

    // MARK: Rules

    func testURLRules() {
        XCTAssertTrue(MCPServerEntry.urlAllowed("https://mcp.example.com/mcp"))
        XCTAssertTrue(MCPServerEntry.urlAllowed("http://localhost:8080/mcp"))
        XCTAssertTrue(MCPServerEntry.urlAllowed("http://127.0.0.1:8080/mcp"))
        XCTAssertFalse(MCPServerEntry.urlAllowed("http://example.com/mcp"))
        XCTAssertFalse(MCPServerEntry.urlAllowed("http://192.168.1.5/mcp"))
        XCTAssertFalse(MCPServerEntry.urlAllowed("ftp://example.com/mcp"))
        XCTAssertFalse(MCPServerEntry.urlAllowed("https://user:pw@example.com/mcp"))
        XCTAssertFalse(MCPServerEntry.urlAllowed("not a url"))
    }

    func testRejectedEntriesAreNotStored() throws {
        let badURL = MCPServerEntry(name: "a", transport: .http, url: "http://example.com/mcp")
        XCTAssertThrowsError(try model.upsert(badURL)) { XCTAssertEqual($0 as? MCPServerEntryError, .invalidURL) }

        let duplicateHeader = MCPServerEntry(name: "b", transport: .http, url: "https://b.example.com", headerNames: ["X-A", "x-a"])
        XCTAssertEqual(duplicateHeader.validationError(), .duplicateHeader)

        let badEnv = MCPServerEntry(name: "c", transport: .stdio, command: "run", envNames: ["1BAD"], stdioAcknowledged: true)
        XCTAssertEqual(badEnv.validationError(), .invalidEnvName)

        let unconfirmed = MCPServerEntry(name: "d", transport: .stdio, command: "run")
        XCTAssertEqual(unconfirmed.validationError(), .stdioNotAcknowledged)

        XCTAssertEqual(model.servers, [])
    }

    func testStdioWarningTextIsTheOwnersWording() {
        XCTAssertEqual(MCPServerWarning.stdio, "This runs a command inside the project container. It must be configured on the gateway.")
    }

    // MARK: Edit, delete, disk state

    func testEditKeepsStoredValueWhenFieldIsEmptyAndRemovesDroppedHeader() throws {
        var entry = try http(headers: ["Authorization": "Bearer keep-me", "X-Old": "drop-me"])
        entry.headerNames = ["Authorization"]
        try model.upsert(entry, headerValues: ["Authorization": ""])

        let payload = try model.mcpServersPayload(for: gateway)
        let headers = object(payload[0])["headers"]?.arrayValue ?? []
        XCTAssertEqual(headers.count, 1)
        XCTAssertEqual(object(headers[0])["value"]?.stringValue, "Bearer keep-me")
        let dropped = try values.get(entryId: entry.id, kind: .header, name: "X-Old")
        XCTAssertNil(dropped)
    }

    func testDeleteRemovesEntryAndItsValues() throws {
        let entry = try stdio(env: ["API_TOKEN": "gone-soon"])
        try model.remove(id: entry.id)
        XCTAssertEqual(model.servers, [])
        XCTAssertNil(try values.get(entryId: entry.id, kind: .env, name: "API_TOKEN"))
    }

    func testRemoveAllDeletesValuesAndFile() throws {
        let entry = try http()
        try model.removeAll()
        XCTAssertNil(try values.get(entryId: entry.id, kind: .header, name: "Authorization"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.fileURL.path))
    }

    func testListSurvivesReload() throws {
        _ = try http(name: "kept")
        let reloaded = MCPServersModel(fileURL: model.fileURL, values: values)
        XCTAssertEqual(reloaded.servers.map(\.name), ["kept"])
        XCTAssertEqual(try reloaded.mcpServersPayload(for: gateway).count, 1)
    }

    func testUnreadableFileIsNotOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: model.fileURL)
        let broken = MCPServersModel(fileURL: model.fileURL, values: values)
        XCTAssertNotNil(broken.loadError)
        XCTAssertThrowsError(try broken.upsert(MCPServerEntry(name: "x", transport: .http, url: "https://x.example.com")))
        XCTAssertThrowsError(try broken.mcpServersPayload(for: gateway))
        XCTAssertEqual(try String(contentsOf: model.fileURL, encoding: .utf8), "not json")
    }

    // MARK: Helpers

    private func fileContains(_ needle: String, under root: URL) throws -> Bool {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return false
        }
        let needleData = Data(needle.utf8)
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: url) else { continue }
            if data.range(of: needleData) != nil { return true }
        }
        return false
    }
}
