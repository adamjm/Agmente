import ACPClient
import Foundation

/// The status dot on the selected connection. It mirrors `ACPConnectionState` without its error value.
enum SettingsConnectionStatus: Equatable {
    case connected
    case connecting
    case disconnected
    case failed

    init(_ state: ACPConnectionState) {
        switch state {
        case .connected: self = .connected
        case .connecting: self = .connecting
        case .disconnected: self = .disconnected
        case .failed: self = .failed
        }
    }
}

/// One row of the Connections section in Settings. It holds plain values only, so it is unit tested without views.
struct SettingsConnectionRowModel: Equatable, Identifiable {
    let id: UUID
    let title: String
    let subtitle: String
    let iconName: String
    let isSelected: Bool
    /// The status of the selected connection. Other connections have no dot.
    let status: SettingsConnectionStatus?

    var accessibilityIdentifier: String { "settingsConnection.\(id.uuidString)" }

    /// - Parameters:
    ///   - isGateway: whether the server is a gateway. The app knows this only for the selected connection,
    ///     so the gateway icon is used only when the server is also selected.
    static func make(
        server: ACPServerConfiguration,
        selectedServerId: UUID?,
        connectionState: ACPConnectionState,
        isGateway: Bool
    ) -> SettingsConnectionRowModel {
        let isSelected = server.id == selectedServerId
        let name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = server.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        if !name.isEmpty {
            title = name
        } else if !host.isEmpty {
            title = host
        } else {
            title = "Untitled connection"
        }
        return SettingsConnectionRowModel(
            id: server.id,
            title: title,
            subtitle: host.isEmpty ? "No host" : host,
            iconName: isGateway && isSelected ? "desktopcomputer" : "server.rack",
            isSelected: isSelected,
            status: isSelected ? SettingsConnectionStatus(connectionState) : nil
        )
    }
}

/// The read-only facts on the connection detail screen. There is no token, passphrase or key here:
/// the client certificate appears only as stored or not stored.
struct SettingsConnectionFacts: Equatable {
    let scheme: String
    let host: String
    let clientCertificateStored: Bool
    /// "Name version", or nil when the agent has not reported its name yet.
    let agent: String?

    static func make(
        server: ACPServerConfiguration,
        hasClientCertificate: Bool,
        agentName: String?,
        agentVersion: String?
    ) -> SettingsConnectionFacts {
        let name = agentName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let version = agentVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let agent: String?
        if name.isEmpty {
            agent = nil
        } else if version.isEmpty {
            agent = name
        } else {
            agent = "\(name) \(version)"
        }
        return SettingsConnectionFacts(
            scheme: server.scheme,
            host: server.host,
            clientCertificateStored: hasClientCertificate,
            agent: agent
        )
    }
}
