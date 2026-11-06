import Foundation
import ACPClient

/// Rules for the session calls the app makes to the agent (FR-34 start mode, FR-36 delete).
enum ForkSessionAgentRules {
    /// The start mode for a new session in `cwd` (FR-34): the default mode of the deepest gateway
    /// project whose path is `cwd` or contains it. Nil when no project matches or it has no default.
    static func startMode(forCwd cwd: String, projects: [GatewayProject]) -> String? {
        let path = normalized(cwd)
        var best: GatewayProject?
        for project in projects {
            let root = normalized(project.path)
            guard path == root || path.hasPrefix(root + "/") else { continue }
            if best == nil || normalized(best!.path).count < root.count {
                best = project
            }
        }
        guard let mode = best?.defaultMode, !mode.isEmpty else { return nil }
        return mode
    }

    /// `session/delete` is sent only when the agent advertised it and the session exists on the agent.
    /// A session that was never created on the agent is removed on this device alone.
    static func sendsDeleteToAgent(_ capabilities: AgentCapabilityState, isPending: Bool) -> Bool {
        capabilities.deleteSession && !isPending
    }

    private static func normalized(_ path: String) -> String {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
