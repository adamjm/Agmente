import AgmenteTransport
import Foundation

// Adapter from this package's WebSocket protocols to the shared transport (D-017, PLAN 2.5).
public struct URLSessionWebSocketProvider: WebSocketProviding {
    public let tls: TransportTLSOptions

    public init(tls: TransportTLSOptions = TransportTLSOptions()) {
        self.tls = tls
    }

    public func makeConnection(url: URL) -> WebSocketConnection {
        TransportWebSocketConnection(NativeWebSocketConnection(url: url, tls: tls))
    }
}

final class TransportWebSocketConnection: WebSocketConnection {
    private let inner: NativeWebSocketConnection

    init(_ inner: NativeWebSocketConnection) {
        self.inner = inner
    }

    func connect(headers: [String: String]) async throws {
        try await mapped { try await inner.connect(headers: headers) }
    }

    func send(text: String) async throws {
        try await mapped { try await inner.send(text: text) }
    }

    func receive() async throws -> WebSocketEvent {
        let event = try await mapped { try await inner.receive() }
        switch event {
        case .connected:
            return .connected
        case .text(let text):
            return .text(text)
        case .binary(let data):
            return .binary(data)
        case .closed(let reason):
            return .closed(WebSocketCloseReason(code: reason.code, reason: reason.reason))
        }
    }

    func close() async {
        await inner.close()
    }

    func ping() async throws {
        try await mapped { try await inner.ping() }
    }

    /// Keep this package's error type for callers: TransportError.notConnected -> WebSocketError.notConnected.
    private func mapped<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch TransportError.notConnected {
            throw WebSocketError.notConnected
        }
    }
}
