import XCTest
import ACP
import ACPClient
@testable import Agmente

// RESULTS 2026-11-07 (T-35 on screen): a failed session/new removed the placeholder and showed nothing.
// These tests run the real create path against a fake WebSocket (no network): the agent's error must
// reach `sessionCreateError` with the text the person reads.
@MainActor
final class SessionCreateAuthErrorTests: XCTestCase {
    private static let authText = "Bob needs authentication. Set BOB_API_KEY on the gateway host."

    private final class FakeConnection: WebSocketConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var events: [WebSocketEvent] = []
        private var sent: [String] = []

        func connect(headers: [String: String]) async throws {}

        func send(text: String) async throws {
            lock.lock()
            sent.append(text)
            lock.unlock()
        }

        func receive() async throws -> WebSocketEvent {
            while true {
                lock.lock()
                if !events.isEmpty {
                    let event = events.removeFirst()
                    lock.unlock()
                    return event
                }
                lock.unlock()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }

        func close() async {}
        func ping() async throws {}

        func enqueue(_ event: WebSocketEvent) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        func sentTexts() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return sent
        }
    }

    private struct FakeProvider: WebSocketProviding, @unchecked Sendable {
        let connection: FakeConnection

        func makeConnection(url: URL) -> WebSocketConnection {
            connection
        }
    }

    private func requests(_ connection: FakeConnection, method: String) -> [[String: Any]] {
        connection.sentTexts().compactMap { text -> [String: Any]? in
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["method"] as? String == method else { return nil }
            return object
        }
    }

    private func waitForRequest(_ connection: FakeConnection, method: String) async -> [String: Any]? {
        for _ in 0..<200 {
            if let request = requests(connection, method: method).first { return request }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    private func enqueueResponse(_ connection: FakeConnection, id: Int, result: ACP.Value) throws {
        let response = ACPWireMessage.response(.init(id: .int(id), result: result))
        let text = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        connection.enqueue(.text(text))
    }

    private func enqueueError(_ connection: FakeConnection, id: Int, error: ACPError) throws {
        let response = ACPWireMessage.response(.init(id: .int(id), error: error))
        let text = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        connection.enqueue(.text(text))
    }

    /// A connected, initialized ACP server whose fake agent answers `session/new` with `error`.
    private func makeServer(failingSessionNewWith error: ACPError) async throws -> (ServerViewModel, FakeConnection) {
        let connection = FakeConnection()
        let client = ACPClient(
            configuration: .init(endpoint: URL(string: "ws://localhost:1234")!, pingInterval: nil),
            socketProvider: FakeProvider(connection: connection)
        )
        let service = ACPService(client: client)
        try await service.connect()

        let suiteName = "SessionCreateAuthErrorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)
        manager.setServiceForTesting(service)

        Task {
            guard let initRequest = await self.waitForRequest(connection, method: "initialize"),
                  let initId = initRequest["id"] as? Int else { return }
            try? self.enqueueResponse(connection, id: initId, result: .object(["status": .string("ok")]))
        }
        let initialized = await manager.initializeAndWait(
            payload: ACPInitializationPayload(clientName: "Agmente iOS", clientVersion: "0.1.0")
        )
        XCTAssertTrue(initialized)

        Task {
            guard let newRequest = await self.waitForRequest(connection, method: "session/new"),
                  let newId = newRequest["id"] as? Int else { return }
            try? self.enqueueError(connection, id: newId, error: error)
        }

        let serverViewModel = ServerViewModel(
            id: UUID(),
            name: "Local",
            scheme: "ws",
            host: "localhost:1234",
            token: "",
            workingDirectory: "/tmp",
            connectionManager: manager,
            getService: { manager.service },
            append: { _ in },
            logWire: { _, _ in },
            cacheDelegate: nil,
            storage: SessionStorage.inMemory()
        )
        return (serverViewModel, connection)
    }

    private func waitForCreateError(_ serverViewModel: ServerViewModel) async -> String? {
        for _ in 0..<300 {
            if let message = serverViewModel.sessionCreateError { return message }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    func testAuthenticationRequiredCreateFailureShowsAuthText() async throws {
        let (serverViewModel, connection) = try await makeServer(
            failingSessionNewWith: .serverError(code: -32000, message: "Authentication required")
        )

        serverViewModel.sendNewSession()

        let message = await waitForCreateError(serverViewModel)
        XCTAssertEqual(message, Self.authText)
        XCTAssertNil(serverViewModel.selectedSessionId, "the placeholder is still removed on failure")
        XCTAssertFalse(requests(connection, method: "session/prompt").count > 0)
    }

    func testOtherCreateFailureShowsItsOwnMessage() async throws {
        let (serverViewModel, _) = try await makeServer(
            failingSessionNewWith: .serverError(code: -32603, message: "Directory does not exist or cannot be accessed")
        )

        serverViewModel.sendNewSession()

        let message = await waitForCreateError(serverViewModel)
        XCTAssertEqual(message, "Directory does not exist or cannot be accessed")
    }

    func testDismissClearsCreateError() async throws {
        let (serverViewModel, _) = try await makeServer(
            failingSessionNewWith: .serverError(code: -32000, message: "Authentication required")
        )

        serverViewModel.sendNewSession()
        _ = await waitForCreateError(serverViewModel)
        serverViewModel.dismissSessionCreateError()

        XCTAssertNil(serverViewModel.sessionCreateError)
    }
}
