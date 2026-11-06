import Foundation
import ACPClient

/// One project on the gateway home screen with its sessions (FR-26). Pure data, so the ordering
/// rules are tested without a view.
struct GatewayProjectSection: Identifiable, Equatable {
    /// The project, or nil for sessions whose project the gateway no longer lists.
    let project: GatewayProject?
    let sessions: [GatewaySession]

    var id: String { project?.id ?? "other" }
    var title: String { project?.name ?? "Other" }
    var unread: Int { sessions.reduce(0) { $0 + $1.unread } }
    var awaitingApproval: Int { sessions.filter { $0.status == .awaitingApproval }.count }
    var lastActivity: Date? { sessions.compactMap(\.lastActivityDate).max() }
}

enum GatewayHomeLayout {
    /// The counts for the summary card: a session is active while a turn runs or an approval waits,
    /// idle otherwise (an errored session is idle too: nothing is running in it).
    static func counts(_ sessions: [GatewaySession]) -> (active: Int, idle: Int) {
        let active = sessions.filter { $0.status == .running || $0.status == .awaitingApproval }.count
        return (active, sessions.count - active)
    }

    /// Sections newest first by their latest session activity; a project with no sessions comes after
    /// those that have some, by name, so a new session can still be started in it. Inside a section,
    /// sessions are newest first, with the session id as the tie-break so the order never flickers.
    /// Sessions of an unknown project go in a last "Other" section. A search text keeps sessions whose
    /// title or project name contains it, and drops the sections left empty.
    static func sections(projects: [GatewayProject], sessions: [GatewaySession], search: String = "") -> [GatewayProjectSection] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ session: GatewaySession, project: GatewayProject?) -> Bool {
            guard !query.isEmpty else { return true }
            return (session.title ?? "New Chat").localizedCaseInsensitiveContains(query)
                || (project?.name ?? "Other").localizedCaseInsensitiveContains(query)
        }
        func ordered(_ list: [GatewaySession]) -> [GatewaySession] {
            list.sorted { lhs, rhs in
                switch (lhs.lastActivityDate, rhs.lastActivityDate) {
                case let (l?, r?) where l != r: return l > r
                case (_?, nil): return true
                case (nil, _?): return false
                default: return lhs.sessionId < rhs.sessionId
                }
            }
        }

        let byProject = Dictionary(grouping: sessions, by: \.projectId)
        var result: [GatewayProjectSection] = []
        for project in projects {
            let kept = ordered((byProject[project.id] ?? []).filter { matches($0, project: project) })
            if kept.isEmpty && !query.isEmpty { continue }
            result.append(GatewayProjectSection(project: project, sessions: kept))
        }
        result.sort { lhs, rhs in
            switch (lhs.lastActivity, rhs.lastActivity) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
        let known = Set(projects.map(\.id))
        let orphans = ordered(sessions.filter { !known.contains($0.projectId) && matches($0, project: nil) })
        if !orphans.isEmpty {
            result.append(GatewayProjectSection(project: nil, sessions: orphans))
        }
        return result
    }
}
