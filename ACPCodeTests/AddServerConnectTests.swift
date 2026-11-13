import XCTest
import ACP
import ACPClient
@testable import ACPCode

/// Add Server opens exactly one connection to the server it adds (add-server connect bug).
/// Each connection the manager opens is counted by the serviceFactory seam.
@MainActor
final class AddServerConnectTests: XCTestCase {

    /// Counts the connections the manager opens, by port.
    private final class ConnectionLog: @unchecked Sendable {
        private let lock = NSLock()
        private var ports: [Int] = []
        func record(_ url: URL) { lock.lock(); ports.append(url.port ?? -1); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return ports.count }
        var recordedPorts: [Int] { lock.lock(); defer { lock.unlock() }; return ports }
    }

    /// A fake socket that answers `initialize` with an ACP result and nothing else.
    private final class FakeSocket: WebSocketConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var events: [WebSocketEvent] = []
        func connect(headers: [String: String]) async throws {}
        func send(text: String) async throws {
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  object["method"] as? String == "initialize",
                  let id = object["id"] as? Int else { return }
            let reply = "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":{\"protocolVersion\":1,\"agentCapabilities\":{\"loadSession\":true}}}"
            lock.lock(); events.append(.text(reply)); lock.unlock()
        }
        func receive() async throws -> WebSocketEvent {
            while true {
                lock.lock()
                if !events.isEmpty { let e = events.removeFirst(); lock.unlock(); return e }
                lock.unlock()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        func close() async {}
        func ping() async throws {}
    }

    private struct Provider: WebSocketProviding, @unchecked Sendable {
        func makeConnection(url: URL) -> WebSocketConnection { FakeSocket() }
    }

    private func makeModel(_ log: ConnectionLog) -> AppViewModel {
        let suite = "AddServerConnectTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false, serviceFactory: { config, _ in
            log.record(config.endpoint)
            return ACPService(client: ACPClient(configuration: config, socketProvider: Provider()))
        })
        return AppViewModel(storage: .inMemory(), defaults: defaults, connectionManager: manager, shouldStartNetworkMonitoring: false, shouldConnectOnStartup: false)
    }

    /// Polls `condition` for up to five seconds. The connect runs on the main actor.
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        return condition()
    }

    /// Lets any extra connect start, so a duplicate would show up in the count.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    func testAddingAServerWithNoConnectionConnectsItOnce() async throws {
        let log = ConnectionLog()
        let model = makeModel(log)
        model.addServer(name: "Gateway A", scheme: "ws", host: "localhost:2345", token: "", cfAccessClientId: "", cfAccessClientSecret: "", workingDirectory: "/tmp")
        let connected = await waitUntil { log.count >= 1 }
        XCTAssertTrue(connected, "adding a server did not connect it")
        await settle()
        XCTAssertEqual(log.recordedPorts, [2345])
    }

    func testAddingASecondServerWhileConnectedConnectsOnlyTheNewOne() async throws {
        let log = ConnectionLog()
        let model = makeModel(log)
        model.addServer(name: "Gateway A", scheme: "ws", host: "localhost:2345", token: "", cfAccessClientId: "", cfAccessClientSecret: "", workingDirectory: "/tmp")
        let firstConnected = await waitUntil { log.count >= 1 }
        XCTAssertTrue(firstConnected)
        model.addServer(name: "Gateway B", scheme: "ws", host: "localhost:2346", token: "", cfAccessClientId: "", cfAccessClientSecret: "", workingDirectory: "/tmp")
        let secondConnected = await waitUntil { log.count >= 2 }
        XCTAssertTrue(secondConnected, "the second server was not connected")
        await settle()
        // selectServer replaces the existing connection with one to the new server; no third connect follows.
        XCTAssertEqual(log.recordedPorts, [2345, 2346])
    }

    func testAddingACodexServerConnectsItOnce() async throws {
        let log = ConnectionLog()
        let model = makeModel(log)
        model.addServer(name: "Codex", scheme: "ws", host: "localhost:2347", token: "", cfAccessClientId: "", cfAccessClientSecret: "", workingDirectory: "/tmp", serverType: .codexAppServer)
        let connected = await waitUntil { log.count >= 1 }
        XCTAssertTrue(connected, "adding a Codex server did not connect it")
        await settle()
        XCTAssertEqual(log.recordedPorts, [2347])
    }
}
