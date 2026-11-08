import Foundation
@_exported import ACPCodeTransport

public struct ACPClientConfiguration {
    public typealias TokenProvider = () async throws -> String

    public var endpoint: URL
    public var authTokenProvider: TokenProvider?
    public var additionalHeaders: [String: String]
    public var pingInterval: TimeInterval?
    /// Append a trailing newline to outbound JSON (useful for stdio bridges that expect line-delimited JSON).
    public var appendNewline: Bool
    /// Certificate pins, trust anchors and client identity for wss (FR-13, FR-14).
    public var tls: TransportTLSOptions

    public init(
        endpoint: URL,
        authTokenProvider: TokenProvider? = nil,
        additionalHeaders: [String: String] = [:],
        pingInterval: TimeInterval? = nil,
        appendNewline: Bool = true,
        tls: TransportTLSOptions = TransportTLSOptions()
    ) {
        self.tls = tls
        self.endpoint = endpoint
        self.authTokenProvider = authTokenProvider
        self.additionalHeaders = additionalHeaders
        self.pingInterval = pingInterval
        self.appendNewline = appendNewline
    }
}