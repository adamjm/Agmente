import Foundation
import Network
import XCTest
@testable import ACPCodeTransport

final class NativeWebSocketConnectionTests: XCTestCase {
    func testSendBeforeConnectThrowsNotConnected() async {
        let connection = NativeWebSocketConnection(url: URL(string: "ws://127.0.0.1:1/")!)
        do {
            try await connection.send(text: "x")
            XCTFail("expected notConnected")
        } catch {
            XCTAssertEqual(error as? TransportError, .notConnected)
        }
    }

    func testTextRoundTripAndServerClose() async throws {
        let server = try LoopbackWebSocketServer { client in
            // Echo one text frame, then close with 4001.
            guard let (opcode, payload) = try await client.readFrame() else { return }
            XCTAssertEqual(opcode, 0x1)
            try await client.sendFrame(opcode: 0x1, payload: payload)
            try await client.sendFrame(opcode: 0x8, payload: Data([0x0F, 0xA1]) + Data("bye".utf8))
        }
        let url = try await server.start()
        defer { server.stop() }

        let connection = NativeWebSocketConnection(url: url)
        try await connection.connect(headers: ["Authorization": "Bearer t"])
        try await connection.send(text: "hello")
        let echo = try await connection.receive()
        XCTAssertEqual(echo, .text("hello"))
        let closed = try await connection.receive()
        XCTAssertEqual(closed, .closed(TransportCloseReason(code: 4001, reason: "bye")))
        await connection.close()
    }

    func testFracpcodedMessageIsReassembled() async throws {
        let server = try LoopbackWebSocketServer { client in
            try await client.sendFrame(opcode: 0x1, payload: Data("ab".utf8), fin: false)
            try await client.sendFrame(opcode: 0x0, payload: Data("cd".utf8), fin: true)
            _ = try await client.readFrame()
        }
        let url = try await server.start()
        defer { server.stop() }

        let connection = NativeWebSocketConnection(url: url)
        try await connection.connect(headers: [:])
        let message = try await connection.receive()
        XCTAssertEqual(message, .text("abcd"))
        await connection.close()
    }

    /// A server that accepts TCP but never answers the WebSocket handshake. Upstream code waited
    /// forever here; connect() must now fail after its deadline.
    func testConnectTimesOutWhenTheServerNeverAnswers() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "silent-server")
        // The listener keeps accepted connections alive by retaining them in this box (on `queue`).
        final class Held: @unchecked Sendable { var connections: [NWConnection] = [] }
        let held = Held()
        listener.newConnectionHandler = { connection in
            held.connections.append(connection) // keep it open, never read or write
            connection.start(queue: queue)
        }
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: queue)
        await fulfillment(of: [ready], timeout: 5)
        defer { listener.cancel() }

        let port = try XCTUnwrap(listener.port?.rawValue)
        let connection = NativeWebSocketConnection(url: URL(string: "ws://127.0.0.1:\(port)/")!, connectTimeout: 0.5)
        let started = Date()
        do {
            try await connection.connect(headers: [:])
            XCTFail("expected a timeout")
        } catch NativeWebSocketConnection.NativeWebSocketError.connectTimeout {
            XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        }
        _ = held
    }
}
