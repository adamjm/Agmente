import Foundation
import ACP

// The gateway's own MCP server list and each session's chosen set (D-107, FR-41, docs/SPEC.md 6.2).
// The list holds no secret: the gateway sends id, name, transport, url (http only) and defaultEnabled.
// A session's set travels in `_meta["acpcode/mcpEnabled"]` on session/new, as a list of ids.

/// A refusal the MCP calls map to a meaning the screen can show.
public enum GatewayMCPError: Error, Equatable, Sendable {
    /// The session has a turn or an approval open, so its set did not change (`-32001`, `turn_open`).
    /// The only `-32001` that `setEnabled` returns is this one.
    case turnOpen
}

/// One server in the gateway's list, as the phone may see it.
public struct GatewayMCPServer: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// As the gateway names it: `http` or `stdio`. A value this build does not know is kept as sent.
    public let transport: String
    /// The URL of an http server, as the gateway sends it. The gateway keeps the path when the URL has no
    /// query or credentials, so this can hold more than the host. The phone shows only ``host``.
    public let url: String?
    public let defaultEnabled: Bool

    public init(id: String, name: String, transport: String, url: String? = nil, defaultEnabled: Bool = false) {
        self.id = id
        self.name = name
        self.transport = transport
        self.url = url
        self.defaultEnabled = defaultEnabled
    }

    /// Reads one entry. Only the fields above are read, so a secret the gateway never sends has no field
    /// here. Nothing is dropped for a missing name, transport or flag: each has a fallback.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = (try? container.decode(String.self, forKey: .name)) ?? id
        transport = (try? container.decode(String.self, forKey: .transport)) ?? "unknown"
        url = try? container.decodeIfPresent(String.self, forKey: .url)
        defaultEnabled = (try? container.decode(Bool.self, forKey: .defaultEnabled)) ?? false
    }

    /// The host of an http server's URL, for the row. Nil for a stdio server or a URL that does not parse.
    public var host: String? {
        guard let url, let host = URLComponents(string: url)?.host, !host.isEmpty else { return nil }
        return host
    }

    /// The transport as a person reads it. A stdio server is a local command; its command is never sent.
    public var transportLabel: String {
        switch transport {
        case "http": return "HTTP"
        case "stdio": return "Local command"
        default: return "Custom server"
        }
    }
}

/// The answer to `_acpcode/mcp/servers/setEnabled`.
public struct GatewayMCPSetResult: Equatable, Sendable {
    public let sessionId: String
    /// The ids the session now enables, as the gateway stored them.
    public let enabled: [String]
    /// True when the gateway closed a live session in the agent, so its next prompt loads the new set.
    public let closed: Bool

    public init(sessionId: String, enabled: [String], closed: Bool) {
        self.sessionId = sessionId
        self.enabled = enabled
        self.closed = closed
    }
}

public extension GatewayClient {
    /// `_acpcode/mcp/servers/list`: the gateway's global MCP servers. Takes no parameters.
    func mcpServers() async throws -> [GatewayMCPServer] {
        let result = try await call("_acpcode/mcp/servers/list", .object([:]))
        return try decode([GatewayMCPServer].self, from: result["servers"], what: "mcp servers")
    }

    /// `_acpcode/mcp/servers/setEnabled {sessionId, ids}`. Only ids the `catalog` holds are sent, so an
    /// unknown id never reaches the gateway. Throws `GatewayMCPError.turnOpen` while a turn or an approval
    /// is open in the session; the set does not change then.
    func setSessionMCPServers(sessionId: String, ids: [String], catalog: [GatewayMCPServer]) async throws -> GatewayMCPSetResult {
        struct Wire: Decodable {
            let sessionId: String
            let enabled: [String]
            let closed: Bool
        }
        let sendable = GatewayMCPChoice.sendableIDs(ids, catalog: catalog)
        do {
            let result = try await call("_acpcode/mcp/servers/setEnabled", .object([
                "sessionId": .string(sessionId),
                "ids": .array(sendable.map { ACP.Value.string($0) })
            ]))
            let wire = try decode(Wire.self, from: result, what: "setEnabled")
            return GatewayMCPSetResult(sessionId: wire.sessionId, enabled: wire.enabled, closed: wire.closed)
        } catch GatewayError.rpc(let code, _) where code == -32001 {
            throw GatewayMCPError.turnOpen
        }
    }
}

