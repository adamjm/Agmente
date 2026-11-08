import CryptoKit
import Foundation
import Network

// Shared WebSocket client on NWConnection, used by ACPClient and AppServerClient (D-017, PLAN 2.5).
// Moved unchanged from the two upstream URLSessionWebSocketProvider.swift copies.

public enum TransportEvent: Equatable, Sendable {
    case connected
    case text(String)
    case binary(Data)
    case closed(TransportCloseReason)
}

public struct TransportCloseReason: Equatable, Sendable {
    public var code: Int
    public var reason: String?

    public init(code: Int, reason: String? = nil) {
        self.code = code
        self.reason = reason
    }
}

public enum TransportError: Error, Equatable {
    case notConnected
}

public actor NativeWebSocketConnection {
    /// NFR-3 / FR-12: the largest message (one frame, or a reassembled fracpcoded message).
    public static let defaultMaxMessageBytes = 16 * 1024 * 1024
    /// WebSocket close code for "message too big".
    public static let closeCodeMessageTooBig = 1009

    private struct ParsedFrame {
        let fin: Bool
        let opcode: UInt8
        let payload: Data
    }

    public enum NativeWebSocketError: LocalizedError {
        case invalidURL(URL)
        case unsupportedScheme(String)
        case invalidHTTPResponse
        case invalidStatusCode(Int)
        case missingAcceptHeader
        case invalidAcceptHeader
        case disconnected
        case unsupportedFrameLength(UInt64)
        case malformedFrame
        case messageTooBig(UInt64)
        case connectTimeout(lastState: String)

        public var errorDescription: String? {
            switch self {
            case .invalidURL(let url):
                return "Invalid WebSocket URL: \(url.absoluteString)"
            case .unsupportedScheme(let scheme):
                return "Unsupported WebSocket scheme: \(scheme)"
            case .invalidHTTPResponse:
                return "Invalid WebSocket handshake response"
            case .invalidStatusCode(let statusCode):
                return "Unexpected WebSocket handshake status code: \(statusCode)"
            case .missingAcceptHeader:
                return "WebSocket handshake missing Sec-WebSocket-Accept"
            case .invalidAcceptHeader:
                return "WebSocket handshake returned an invalid Sec-WebSocket-Accept header"
            case .disconnected:
                return "WebSocket is disconnected"
            case .unsupportedFrameLength(let length):
                return "WebSocket frame length is unsupported: \(length)"
            case .malformedFrame:
                return "Malformed WebSocket frame"
            case .connectTimeout(let lastState):
                return "WebSocket connection timed out (last state: \(lastState))"
            case .messageTooBig(let length):
                return "WebSocket message of \(length) bytes is over the limit"
            }
        }
    }

    private static let handshakeGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    private static let headerDelimiter = Data([13, 10, 13, 10]) // CRLFCRLF

    private let url: URL
    private let maxMessageBytes: Int
    private let tls: TransportTLSOptions
    private let connectTimeout: TimeInterval
    private var lastStateDescription = "setup"
    private var connectTimeoutFired = false
    private let queue = DispatchQueue(label: "ACPCodeTransport.NativeWebSocketConnection")

    private var connection: NWConnection?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var readBuffer = Data()
    private var fracpcodedOpcode: UInt8?
    private var fracpcodedPayload = Data()
    private var handshakeComplete = false

    public init(
        url: URL,
        maxMessageBytes: Int = NativeWebSocketConnection.defaultMaxMessageBytes,
        tls: TransportTLSOptions = TransportTLSOptions(),
        connectTimeout: TimeInterval = 15
    ) {
        self.url = url
        self.maxMessageBytes = maxMessageBytes
        self.tls = tls
        self.connectTimeout = connectTimeout
    }

    /// Bytes waiting in the read buffer (tests check that an oversize frame is never buffered).
    var bufferedByteCount: Int { readBuffer.count }

    public func connect(headers: [String: String]) async throws {
        guard connection == nil else { return }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host else {
            throw NativeWebSocketError.invalidURL(url)
        }

        let scheme = (components.scheme ?? "").lowercased()
        guard scheme == "ws" || scheme == "wss" else {
            throw NativeWebSocketError.unsupportedScheme(scheme)
        }

        let defaultPort = scheme == "wss" ? 443 : 80
        let portValue = components.port ?? defaultPort
        guard let port = NWEndpoint.Port(rawValue: UInt16(portValue)) else {
            throw NativeWebSocketError.invalidURL(url)
        }

        let parameters: NWParameters = {
            if scheme == "wss" {
                let tlsOptions = NWProtocolTLS.Options()
                tls.apply(to: tlsOptions, queue: queue)
                return NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
            }
            return NWParameters.tcp
        }()

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: port,
            using: parameters
        )

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handleConnectionState(state) }
        }

        self.connection = connection
        self.readBuffer.removeAll(keepingCapacity: false)
        self.fracpcodedOpcode = nil
        self.fracpcodedPayload.removeAll(keepingCapacity: false)
        self.handshakeComplete = false
        self.connectTimeoutFired = false

        // Upstream waited for .ready or .failed with no limit; a connection stuck in .preparing (for
        // example a TLS peer that never answers) then hung the caller forever.
        let timeout = connectTimeout
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.connectTimedOut()
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectContinuation = continuation
            connection.start(queue: queue)
        }

        do {
            let path = buildRequestPath(from: components)
            let hostHeader = buildHostHeader(host: host, explicitPort: components.port)
            try await performHandshake(path: path, hostHeader: hostHeader, headers: headers)
            handshakeComplete = true
        } catch {
            connection.cancel()
            self.connection = nil
            if connectTimeoutFired { throw NativeWebSocketError.connectTimeout(lastState: lastStateDescription) }
            throw error
        }
    }

    public func send(text: String) async throws {
        guard handshakeComplete else { throw TransportError.notConnected }
        let payload = Data(text.utf8)
        let frame = makeClientFrame(opcode: 0x1, payload: payload)
        try await sendRaw(frame)
    }

    public func receive() async throws -> TransportEvent {
        guard handshakeComplete else { throw TransportError.notConnected }

        while true {
            // Drain every complete frame already buffered before reading the network again.
            // (Upstream read the network after a ping or a non-final fragment even when the next
            // frame was already in the buffer, which could stall the read.)
            do {
                while let frame = try parseFrameFromBuffer() {
                    if let event = try await handle(frame) {
                        return event
                    }
                }
            } catch NativeWebSocketError.messageTooBig {
                return await closeMessageTooBig()
            }
            let chunk = try await receiveRaw()
            if chunk.isEmpty {
                return .closed(TransportCloseReason(code: 1006, reason: "Connection closed"))
            }
            readBuffer.append(chunk)
        }
    }

    public func close() async {
        guard let connection else { return }
        if handshakeComplete {
            let closeFrame = makeClientFrame(opcode: 0x8, payload: Data())
            try? await sendRaw(closeFrame)
        }
        connection.cancel()
        self.connection = nil
        self.handshakeComplete = false
        self.readBuffer.removeAll(keepingCapacity: false)
        self.fracpcodedOpcode = nil
        self.fracpcodedPayload.removeAll(keepingCapacity: false)
    }

    public func ping() async throws {
        guard handshakeComplete else { throw TransportError.notConnected }
        let frame = makeClientFrame(opcode: 0x9, payload: Data())
        try await sendRaw(frame)
    }

    /// Send close 1009, drop the connection and buffers, and report the close (FR-12).
    private func closeMessageTooBig() async -> TransportEvent {
        if handshakeComplete {
            var payload = Data([UInt8(Self.closeCodeMessageTooBig >> 8), UInt8(Self.closeCodeMessageTooBig & 0xFF)])
            payload.append(Data("message too big".utf8))
            try? await sendRaw(makeClientFrame(opcode: 0x8, payload: payload))
        }
        // Half-close, then cancel after a short grace. Cancelling at once, with unread data still in
        // the receive buffer, makes TCP send a reset that can drop the close frame at the peer.
        if let closing = connection {
            closing.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
            Task.detached {
                try? await Task.sleep(nanoseconds: 250_000_000)
                closing.cancel()
            }
        }
        connection = nil
        handshakeComplete = false
        readBuffer.removeAll(keepingCapacity: false)
        fracpcodedOpcode = nil
        fracpcodedPayload.removeAll(keepingCapacity: false)
        return .closed(TransportCloseReason(code: Self.closeCodeMessageTooBig, reason: "message too big"))
    }

    // MARK: - Connection State

    /// The deadline covers TCP, TLS and the WebSocket handshake. Cancelling the connection also ends a
    /// pending handshake read, which then throws.
    private func connectTimedOut() {
        guard !handshakeComplete, let connection else { return }
        connectTimeoutFired = true
        connection.cancel()
        resolveConnectContinuation(with: .failure(NativeWebSocketError.connectTimeout(lastState: lastStateDescription)))
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        lastStateDescription = "\(state)"
        switch state {
        case .ready:
            resolveConnectContinuation(with: .success(()))
        case .failed(let error):
            resolveConnectContinuation(with: .failure(error))
            // A failure after .ready (for example a TLS 1.3 server that rejects the client certificate
            // after the handshake) must also end pending reads.
            connection?.cancel()
        case .waiting(let error):
            resolveConnectContinuation(with: .failure(error))
        case .cancelled:
            resolveConnectContinuation(with: .failure(NativeWebSocketError.disconnected))
        default:
            break
        }
    }

    private func resolveConnectContinuation(with result: Result<Void, Error>) {
        guard let continuation = connectContinuation else { return }
        connectContinuation = nil
        continuation.resume(with: result)
    }

    // MARK: - Handshake

    private func performHandshake(
        path: String,
        hostHeader: String,
        headers: [String: String]
    ) async throws {
        let secKey = makeSecWebSocketKey()
        let expectedAccept = expectedAcceptValue(for: secKey)

        var requestLines = [
            "GET \(path) HTTP/1.1",
            "Host: \(hostHeader)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(secKey)",
            "Sec-WebSocket-Version: 13",
        ]

        let reservedHeaders = Set([
            "host",
            "upgrade",
            "connection",
            "sec-websocket-key",
            "sec-websocket-version",
        ])

        for (name, value) in headers {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty, !trimmedValue.isEmpty else { continue }
            guard !reservedHeaders.contains(trimmedName.lowercased()) else { continue }
            requestLines.append("\(trimmedName): \(trimmedValue)")
        }

        requestLines.append("")
        requestLines.append("")

        let request = requestLines.joined(separator: "\r\n")
        try await sendRaw(Data(request.utf8))

        let responseHeaderData = try await readHeaderBlock()
        guard let responseHeader = String(data: responseHeaderData, encoding: .utf8) else {
            throw NativeWebSocketError.invalidHTTPResponse
        }

        let lines = responseHeader
            .split(separator: "\r\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let statusLine = lines.first else {
            throw NativeWebSocketError.invalidHTTPResponse
        }

        let statusParts = statusLine.split(separator: " ", omittingEmptySubsequences: true)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw NativeWebSocketError.invalidHTTPResponse
        }
        guard statusCode == 101 else {
            throw NativeWebSocketError.invalidStatusCode(statusCode)
        }

        var responseHeaders: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let delimiter = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<delimiter]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[line.index(after: delimiter)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = responseHeaders[name], !existing.isEmpty {
                responseHeaders[name] = "\(existing),\(value)"
            } else {
                responseHeaders[name] = value
            }
        }

        let upgradeHeader = responseHeaders["upgrade"]?.lowercased() ?? ""
        guard upgradeHeader == "websocket" else {
            throw NativeWebSocketError.invalidHTTPResponse
        }

        let connectionHeader = responseHeaders["connection"] ?? ""
        guard headerContainsToken(connectionHeader, token: "upgrade") else {
            throw NativeWebSocketError.invalidHTTPResponse
        }

        guard let acceptHeader = responseHeaders["sec-websocket-accept"] else {
            throw NativeWebSocketError.missingAcceptHeader
        }
        guard acceptHeader == expectedAccept else {
            throw NativeWebSocketError.invalidAcceptHeader
        }
    }

    private func buildHostHeader(host: String, explicitPort: Int?) -> String {
        guard let explicitPort else { return host }
        return "\(host):\(explicitPort)"
    }

    private func buildRequestPath(from components: URLComponents) -> String {
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        return path + query
    }

    private func makeSecWebSocketKey() -> String {
        var random = [UInt8](repeating: 0, count: 16)
        for index in random.indices {
            random[index] = UInt8.random(in: 0 ... 255)
        }
        return Data(random).base64EncodedString()
    }

    private func expectedAcceptValue(for secKey: String) -> String {
        let combined = secKey + Self.handshakeGUID
        let digest = Insecure.SHA1.hash(data: Data(combined.utf8))
        return Data(digest).base64EncodedString()
    }

    private func headerContainsToken(_ header: String, token: String) -> Bool {
        let normalizedToken = token.lowercased()
        return header
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .contains(normalizedToken)
    }

    private func readHeaderBlock() async throws -> Data {
        while true {
            if let range = readBuffer.range(of: Self.headerDelimiter) {
                let headerEnd = range.upperBound
                let headerData = readBuffer[..<headerEnd]
                readBuffer.removeSubrange(..<headerEnd)
                return Data(headerData)
            }

            let chunk = try await receiveRaw()
            if chunk.isEmpty {
                throw NativeWebSocketError.invalidHTTPResponse
            }
            readBuffer.append(chunk)
        }
    }

    // MARK: - Frame Send/Receive

    /// Handle one parsed frame. Returns an event for the caller, or nil when the frame was consumed
    /// without one (ping, pong, non-final fragment, unknown opcode).
    private func handle(_ frame: ParsedFrame) async throws -> TransportEvent? {
        switch frame.opcode {
        case 0x0:
            // Continuation frame.
            guard let opcode = fracpcodedOpcode else { return nil }
            fracpcodedPayload.append(frame.payload)
            if frame.fin {
                let completePayload = fracpcodedPayload
                fracpcodedOpcode = nil
                fracpcodedPayload.removeAll(keepingCapacity: false)
                return makeEvent(for: opcode, payload: completePayload)
            }
            return nil
        case 0x1, 0x2:
            if frame.fin {
                return makeEvent(for: frame.opcode, payload: frame.payload)
            }
            fracpcodedOpcode = frame.opcode
            fracpcodedPayload = frame.payload
            return nil
        case 0x8:
            let closeReason = parseCloseReason(from: frame.payload)
            return .closed(closeReason)
        case 0x9:
            // Ping frame: reply with pong and continue.
            let pong = makeClientFrame(opcode: 0xA, payload: frame.payload)
            try await sendRaw(pong)
            return nil
        case 0xA:
            // Pong frame: ignore and continue.
            return nil
        default:
            // Ignore unknown control/data opcodes.
            return nil
        }
    }

    private func makeEvent(for opcode: UInt8, payload: Data) -> TransportEvent {
        switch opcode {
        case 0x1:
            if let text = String(data: payload, encoding: .utf8) {
                return .text(text)
            }
            return .binary(payload)
        case 0x2:
            return .binary(payload)
        default:
            return .binary(payload)
        }
    }

    private func parseCloseReason(from payload: Data) -> TransportCloseReason {
        guard payload.count >= 2 else {
            return TransportCloseReason(code: 1000, reason: nil)
        }
        let code = Int((UInt16(payload[0]) << 8) | UInt16(payload[1]))
        let reasonData = payload.dropFirst(2)
        let reason = reasonData.isEmpty ? nil : String(data: reasonData, encoding: .utf8)
        return TransportCloseReason(code: code, reason: reason)
    }

    private func parseFrameFromBuffer() throws -> ParsedFrame? {
        guard readBuffer.count >= 2 else { return nil }

        let firstByte = readBuffer[0]
        let secondByte = readBuffer[1]
        let fin = (firstByte & 0x80) != 0
        let opcode = firstByte & 0x0F
        let masked = (secondByte & 0x80) != 0

        var index = 2
        var payloadLength = UInt64(secondByte & 0x7F)

        switch payloadLength {
        case 126:
            guard readBuffer.count >= index + 2 else { return nil }
            payloadLength = (UInt64(readBuffer[index]) << 8) | UInt64(readBuffer[index + 1])
            index += 2
        case 127:
            guard readBuffer.count >= index + 8 else { return nil }
            payloadLength = 0
            for byte in readBuffer[index..<(index + 8)] {
                payloadLength = (payloadLength << 8) | UInt64(byte)
            }
            index += 8
        default:
            break
        }

        guard payloadLength <= UInt64(Int.max) else {
            throw NativeWebSocketError.unsupportedFrameLength(payloadLength)
        }
        // FR-12: refuse on the declared length, before the payload is buffered.
        // A continuation frame counts toward the message reassembled so far.
        let isContinuation = opcode == 0x0 && fracpcodedOpcode != nil
        let messageLength = isContinuation ? UInt64(fracpcodedPayload.count) + payloadLength : payloadLength
        if opcode < 0x8, messageLength > UInt64(maxMessageBytes) {
            throw NativeWebSocketError.messageTooBig(messageLength)
        }

        var maskKey: [UInt8] = []
        if masked {
            guard readBuffer.count >= index + 4 else { return nil }
            maskKey = Array(readBuffer[index..<(index + 4)])
            index += 4
        }

        let payloadCount = Int(payloadLength)
        guard readBuffer.count >= index + payloadCount else { return nil }

        var payload = Data(readBuffer[index..<(index + payloadCount)])
        readBuffer.removeSubrange(0..<(index + payloadCount))

        if masked {
            var bytes = [UInt8](payload)
            for i in bytes.indices {
                bytes[i] ^= maskKey[i % 4]
            }
            payload = Data(bytes)
        }

        return ParsedFrame(fin: fin, opcode: opcode, payload: payload)
    }

    private func makeClientFrame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data()
        frame.append(0x80 | (opcode & 0x0F))

        let payloadCount = payload.count
        let maskBit: UInt8 = 0x80

        if payloadCount <= 125 {
            frame.append(maskBit | UInt8(payloadCount))
        } else if payloadCount <= 65_535 {
            frame.append(maskBit | 126)
            frame.append(UInt8((payloadCount >> 8) & 0xFF))
            frame.append(UInt8(payloadCount & 0xFF))
        } else {
            frame.append(maskBit | 127)
            let length = UInt64(payloadCount)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((length >> UInt64(shift)) & 0xFF))
            }
        }

        var maskKey = [UInt8](repeating: 0, count: 4)
        for index in maskKey.indices {
            maskKey[index] = UInt8.random(in: 0 ... 255)
        }
        frame.append(contentsOf: maskKey)

        var maskedPayload = [UInt8](payload)
        for i in maskedPayload.indices {
            maskedPayload[i] ^= maskKey[i % 4]
        }
        frame.append(contentsOf: maskedPayload)
        return frame
    }

    // MARK: - Raw IO

    private func sendRaw(_ data: Data) async throws {
        guard let connection else { throw NativeWebSocketError.disconnected }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveRaw() async throws -> Data {
        guard let connection else { throw NativeWebSocketError.disconnected }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(throwing: NativeWebSocketError.malformedFrame)
                }
            }
        }
    }
}
