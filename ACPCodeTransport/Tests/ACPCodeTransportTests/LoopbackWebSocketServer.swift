import CryptoKit
import Foundation
import Network

/// A minimal WebSocket server on 127.0.0.1 for transport tests. One client at a time.
/// After the handshake it runs `script` with a handle that can send raw bytes and read client frames.
final class LoopbackWebSocketServer: @unchecked Sendable {
    struct Client: Sendable {
        let connection: NWConnection

        func sendRaw(_ data: Data) async throws {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { c.resume(throwing: error) } else { c.resume() }
                })
            }
        }

        /// Send one unmasked server frame.
        func sendFrame(opcode: UInt8, payload: Data, fin: Bool = true) async throws {
            try await sendRaw(Self.frameHeader(opcode: opcode, length: UInt64(payload.count), fin: fin) + payload)
        }

        static func frameHeader(opcode: UInt8, length: UInt64, fin: Bool = true) -> Data {
            var frame = Data([(fin ? 0x80 : 0x00) | (opcode & 0x0F)])
            if length <= 125 {
                frame.append(UInt8(length))
            } else if length <= 65_535 {
                frame.append(126)
                frame.append(UInt8((length >> 8) & 0xFF))
                frame.append(UInt8(length & 0xFF))
            } else {
                frame.append(127)
                for shift in stride(from: 56, through: 0, by: -8) {
                    frame.append(UInt8((length >> UInt64(shift)) & 0xFF))
                }
            }
            return frame
        }

        /// Read one masked client frame. Returns (opcode, unmasked payload), or nil when the client closed.
        func readFrame() async throws -> (UInt8, Data)? {
            guard let head = try await read(2) else { return nil }
            let opcode = head[0] & 0x0F
            var length = UInt64(head[1] & 0x7F)
            if length == 126, let ext = try await read(2) {
                length = (UInt64(ext[0]) << 8) | UInt64(ext[1])
            } else if length == 127, let ext = try await read(8) {
                length = ext.reduce(0) { ($0 << 8) | UInt64($1) }
            }
            guard let mask = try await read(4) else { return nil }
            let body = length == 0 ? Data() : (try await read(Int(length)) ?? Data())
            let payload = Data(body.enumerated().map { $0.element ^ mask[$0.offset % 4] })
            return (opcode, payload)
        }

        func read(_ count: Int) async throws -> Data? {
            var out = Data()
            while out.count < count {
                let chunk: Data? = try await withCheckedThrowingContinuation { c in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: count - out.count) { data, _, done, error in
                        if let error { c.resume(throwing: error); return }
                        if let data, !data.isEmpty { c.resume(returning: data); return }
                        c.resume(returning: done ? nil : Data())
                    }
                }
                guard let chunk else { return nil }
                out.append(chunk)
            }
            return out
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackWebSocketServer")
    private let script: @Sendable (Client) async throws -> Void
    /// Bytes the server has written after the handshake (for memory checks in tests).
    private(set) var port: UInt16 = 0

    init(script: @escaping @Sendable (Client) async throws -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.script = script
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let resumed = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if resumed.take() { c.resume() }
                case .failed(let error): if resumed.take() { c.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { [script, queue] connection in
                connection.start(queue: queue)
                Task {
                    let client = Client(connection: connection)
                    do {
                        try await Self.handshake(client)
                        try await script(client)
                    } catch {
                        connection.cancel()
                    }
                }
            }
            listener.start(queue: queue)
        }
        port = listener.port?.rawValue ?? 0
        return URL(string: "ws://127.0.0.1:\(port)/")!
    }

    func stop() {
        listener.cancel()
    }

    private static func handshake(_ client: Client) async throws {
        var request = Data()
        let end = Data([13, 10, 13, 10])
        while request.range(of: end) == nil {
            guard let byte = try await client.read(1) else { throw URLError(.badServerResponse) }
            request.append(byte)
        }
        let text = String(decoding: request, as: UTF8.self)
        let keyLine = text.split(separator: "\r\n").first { $0.lowercased().hasPrefix("sec-websocket-key:") }
        let key = keyLine.map { String($0.split(separator: ":", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces) } ?? ""
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        try await client.sendRaw(Data(response.utf8))
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
