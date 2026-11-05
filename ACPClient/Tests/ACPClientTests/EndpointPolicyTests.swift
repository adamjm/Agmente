import Foundation
import XCTest
@testable import ACPClient
import ACPClientMocks

/// T-15 (FR-11): a URL refused by the endpoint policy never reaches makeConnection, and is not retried.
@MainActor
final class EndpointPolicyTests: XCTestCase {
    private struct Refused: Error {}

    /// Counts makeConnection calls.
    private final class RecordingProvider: WebSocketProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var _urls: [URL] = []
        var urls: [URL] { lock.lock(); defer { lock.unlock() }; return _urls }
        let connection = MockWebSocketConnection()
        func makeConnection(url: URL) -> WebSocketConnection {
            lock.lock(); _urls.append(url); lock.unlock()
            return connection
        }
    }

    private func makeManager(_ provider: RecordingProvider, defaults: UserDefaults) -> ACPClientManager {
        ACPClientManager(
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            serviceFactory: { config, encoder in
                ACPService(client: ACPClient(configuration: config, socketProvider: provider, logger: NoOpLogger(), encoder: encoder))
            }
        )
    }

    func testRefusedEndpointMakesNoConnection() async throws {
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let provider = RecordingProvider()
        let manager = makeManager(provider, defaults: defaults)
        manager.endpointPolicy = { url in url.scheme == "ws" ? Refused() : nil }

        for url in ["ws://example.com", "ws://192.168.1.5", "ws://100.100.1.1", "ws://127.0.0.1"] {
            let ok = await manager.connectAndWait(config: ACPConnectionConfig(endpoint: URL(string: url)!))
            XCTAssertFalse(ok, url)
            if case .failed(let error) = manager.connectionState {
                XCTAssertTrue(error is Refused, url)
            } else {
                XCTFail("expected failed state for \(url)")
            }
        }
        // Give any (wrong) reconnect a chance to fire.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(provider.urls, [], "a refused endpoint must not reach makeConnection")
    }

    func testAllowedEndpointReachesProvider() async throws {
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let provider = RecordingProvider()
        let manager = makeManager(provider, defaults: defaults)
        manager.endpointPolicy = { url in url.scheme == "ws" ? Refused() : nil }
        _ = await manager.connectAndWait(config: ACPConnectionConfig(endpoint: URL(string: "wss://example.com")!))
        XCTAssertEqual(provider.urls.map(\.absoluteString), ["wss://example.com"])
        manager.disconnect()
    }
}
