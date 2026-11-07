import ACP
import Foundation

/// Where the MCP payload is built (PLAN 6B.2). The list goes only to gateway servers, and HTTP
/// entries only when the agent's `mcpCapabilities.http` is true.
struct MCPPayloadContext: Equatable, Sendable {
    /// The server is a gateway server. Other servers never get the phone's list.
    var isGateway: Bool
    /// The agent's `initialize` result has `mcpCapabilities.http` true.
    var agentSupportsHTTP: Bool
}

/// The phone's MCP server list for one gateway server (FR-40, PLAN 6B.2).
///
/// Stored as one JSON file per server, with names, URLs, commands and flags only. Header and
/// environment values stay in the Keychain (`MCPHeaderStore`). The file is not Core Data.
@MainActor
final class MCPServersModel: ObservableObject {
    @Published private(set) var servers: [MCPServerEntry] = []
    /// Set when the file exists but cannot be read. Writes are refused then, so a bad file is never overwritten.
    @Published private(set) var loadError: String?

    let fileURL: URL
    private let values: MCPHeaderStore

    private struct FileContents: Codable {
        var version: Int
        var servers: [MCPServerEntry]
    }

    init(fileURL: URL, values: MCPHeaderStore = MCPHeaderStore()) {
        self.fileURL = fileURL
        self.values = values
        load()
    }

