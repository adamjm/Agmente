import XCTest
import ACP
import ACPClient
import enum ACP.ACPError
@testable import ACPCode

/// D-107 and FR-41: the gateway's MCP server list, the per-session set, and the new-session sheet's rules.
/// Every test uses a fake gateway and an isolated UserDefaults suite. Nothing touches the network.
final class GatewayMCPCallFake: GatewayCalling, @unchecked Sendable {
    var calls: [(method: String, params: ACP.Value?)] = []
    var results: [String: ACP.Value] = [:]
    var errors: [String: Error] = [:]

    func gatewayCall(method: String, params: ACP.Value?) async throws -> ACP.Value {
        calls.append((method, params))
        if let error = errors[method] { throw error }
        return results[method] ?? .null
    }

    func params(_ method: String) -> ACP.Value? {
        calls.last(where: { $0.method == method })?.params ?? nil
    }
}

private func json(_ text: String) throws -> ACP.Value {
    try JSONDecoder().decode(ACP.Value.self, from: Data(text.utf8))
}

private func isolatedDefaults() -> UserDefaults {
    let suite = "acpcode.tests.mcp.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

private let listedJSON = """
{"servers":[
 {"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"filesystem","transport":"stdio","defaultEnabled":true},
 {"id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","name":"docs","transport":"http","url":"https://mcp.example.com/mcp","defaultEnabled":false},
 {"id":"cccccccccccccccccccccccccccccccc","name":"search","transport":"http","url":"https://search.example.net/","defaultEnabled":true}
]}
"""

private let a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
private let b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
private let c = "cccccccccccccccccccccccccccccccc"

private func catalog() -> [GatewayMCPServer] {
    [
        GatewayMCPServer(id: a, name: "filesystem", transport: "stdio", defaultEnabled: true),
        GatewayMCPServer(id: b, name: "docs", transport: "http", url: "https://mcp.example.com/mcp", defaultEnabled: false),
        GatewayMCPServer(id: c, name: "search", transport: "http", url: "https://search.example.net/", defaultEnabled: true)
    ]
}

final class GatewayMCPServersTests: XCTestCase {
    // MARK: List decoding and the wire call

    func testListDecodesEveryFieldTheGatewaySends() async throws {
        let fake = GatewayMCPCallFake()
        fake.results["_acpcode/mcp/servers/list"] = try json(listedJSON)
        let servers = try await GatewayClient(fake).mcpServers()

        XCTAssertEqual(servers.map(\.id), [a, b, c], "no entry is dropped")
        XCTAssertEqual(servers.map(\.name), ["filesystem", "docs", "search"])
        XCTAssertEqual(servers.map(\.transport), ["stdio", "http", "http"])
        XCTAssertEqual(servers.map(\.defaultEnabled), [true, false, true])
        XCTAssertNil(servers[0].url, "a stdio entry has no url")
        XCTAssertEqual(servers[1].host, "mcp.example.com")
        XCTAssertEqual(servers[0].transportLabel, "Local command")
        XCTAssertEqual(servers[1].transportLabel, "HTTP")
    }

    func testListKeepsAnUnknownTransportAndFillsMissingFields() async throws {
        let fake = GatewayMCPCallFake()
        fake.results["_acpcode/mcp/servers/list"] = try json(#"{"servers":[{"id":"\#(a)"},{"id":"\#(b)","name":"x","transport":"sse","defaultEnabled":true}]}"#)
        let servers = try await GatewayClient(fake).mcpServers()

        XCTAssertEqual(servers.count, 2, "an entry with only an id is kept")
        XCTAssertEqual(servers[0].name, a, "the name falls back to the id")
        XCTAssertEqual(servers[0].transport, "unknown")
        XCTAssertFalse(servers[0].defaultEnabled)
        XCTAssertEqual(servers[1].transportLabel, "Custom server")
    }

    func testTheListHasNoFieldForASecretOrACommand() throws {
        let fields = Mirror(reflecting: GatewayMCPServer(id: a, name: "n", transport: "stdio")).children.compactMap(\.label)
        XCTAssertEqual(fields.sorted(), ["defaultEnabled", "id", "name", "transport", "url"])
        // A secret the gateway might ever add is ignored, not read.
        let server = try JSONDecoder().decode(GatewayMCPServer.self, from: Data(#"{"id":"\#(a)","name":"n","transport":"stdio","command":"npx","args":["x"],"headers":[{"name":"Authorization","value":"s"}]}"#.utf8))
        XCTAssertEqual(server.name, "n")
        XCTAssertNil(server.url)
    }

    func testHostOnlyForAURL() {
        let withCredentials = GatewayMCPServer(id: a, name: "n", transport: "http", url: "https://user:pw@host.example.com:8443/x?token=1")
        XCTAssertEqual(withCredentials.host, "host.example.com")
        XCTAssertNil(GatewayMCPServer(id: a, name: "n", transport: "stdio").host)
    }

    func testTheListCallTakesNoParameters() async throws {
        let fake = GatewayMCPCallFake()
        fake.results["_acpcode/mcp/servers/list"] = try json(#"{"servers":[]}"#)
        _ = try await GatewayClient(fake).mcpServers()
        XCTAssertEqual(fake.calls.first?.method, "_acpcode/mcp/servers/list")
        XCTAssertEqual(fake.calls.first?.params, .object([:]))
    }

    func testAGatewayWithoutMCPSupportAnswersMethodNotFound() async {
        let fake = GatewayMCPCallFake()
        fake.errors["_acpcode/mcp/servers/list"] = ACPServiceError.rpc(id: .number(1), error: .methodNotFound(nil))
        do {
            _ = try await GatewayClient(fake).mcpServers()
            XCTFail("expected a refusal")
        } catch let error as GatewayError {
            XCTAssertTrue(error.isMethodNotFound)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: session/new key

    func testBuilderAddsTheKeyOnlyForAGatewayServer() {
        let ids = [a, b]
        let gateway = GatewayMCPChoice.sessionNewMeta(isGateway: true, enabledIDs: ids)
        XCTAssertEqual(gateway[GatewayMCPChoice.metaKey], .array([.string(a), .string(b)]))

        XCTAssertTrue(GatewayMCPChoice.sessionNewMeta(isGateway: false, enabledIDs: ids).isEmpty,
                      "a plain ACP server or Codex gets no key")
        XCTAssertTrue(GatewayMCPChoice.sessionNewMeta(isGateway: true, enabledIDs: nil).isEmpty,
                      "no chosen set sends no key, so the gateway uses its defaults")
    }

    func testAnEmptyChosenSetIsSentAsAnEmptyList() {
        let meta = GatewayMCPChoice.sessionNewMeta(isGateway: true, enabledIDs: [])
        XCTAssertEqual(meta[GatewayMCPChoice.metaKey], .array([]))
    }

    func testUnknownAndRepeatedIDsAreNeverSent() {
        let unknown = "dddddddddddddddddddddddddddddddd"
        XCTAssertEqual(GatewayMCPChoice.sendableIDs([a, unknown, b, a], catalog: catalog()), [a, b])
        XCTAssertEqual(GatewayMCPChoice.sendableIDs([unknown], catalog: catalog()), [])
    }

    func testAtMostThirtyTwoIDsAreSent() {
        let many = (0..<40).map { String(format: "%032x", $0) }
        let big = many.map { GatewayMCPServer(id: $0, name: $0, transport: "http") }
        XCTAssertEqual(GatewayMCPChoice.sendableIDs(many, catalog: big).count, 32)
    }

    func testSetEnabledSendsOnlyKnownIDs() async throws {
        let fake = GatewayMCPCallFake()
        fake.results["_acpcode/mcp/servers/setEnabled"] = try json(#"{"sessionId":"s1","enabled":["\#(a)"],"closed":true}"#)
        let result = try await GatewayClient(fake).setSessionMCPServers(sessionId: "s1", ids: [a, "dddddddddddddddddddddddddddddddd"], catalog: catalog())
        let sent = fake.params("_acpcode/mcp/servers/setEnabled")
        XCTAssertEqual(sent?["ids"], .array([.string(a)]))
        XCTAssertEqual(sent?["sessionId"], .string("s1"))
        XCTAssertEqual(result, GatewayMCPSetResult(sessionId: "s1", enabled: [a], closed: true))
    }

    func testTurnOpenRefusalIsTurnOpen() async {
        let fake = GatewayMCPCallFake()
        fake.errors["_acpcode/mcp/servers/setEnabled"] = ACPServiceError.rpc(id: .number(2), error: .serverError(code: -32001, message: "a turn is open in this session: wait for it to end"))
        do {
            _ = try await GatewayClient(fake).setSessionMCPServers(sessionId: "s1", ids: [a], catalog: catalog())
            XCTFail("expected turnOpen")
        } catch let error as GatewayMCPError {
            XCTAssertEqual(error, .turnOpen)
            XCTAssertEqual(GatewayMCPCopy.turnOpen, "Wait for the current answer to finish, then try again.")
            XCTAssertEqual(GatewayMCPCopy.failure(error), "Could not change the MCP servers. Try again.")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testAnotherRefusalIsNotTurnOpen() async {
        let fake = GatewayMCPCallFake()
        fake.errors["_acpcode/mcp/servers/setEnabled"] = ACPServiceError.rpc(id: .number(2), error: .invalidParams("unknown session"))
        do {
            _ = try await GatewayClient(fake).setSessionMCPServers(sessionId: "s1", ids: [a], catalog: catalog())
            XCTFail("expected a refusal")
        } catch let error as GatewayError {
            XCTAssertEqual(error, .rpc(code: -32602, message: "unknown session"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: Defaults, starting state, memory and the summary

    func testDefaultsComeFromDefaultEnabled() {
        XCTAssertEqual(GatewayMCPChoice.defaultIDs(catalog()), [a, c])
        XCTAssertEqual(GatewayMCPChoice.startingIDs(catalog: catalog(), memory: nil), [a, c])
    }

    func testARememberedChoiceWinsAndANewServerTakesItsDefault() {
        let memory = GatewayMCPMemory(enabled: [a], known: [a, b])
        let list = catalog() + [GatewayMCPServer(id: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", name: "new", transport: "stdio", defaultEnabled: true)]
        XCTAssertEqual(GatewayMCPChoice.startingIDs(catalog: list, memory: memory), [a, c, "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"],
                       "docs was seen and is off; search and new are not in the memory, so they take their defaults")
    }

    func testARemovedServerIsDroppedFromTheChoice() {
        let memory = GatewayMCPMemory(enabled: [a, "ffffffffffffffffffffffffffffffff"], known: [a, "ffffffffffffffffffffffffffffffff"])
        XCTAssertEqual(GatewayMCPChoice.startingIDs(catalog: [GatewayMCPServer(id: a, name: "n", transport: "stdio")], memory: memory), [a])
    }

    func testSummaryWords() {
        XCTAssertEqual(GatewayMCPChoice.summary(on: 3, total: 5), "3 of 5 on")
        XCTAssertEqual(GatewayMCPChoice.summary(on: 0, total: 5), "None on")
        XCTAssertEqual(GatewayMCPChoice.summary(on: 5, total: 5), "5 of 5 on")
    }

    func testProjectMemoryRoundTripsPerProject() {
        let defaults = isolatedDefaults()
        XCTAssertNil(GatewayMCPMemoryStore.projectChoice(projectId: "p1", defaults: defaults))
        let memory = GatewayMCPMemory(enabled: [a], known: [a, b])
        GatewayMCPMemoryStore.rememberProjectChoice(memory, projectId: "p1", defaults: defaults)
        XCTAssertEqual(GatewayMCPMemoryStore.projectChoice(projectId: "p1", defaults: defaults), memory)
        XCTAssertNil(GatewayMCPMemoryStore.projectChoice(projectId: "p2", defaults: defaults))
    }

    func testUnreadableMemoryIsTreatedAsAbsent() {
        let defaults = isolatedDefaults()
        defaults.set(Data("not json".utf8), forKey: "acpcode.mcp.projectChoice.p1")
        defaults.set(Data("not json".utf8), forKey: "acpcode.mcp.session.s1")
        XCTAssertNil(GatewayMCPMemoryStore.projectChoice(projectId: "p1", defaults: defaults))
        XCTAssertNil(GatewayMCPMemoryStore.sessionIDs(sessionId: "s1", defaults: defaults))
    }

    func testSessionSetRoundTrips() {
        let defaults = isolatedDefaults()
        XCTAssertNil(GatewayMCPMemoryStore.sessionIDs(sessionId: "s1", defaults: defaults))
        GatewayMCPMemoryStore.rememberSessionIDs([a, c], sessionId: "s1", defaults: defaults)
        XCTAssertEqual(GatewayMCPMemoryStore.sessionIDs(sessionId: "s1", defaults: defaults), [a, c])
    }

    // MARK: The catalog model the sheet and the header use

    @MainActor
    func testLoadedListGivesTheSummaryAndTheDefaults() async throws {
        let fake = GatewayMCPCallFake()
        fake.results["_acpcode/mcp/servers/list"] = try json(listedJSON)
        let model = GatewayMCPCatalogModel(clientProvider: { GatewayClient(fake) }, defaults: isolatedDefaults())
        await model.load(projectId: "p1")
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertTrue(model.showsSection)
        XCTAssertEqual(model.summary, "2 of 3 on")
        XCTAssertEqual(model.idsToSend, [a, c])
    }

    @MainActor
    func testNoServersHidesTheSectionAndSendsNoKey() async throws {
        let fake = GatewayMCPCallFake()
        fake.results["_acpcode/mcp/servers/list"] = try json(#"{"servers":[]}"#)
        let model = GatewayMCPCatalogModel(clientProvider: { GatewayClient(fake) }, defaults: isolatedDefaults())
        await model.load(projectId: "p1")
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertFalse(model.showsSection)
        XCTAssertNil(model.idsToSend)
    }

    @MainActor
    func testWithoutMCPSupportTheSectionIsHiddenAndNoKeyIsSent() async {
        let fake = GatewayMCPCallFake()
        fake.errors["_acpcode/mcp/servers/list"] = ACPServiceError.rpc(id: .number(1), error: .methodNotFound(nil))
        let model = GatewayMCPCatalogModel(clientProvider: { GatewayClient(fake) }, defaults: isolatedDefaults())
        await model.load(projectId: "p1")
        XCTAssertEqual(model.phase, .unsupported)
        XCTAssertFalse(model.showsSection)
        XCTAssertNil(model.idsToSend)
    }

    @MainActor
    func testAFailedLoadShowsTheRowAndStartsWithNoServers() async {
        let fake = GatewayMCPCallFake()
        fake.errors["_acpcode/mcp/servers/list"] = ACPServiceError.rpc(id: .number(1), error: .internalError("boom"))
        let model = GatewayMCPCatalogModel(clientProvider: { GatewayClient(fake) }, defaults: isolatedDefaults())
        await model.load(projectId: "p1")
        XCTAssertEqual(model.phase, .failed)
        XCTAssertTrue(model.showsSection)
        XCTAssertEqual(model.summary, "Not loaded")
        XCTAssertEqual(model.idsToSend, [], "the session starts with no MCP servers, as the copy says")
    }

    @MainActor
    func testNoConnectionIsAFailedLoad() async {
        let model = GatewayMCPCatalogModel(clientProvider: { nil }, defaults: isolatedDefaults())
        await model.load(projectId: "p1")
        XCTAssertEqual(model.phase, .failed)
    }

    @MainActor
    func testWhileLoadingNoKeyIsSent() {
        let model = GatewayMCPCatalogModel(clientProvider: { nil }, defaults: isolatedDefaults())
        XCTAssertNil(model.idsToSend)
    }

    @MainActor
    func testTogglesAreRememberedPerProject() async throws {
        let fake = GatewayMCPCallFake()
        fake.results["_acpcode/mcp/servers/list"] = try json(listedJSON)
        let defaults = isolatedDefaults()
        let model = GatewayMCPCatalogModel(clientProvider: { GatewayClient(fake) }, defaults: defaults)
        await model.load(projectId: "p1")
        model.setOn(b, true)
        model.setOn(a, false)
        XCTAssertEqual(model.idsToSend, [b, c])

        let again = GatewayMCPCatalogModel(clientProvider: { GatewayClient(fake) }, defaults: defaults)
        await again.load(projectId: "p1")
        XCTAssertEqual(again.idsToSend, [b, c], "the last choice for the project is remembered")

        let other = GatewayMCPCatalogModel(clientProvider: { GatewayClient(fake) }, defaults: defaults)
        await other.load(projectId: "p2")
        XCTAssertEqual(other.idsToSend, [a, c], "another project starts from the defaults")
    }

    @MainActor
    func testUseDefaultsAndBulkActions() async throws {
        let fake = GatewayMCPCallFake()
        fake.results["_acpcode/mcp/servers/list"] = try json(listedJSON)
        let model = GatewayMCPCatalogModel(clientProvider: { GatewayClient(fake) }, defaults: isolatedDefaults())
        await model.load(projectId: "p1")
        model.setAll(false)
        XCTAssertEqual(model.summary, "None on")
        model.setAll(true)
        XCTAssertEqual(model.idsToSend, [a, b, c])
        model.useDefaults()
        XCTAssertEqual(model.idsToSend, [a, c])
    }

    @MainActor
    func testSessionHeaderSavesTheSetAndRemembersIt() async throws {
        let fake = GatewayMCPCallFake()
        fake.results["_acpcode/mcp/servers/list"] = try json(listedJSON)
        fake.results["_acpcode/mcp/servers/setEnabled"] = try json(#"{"sessionId":"s1","enabled":["\#(b)"],"closed":true}"#)
        let defaults = isolatedDefaults()
        let model = GatewayMCPCatalogModel(clientProvider: { GatewayClient(fake) }, defaults: defaults)
        await model.load()
        model.select(ids: [b])
        try await model.saveSession("s1")
        XCTAssertEqual(GatewayMCPMemoryStore.sessionIDs(sessionId: "s1", defaults: defaults), [b])
        XCTAssertNil(GatewayMCPMemoryStore.projectChoice(projectId: "p1", defaults: defaults), "a header writes no project choice")
    }

    @MainActor
    func testSessionHeaderTurnOpenKeepsTheSavedSet() async throws {
        let fake = GatewayMCPCallFake()
        fake.results["_acpcode/mcp/servers/list"] = try json(listedJSON)
        fake.errors["_acpcode/mcp/servers/setEnabled"] = ACPServiceError.rpc(id: .number(3), error: .serverError(code: -32001, message: "turn open"))
        let defaults = isolatedDefaults()
        GatewayMCPMemoryStore.rememberSessionIDs([a], sessionId: "s1", defaults: defaults)
        let model = GatewayMCPCatalogModel(clientProvider: { GatewayClient(fake) }, defaults: defaults)
        await model.load()
        model.select(ids: [a])
        do {
            try await model.saveSession("s1")
            XCTFail("expected turnOpen")
        } catch let error as GatewayMCPError {
            XCTAssertEqual(error, .turnOpen)
        }
        XCTAssertEqual(GatewayMCPMemoryStore.sessionIDs(sessionId: "s1", defaults: defaults), [a], "a refused change is not stored")
    }
}