/// The rules for a chosen set: what may be sent, the defaults, the starting state of a sheet and the
/// words for the summary. Pure, so the app and its tests share one implementation.
public enum GatewayMCPChoice {
    /// The `_meta` key of session/new that carries the chosen ids (D-107).
    public static let metaKey = "acpcode/mcpEnabled"
    /// The most ids a session may enable (D-107).
    public static let maxIDs = 32

    /// The requested ids the catalog holds, in the order asked, without repeats, at most `maxIDs`.
    public static func sendableIDs(_ requested: [String], catalog: [GatewayMCPServer]) -> [String] {
        let known = Set(catalog.map(\.id))
        var seen = Set<String>()
        var out: [String] = []
        for id in requested where known.contains(id) && !seen.contains(id) {
            seen.insert(id)
            out.append(id)
            if out.count == maxIDs { break }
        }
        return out
    }

    /// The ids the gateway starts a session with when nothing is chosen: the entries with `defaultEnabled`.
    public static func defaultIDs(_ catalog: [GatewayMCPServer]) -> [String] {
        catalog.filter(\.defaultEnabled).map(\.id)
    }

    /// The set a sheet starts with. A server the phone has seen before takes its remembered state. A server
    /// new to the list takes its default. A server removed on the Mac is simply absent.
    public static func startingIDs(catalog: [GatewayMCPServer], memory: GatewayMCPMemory?) -> [String] {
        guard let memory else { return defaultIDs(catalog) }
        let on = Set(memory.enabled)
        let known = Set(memory.known)
        return catalog.filter { known.contains($0.id) ? on.contains($0.id) : $0.defaultEnabled }.map(\.id)
    }

    /// The summary on the disclosure row: "3 of 5 on", or "None on".
    public static func summary(on: Int, total: Int) -> String {
        on == 0 ? "None on" : "\(on) of \(total) on"
    }

    /// The `_meta` a session/new carries. Only a gateway server gets the key, and only when a set was chosen
    /// (`enabledIDs` not nil). A plain ACP server or Codex gets nothing added.
    public static func sessionNewMeta(isGateway: Bool, enabledIDs: [String]?) -> [String: ACP.Value] {
        guard isGateway, let enabledIDs else { return [:] }
        return [metaKey: .array(enabledIDs.map { ACP.Value.string($0) })]
    }
}

/// The last choice made for one project in the new-session sheet. `enabled` is what was on. `known` is every
/// id the phone had seen, so a server that is new to the list takes its default rather than off.
public struct GatewayMCPMemory: Codable, Equatable, Sendable {
    public var enabled: [String]
    public var known: [String]

    public init(enabled: [String], known: [String]) {
        self.enabled = enabled
        self.known = known
    }
}

/// Stores the per-project choice and the per-session set in UserDefaults. Every read and write is safe: a
/// value that will not decode is treated as absent, and the screen then shows the defaults.
public enum GatewayMCPMemoryStore {
    private static let projectPrefix = "acpcode.mcp.projectChoice."
    private static let sessionPrefix = "acpcode.mcp.session."

    public static func projectChoice(projectId: String, defaults: UserDefaults = .standard) -> GatewayMCPMemory? {
        guard let data = defaults.data(forKey: projectPrefix + projectId) else { return nil }
        return try? JSONDecoder().decode(GatewayMCPMemory.self, from: data)
    }

    public static func rememberProjectChoice(_ memory: GatewayMCPMemory, projectId: String, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(memory) else { return }
        defaults.set(data, forKey: projectPrefix + projectId)
    }

    /// The set a gateway session took when the phone created it or last changed it. The gateway does not
    /// report a session's set, so nil means the phone does not know it (another device made it, for example).
    public static func sessionIDs(sessionId: String, defaults: UserDefaults = .standard) -> [String]? {
        guard let data = defaults.data(forKey: sessionPrefix + sessionId) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    public static func rememberSessionIDs(_ ids: [String], sessionId: String, defaults: UserDefaults = .standard) {
        guard !sessionId.isEmpty, let data = try? JSONEncoder().encode(ids) else { return }
        defaults.set(data, forKey: sessionPrefix + sessionId)
    }
}
