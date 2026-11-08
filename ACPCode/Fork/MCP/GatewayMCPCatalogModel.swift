import Foundation
import ACPClient

/// The gateway's MCP servers and the chosen set, for the new-session sheet and the session header (D-107).
/// The list is global to the Mac. The choice is per project in the sheet and per session in the header.
@MainActor
final class GatewayMCPCatalogModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        /// The list call failed for a reason other than a missing method. The session starts with no servers.
        case failed
        /// The gateway answers `-32601`: it has no MCP support. The screen shows nothing.
        case unsupported
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var servers: [GatewayMCPServer] = []
    /// The ids that are on, in the list's order.
    @Published private(set) var enabled: [String] = []

    /// The project whose remembered choice this sheet reads and writes. Nil for a session header.
    private(set) var projectId: String?
    private let clientProvider: () -> GatewayClient?
    private let defaults: UserDefaults

    init(clientProvider: @escaping () -> GatewayClient?, defaults: UserDefaults = .standard) {
        self.clientProvider = clientProvider
        self.defaults = defaults
    }

    /// The section shows for a loading or failed list, and for a loaded list that has servers. It is
    /// hidden with no servers and for a gateway without MCP support.
    var showsSection: Bool {
        switch phase {
        case .loading, .failed: return true
        case .loaded: return !servers.isEmpty
        case .idle, .unsupported: return false
        }
    }

    var enabledCount: Int { GatewayMCPChoice.sendableIDs(enabled, catalog: servers).count }

    var summary: String {
        switch phase {
        case .loading: return "Loading"
        case .failed: return "Not loaded"
        default: return GatewayMCPChoice.summary(on: enabledCount, total: servers.count)
        }
    }

    /// The ids to send with session/new, for the sheet's Create. Nil sends no key, so the gateway uses its
    /// defaults (a list still loading, or no servers). An empty array is sent when the list failed to load,
    /// so the session starts with no MCP servers, as the copy says.
    var idsToSend: [String]? {
        switch phase {
        case .loaded where !servers.isEmpty:
            return GatewayMCPChoice.sendableIDs(enabled, catalog: servers)
        case .failed:
            return []
        default:
            return nil
        }
    }

    /// Loads the list. A missing client counts as a failed load. A `-32601` is "no MCP support".
    func load(projectId: String? = nil) async {
        if let projectId { self.projectId = projectId }
        guard let client = clientProvider() else {
            phase = .failed
            return
        }
        phase = .loading
        do {
            let list = try await client.mcpServers()
            servers = list
            enabled = GatewayMCPChoice.startingIDs(catalog: list, memory: rememberedChoice())
            phase = .loaded
        } catch let error as GatewayError where error.isMethodNotFound {
            servers = []
            enabled = []
            phase = .unsupported
        } catch {
            phase = .failed
        }
    }

    /// Switches the project the sheet is for. Its remembered choice replaces the current toggles.
    func selectProject(_ projectId: String?) {
        self.projectId = projectId
        guard phase == .loaded else { return }
        enabled = GatewayMCPChoice.startingIDs(catalog: servers, memory: rememberedChoice())
    }

    /// Sets a session header's starting toggles to the set the session took.
    func select(ids: [String]) {
        enabled = GatewayMCPChoice.sendableIDs(ids, catalog: servers)
    }

    func isOn(_ id: String) -> Bool { enabled.contains(id) }

    func setOn(_ id: String, _ on: Bool) {
        var next = enabled.filter { $0 != id }
        if on { next.append(id) }
        enabled = servers.map(\.id).filter { next.contains($0) }
        remember()
    }

    func setAll(_ on: Bool) {
        enabled = on ? servers.map(\.id) : []
        remember()
    }

    /// The Mac's defaults, which are the `defaultEnabled` entries.
    func useDefaults() {
        enabled = GatewayMCPChoice.defaultIDs(servers)
        remember()
    }

    /// Changes a live session's set (D-107). The gateway closes the session in the agent, so its next prompt
    /// loads the new set. Throws `GatewayMCPError.turnOpen` while a turn or an approval is open.
    func saveSession(_ sessionId: String) async throws {
        guard let client = clientProvider() else { throw GatewayError.disconnected }
        let result = try await client.setSessionMCPServers(sessionId: sessionId, ids: enabled, catalog: servers)
        GatewayMCPMemoryStore.rememberSessionIDs(result.enabled, sessionId: sessionId, defaults: defaults)
        enabled = GatewayMCPChoice.sendableIDs(result.enabled, catalog: servers)
    }

    private func rememberedChoice() -> GatewayMCPMemory? {
        guard let projectId else { return nil }
        return GatewayMCPMemoryStore.projectChoice(projectId: projectId, defaults: defaults)
    }

    /// Writes the choice for the project. A session header has no project, so nothing is written there.
    private func remember() {
        guard let projectId else { return }
        GatewayMCPMemoryStore.rememberProjectChoice(
            GatewayMCPMemory(enabled: enabled, known: servers.map(\.id)),
            projectId: projectId,
            defaults: defaults
        )
    }
}
