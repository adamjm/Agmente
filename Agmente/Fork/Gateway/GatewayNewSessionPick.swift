import Foundation
import ACPClient

/// The project the new-session sheet starts on: the chosen one while it is still listed, else the
/// first project, else nil when the gateway has none (FR-26).
func gatewayNewSessionChosenProject(_ projects: [GatewayProject], selection: String?) -> GatewayProject? {
    projects.first { $0.id == selection } ?? projects.first
}

/// The cwd sent to `session/new` for a gateway server: the chosen project's path, trimmed. Nil for a
/// missing or blank path, so "/" is never sent for a gateway server.
func gatewayNewSessionCwd(selectedProjectPath: String?) -> String? {
    guard let path = selectedProjectPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
        return nil
    }
    return path
}

/// True when a new session on this server must not be sent: a gateway server without a project path.
/// A plain ACP server is never blocked here; it keeps its free-text working directory.
func gatewayNewSessionBlocked(isGateway: Bool, selectedProjectPath: String?) -> Bool {
    isGateway && gatewayNewSessionCwd(selectedProjectPath: selectedProjectPath) == nil
}