    /// `Application Support/Agmente/Fork/MCP/servers-<serverId>.json`, one file per gateway server.
    nonisolated static func defaultFileURL(serverId: UUID) -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Agmente", isDirectory: true)
            .appendingPathComponent("Fork", isDirectory: true)
            .appendingPathComponent("MCP", isDirectory: true)
            .appendingPathComponent("servers-\(serverId.uuidString).json")
    }

    // MARK: Changes

    /// Adds or replaces an entry. `headerValues` and `envValues` are keyed by name; an empty or
    /// missing value keeps the stored one. Every new value and the entry are checked before anything
    /// is written, so a failure leaves the file and the Keychain as they were.
    func upsert(_ entry: MCPServerEntry, headerValues: [String: String] = [:], envValues: [String: String] = [:]) throws {
        try requireReadable()
        let entry = entry.normalized()
        try entry.validate()

        var pending: [(MCPHeaderStore.Kind, String, String)] = []
        for name in entry.headerNames {
            try collectValue(for: name, kind: .header, entryId: entry.id, given: headerValues[name], into: &pending)
        }
        for name in entry.envNames {
            try collectValue(for: name, kind: .env, entryId: entry.id, given: envValues[name], into: &pending)
        }

        let previous = servers.first { $0.id == entry.id }
        var next = servers
        if let index = next.firstIndex(where: { $0.id == entry.id }) {
            next[index] = entry
        } else {
            next.append(entry)
        }

        for (kind, name, value) in pending {
            try values.set(value, entryId: entry.id, kind: kind, name: name)
        }
        try write(next)

        // Values of names that the entry no longer uses are removed after the file is written.
        if let previous {
            for name in previous.headerNames where !entry.headerNames.contains(name) {
                try values.delete(entryId: entry.id, kind: .header, name: name)
            }
            for name in previous.envNames where !entry.envNames.contains(name) {
                try values.delete(entryId: entry.id, kind: .env, name: name)
            }
        }
    }

    func setEnabled(id: UUID, _ enabled: Bool) throws {
        try requireReadable()
        var next = servers
        guard let index = next.firstIndex(where: { $0.id == id }) else { return }
        next[index].isEnabled = enabled
        try write(next)
    }

    /// Deletes one entry and its values.
    func remove(id: UUID) throws {
        try requireReadable()
        guard let entry = servers.first(where: { $0.id == id }) else { return }
        try write(servers.filter { $0.id != id })
        try values.deleteAll(entryId: id, headerNames: entry.headerNames, envNames: entry.envNames)
    }

    /// Deletes every entry, every value and the file. Called when the gateway server is deleted.
    func removeAll() throws {
        for entry in servers {
            try values.deleteAll(entryId: entry.id, headerNames: entry.headerNames, envNames: entry.envNames)
        }
        servers = []
        loadError = nil
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: Payload

    /// The ACP `mcpServers` array for `session/new` and `session/resume` (FR-40, D-084).
    ///
    /// - Gateway servers only. Other servers get no list (the caller sends `[]`, as before).
    /// - Enabled entries only. A stdio entry needs its warning confirmed (`stdioAcknowledged`).
    /// - HTTP entries only when the agent supports `mcpCapabilities.http`.
    /// - `alwaysAllow` only when it is not empty (D-089).
    /// - Header and environment values are read from the Keychain here and nowhere else. A missing
    ///   value throws, so a server is never sent with a header it should have.
    func mcpServersPayload(for context: MCPPayloadContext) throws -> [ACP.Value] {
        guard context.isGateway else { return [] }
        if loadError != nil { throw MCPServerEntryError.unreadableFile }

        var out: [ACP.Value] = []
        for entry in servers where entry.isEnabled {
            switch entry.transport {
            case .http:
                guard context.agentSupportsHTTP, let url = entry.url else { continue }
                var headers: [ACP.Value] = []
                for name in entry.headerNames {
                    headers.append(.object(["name": .string(name), "value": .string(try storedValue(entry.id, .header, name))]))
                }
                var object: [String: ACP.Value] = [
                    "type": .string("http"),
                    "name": .string(entry.name),
                    "url": .string(url),
                    "headers": .array(headers),
                ]
                addAlwaysAllow(entry, to: &object)
                out.append(.object(object))

            case .stdio:
                guard entry.stdioAcknowledged, let command = entry.command else { continue }
                var env: [ACP.Value] = []
                for name in entry.envNames {
                    env.append(.object(["name": .string(name), "value": .string(try storedValue(entry.id, .env, name))]))
                }
                // No "type" key: the stdio shape in ACP is {name, command, args, env} (the gateway's rule).
                var object: [String: ACP.Value] = [
                    "name": .string(entry.name),
                    "command": .string(command),
                    "args": .array(entry.args.map { .string($0) }),
                    "env": .array(env),
                ]
                addAlwaysAllow(entry, to: &object)
                out.append(.object(object))
            }
        }
        return out
    }

    // MARK: Private

    private func addAlwaysAllow(_ entry: MCPServerEntry, to object: inout [String: ACP.Value]) {
        if !entry.alwaysAllow.isEmpty {
            object["alwaysAllow"] = .array(entry.alwaysAllow.map { .string($0) })
        }
    }

    private func collectValue(
        for name: String,
        kind: MCPHeaderStore.Kind,
        entryId: UUID,
        given: String?,
        into pending: inout [(MCPHeaderStore.Kind, String, String)]
    ) throws {
        if let given, !given.isEmpty {
            guard MCPServerEntry.isValidSecretValue(given) else { throw MCPServerEntryError.invalidValue(name) }
            pending.append((kind, name, given))
            return
        }
        guard try values.get(entryId: entryId, kind: kind, name: name) != nil else {
            throw MCPServerEntryError.missingValue(name)
        }
    }

    private func storedValue(_ entryId: UUID, _ kind: MCPHeaderStore.Kind, _ name: String) throws -> String {
        guard let value = try values.get(entryId: entryId, kind: kind, name: name) else {
            throw MCPServerEntryError.missingValue(name)
        }
        return value
    }

    private func requireReadable() throws {
        if loadError != nil { throw MCPServerEntryError.unreadableFile }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            servers = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let contents = try JSONDecoder().decode(FileContents.self, from: data)
            servers = contents.servers
            loadError = nil
        } catch {
            servers = []
            loadError = MCPServerEntryError.unreadableFile.localizedDescription
        }
    }

    private func write(_ list: [MCPServerEntry]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(FileContents(version: 1, servers: list))
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        servers = list
    }
}

extension MCPServersModel {
    /// Deletes the MCP entries, their Keychain values and the list file of one gateway server.
    /// `SessionStorage.deleteServer` calls this, and it is not on the main actor, so it does what
    /// `removeAll()` does without the instance. A file that cannot be decoded is removed without its
    /// values: the entry names are then unknown (see the PLAN 6B.1 note in the report).
    nonisolated static func deleteStoredData(serverId: UUID, values: MCPHeaderStore = MCPHeaderStore()) throws {
        let url = defaultFileURL(serverId: serverId)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if let data = try? Data(contentsOf: url),
           let contents = try? JSONDecoder().decode(FileContents.self, from: data) {
            for entry in contents.servers {
                try values.deleteAll(entryId: entry.id, headerNames: entry.headerNames, envNames: entry.envNames)
            }
        }
        try FileManager.default.removeItem(at: url)
    }
}
