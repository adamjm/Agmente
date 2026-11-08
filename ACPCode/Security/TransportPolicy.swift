import Foundation

/// Which endpoints the app may connect to (FR-11, D-018, D-019, PLAN 2.3).
///
/// - `wss://` to any host, unless the server is marked "Local only", which allows local hosts only.
/// - `ws://` only to loopback in Debug builds, or to loopback, `.local` and RFC 1918 hosts when the
///   server is marked "Local only".
/// - Everything else is refused, including Tailscale (`100.64/10`) and IPv6 unique-local addresses.
enum TransportPolicy {
    enum Refusal: LocalizedError, Equatable {
        case unsupportedScheme(String)
        case missingHost
        case plaintextNotAllowed(host: String)
        case notLocalHost(host: String)

        var errorDescription: String? {
            switch self {
            case .unsupportedScheme(let scheme):
                return "Unsupported scheme \"\(scheme)\". Use wss://."
            case .missingHost:
                return "The endpoint has no host."
            case .plaintextNotAllowed(let host):
                return "Unencrypted ws:// is not allowed for \(host). Use wss://, or mark the server \"Local only\" if it is on your local network."
            case .notLocalHost(let host):
                return "\(host) is not on the local network, but this server is marked \"Local only\"."
            }
        }
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Returns nil when the URL is allowed, or the reason it is refused.
    static func check(url: URL, localOnly: Bool, isDebugBuild: Bool = TransportPolicy.isDebugBuild) -> Refusal? {
        let scheme = (url.scheme ?? "").lowercased()
        guard let rawHost = url.host, !rawHost.isEmpty else { return .missingHost }
        let host = normalizedHost(rawHost)

        switch scheme {
        case "wss":
            if localOnly && !isLocal(host) { return .notLocalHost(host: host) }
            return nil
        case "ws":
            if localOnly {
                return isLocal(host) ? nil : .notLocalHost(host: host)
            }
            if isDebugBuild && isLoopback(host) { return nil }
            return .plaintextNotAllowed(host: host)
        default:
            return .unsupportedScheme(scheme)
        }
    }

    // MARK: - Host classes

    static func normalizedHost(_ host: String) -> String {
        var value = host.lowercased()
        if value.hasPrefix("["), value.hasSuffix("]") { value = String(value.dropFirst().dropLast()) }
        if value.hasSuffix(".") { value = String(value.dropLast()) }
        return value
    }

    /// `localhost`, `127.0.0.0/8` and `::1`.
    static func isLoopback(_ host: String) -> Bool {
        let host = normalizedHost(host)
        if host == "localhost" || host == "::1" || host == "0:0:0:0:0:0:0:1" { return true }
        if let octets = ipv4Octets(host) { return octets[0] == 127 }
        return false
    }

    /// Loopback, names ending in `.local`, and RFC 1918 (`10/8`, `172.16/12`, `192.168/16`).
    static func isLocal(_ host: String) -> Bool {
        let host = normalizedHost(host)
        if isLoopback(host) { return true }
        if host.hasSuffix(".local"), host.count > ".local".count { return true }
        guard let o = ipv4Octets(host) else { return false }
        switch (o[0], o[1]) {
        case (10, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        default: return false
        }
    }

    /// Strict dotted-quad parse. Returns nil for names and for forms like `127.1` or `0x7f.0.0.1`.
    static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part), value <= 255 else { return nil }
            octets.append(value)
        }
        return octets
    }
}
