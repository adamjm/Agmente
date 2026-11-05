import Foundation
import XCTest
@testable import AgmenteTransport

/// T-16 (FR-12, NFR-3): an oversize message closes the connection with 1009, and its payload is
/// never buffered.
final class MessageSizeCapTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _closeCode: Int?
        var closeCode: Int? { lock.lock(); defer { lock.unlock() }; return _closeCode }
        func set(_ code: Int) { lock.lock(); _closeCode = code; lock.unlock() }
    }

    /// After sending `frames`, read client frames until a close arrives and record its code.
    private func makeServer(_ box: Box, frames: @escaping @Sendable (LoopbackWebSocketServer.Client) async throws -> Void) throws -> LoopbackWebSocketServer {
        try LoopbackWebSocketServer { client in
            try await frames(client)
            while let (opcode, payload) = try await client.readFrame() {
                if opcode == 0x8, payload.count >= 2 {
                    box.set(Int(payload[0]) << 8 | Int(payload[1]))
                    return
                }
            }
        }
    }

    private func waitForCloseCode(_ box: Box) async -> Int? {
        for _ in 0..<100 where box.closeCode == nil { try? await Task.sleep(nanoseconds: 20_000_000) }
        return box.closeCode
    }

    func testT16A17MiBFrameHeaderClosesWith1009WithoutBufferingThePayload() async throws {
        let box = Box()
        let server = try makeServer(box) { client in
            // Header for a 17 MiB text frame, then only 64 KiB of it. The client must not wait for the rest.
            let length = UInt64(17 * 1024 * 1024)
            try await client.sendRaw(LoopbackWebSocketServer.Client.frameHeader(opcode: 0x1, length: length) + Data(count: 64 * 1024))
        }
        let url = try await server.start()
        defer { server.stop() }

        let connection = NativeWebSocketConnection(url: url) // default cap: 16 MiB
        try await connection.connect(headers: [:])
        let event = try await connection.receive()
        XCTAssertEqual(event, .closed(TransportCloseReason(code: 1009, reason: "message too big")))
        let buffered = await connection.bufferedByteCount
        XCTAssertEqual(buffered, 0, "buffers are dropped after the close")
        let code = await waitForCloseCode(box)
        XCTAssertEqual(code, 1009, "the client sent close 1009 to the server")
    }

    func testFrameAtTheCapIsAccepted() async throws {
        let server = try LoopbackWebSocketServer { client in
            try await client.sendFrame(opcode: 0x2, payload: Data(count: 1024))
            _ = try await client.readFrame()
        }
        let url = try await server.start()
        defer { server.stop() }
        let connection = NativeWebSocketConnection(url: url, maxMessageBytes: 1024)
        try await connection.connect(headers: [:])
        let event = try await connection.receive()
        XCTAssertEqual(event, .binary(Data(count: 1024)))
        await connection.close()
    }

    func testFragmentsOverTheCapTogetherCloseWith1009() async throws {
        let box = Box()
        let server = try makeServer(box) { client in
            try await client.sendFrame(opcode: 0x1, payload: Data(repeating: 0x61, count: 600), fin: false)
            try await client.sendFrame(opcode: 0x0, payload: Data(repeating: 0x61, count: 600), fin: true)
        }
        let url = try await server.start()
        defer { server.stop() }
        let connection = NativeWebSocketConnection(url: url, maxMessageBytes: 1024)
        try await connection.connect(headers: [:])
        let event = try await connection.receive()
        XCTAssertEqual(event, .closed(TransportCloseReason(code: 1009, reason: "message too big")))
        let code = await waitForCloseCode(box)
        XCTAssertEqual(code, 1009)
    }

    func testControlFramesAreNotCountedAgainstTheCap() async throws {
        // A ping (control frame, at most 125 bytes) with a small cap still gets answered.
        let server = try LoopbackWebSocketServer { client in
            try await client.sendFrame(opcode: 0x9, payload: Data(count: 100))
            try await client.sendFrame(opcode: 0x1, payload: Data("ok".utf8))
            _ = try await client.readFrame()
            _ = try await client.readFrame()
        }
        let url = try await server.start()
        defer { server.stop() }
        let connection = NativeWebSocketConnection(url: url, maxMessageBytes: 10)
        try await connection.connect(headers: [:])
        let event = try await connection.receive()
        XCTAssertEqual(event, .text("ok"))
        await connection.close()
    }
}
