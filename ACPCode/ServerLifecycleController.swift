import Foundation
import ACPClient

@MainActor
final class ServerLifecycleController {
    private enum DefaultsKey {
        static let legacyLastConnectedAt = "ACPCode.lastConnectedAt"
        static let connectionLastConnectedAt = "ACPClientManager.lastConnectedAt"
    }

    private let storage: SessionStorage
    private let defaults: UserDefaults
    private var pendingDisconnectServerIds: [UUID] = []

    init(storage: SessionStorage, defaults: UserDefaults) {
        self.storage = storage
        self.defaults = defaults
    }

    func migrateLegacyConnectionDefaultsIfNeeded(connectionManagerProvided: Bool) {
        guard !connectionManagerProvided else { return }

        if defaults.object(forKey: DefaultsKey.connectionLastConnectedAt) == nil,
           let legacyTimestamp = defaults.object(forKey: DefaultsKey.legacyLastConnectedAt) as? TimeInterval {
            defaults.set(legacyTimestamp, forKey: DefaultsKey.connectionLastConnectedAt)
        }
    }

    func loadServersFromStorage() -> [ACPServerConfiguration] {
        storage.fetchServers()
    }

    func persistServer(_ server: ACPServerConfiguration) {
        storage.saveServer(server)
    }

    func enqueuePendingDisconnect(_ serverId: UUID) {
        pendingDisconnectServerIds.append(serverId)
    }

    func popPendingDisconnectServerId() -> UUID? {
        guard !pendingDisconnectServerIds.isEmpty else { return nil }
        return pendingDisconnectServerIds.removeFirst()
    }

    func connectOnStartupIfNeeded(
        selectedServerIdProvider: @escaping () -> UUID?,
        connectInitializeAndFetchSessions: @escaping () -> Void
    ) {
        guard selectedServerIdProvider() != nil else { return }
        connectInitializeAndFetchSessions()
    }

    func connectInitializeAndFetchSessions(
        selectedServerIdProvider: @escaping () -> UUID?,
        isInitializedOnConnection: @escaping () -> Bool,
        connectAndWait: @escaping () async -> Bool,
        initializeAndWait: @escaping () async -> Bool,
        fetchSessionList: @escaping () -> Void
    ) {
        Task { @MainActor in
            guard selectedServerIdProvider() != nil else { return }
            let connected = await connectAndWait()
            guard connected else { return }
            if selectedServerIdProvider() != nil, !isInitializedOnConnection() {
                _ = await initializeAndWait()
            }
            fetchSessionList()
        }
    }
}