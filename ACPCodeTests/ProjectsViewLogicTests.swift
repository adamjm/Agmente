import Testing
import ACPClient
@testable import ACPCode

// Sorting and counting for the Projects view and project detail (Fork/Drawer/ProjectsView.swift).

struct ProjectsViewLogicTests {
    private func session(_ id: String, project: String, activity: String, title: String? = nil) -> GatewaySession {
        GatewaySession(
            sessionId: id,
            projectId: project,
            title: title,
            status: .idle,
            lastActivity: activity,
            headSeq: 0,
            unread: 0
        )
    }

    @Test func sessionsOfOneProjectAreListedNewestFirst() {
        let sessions = [
            session("old", project: "p1", activity: "2026-11-01T10:00:00.000Z"),
            session("other", project: "p2", activity: "2026-11-09T10:00:00.000Z"),
            session("new", project: "p1", activity: "2026-11-05T10:00:00.000Z"),
        ]
        let ids = ProjectsLogic.sessions(in: "p1", from: sessions).map(\.sessionId)
        #expect(ids == ["new", "old"])
    }

    @Test func sessionWithoutAReadableDateSortsLastAndTiesBreakById() {
        let sessions = [
            session("b", project: "p1", activity: "not a date"),
            session("a", project: "p1", activity: "2026-11-05T10:00:00.000Z"),
            session("c", project: "p1", activity: "not a date"),
        ]
        let ids = ProjectsLogic.sessions(in: "p1", from: sessions).map(\.sessionId)
        #expect(ids == ["a", "b", "c"])
    }

    @Test func sessionCountCountsOnlyTheNamedProject() {
        let sessions = [
            session("1", project: "p1", activity: "2026-11-05T10:00:00.000Z"),
            session("2", project: "p2", activity: "2026-11-05T10:00:00.000Z"),
            session("3", project: "p1", activity: "2026-11-05T10:00:00.000Z"),
        ]
        #expect(ProjectsLogic.sessionCount(projectId: "p1", sessions: sessions) == 2)
        #expect(ProjectsLogic.sessionCount(projectId: "missing", sessions: sessions) == 0)
    }

    @Test func sessionCountLabelUsesTheSingularForOne() {
        #expect(ProjectsLogic.sessionCountLabel(0) == "0 sessions")
        #expect(ProjectsLogic.sessionCountLabel(1) == "1 session")
        #expect(ProjectsLogic.sessionCountLabel(3) == "3 sessions")
    }
}
