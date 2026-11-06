import XCTest
import ACP
@testable import Agmente
import ACPClient

private func session(_ id: String, project: String, at time: String?, title: String? = nil, status: GatewaySessionStatus = .idle, unread: Int = 0) -> GatewaySession {
    GatewaySession(sessionId: id, projectId: project, title: title, status: status,
                   lastActivity: time ?? "not a date", headSeq: 1, unread: unread)
}

private let siteProject = GatewayProject(id: "p-site", name: "Site", path: "/srv/site")
private let apiProject = GatewayProject(id: "p-api", name: "API", path: "/srv/api")
private let emptyProject = GatewayProject(id: "p-new", name: "Brand New", path: "/srv/new")

final class GatewayHomeLayoutTests: XCTestCase {
    func testSectionsAreNewestFirstAndSessionsInsideAreNewestFirst() {
        let sections = GatewayHomeLayout.sections(
            projects: [siteProject, apiProject],
            sessions: [
                session("s1", project: "p-site", at: "2026-11-06T08:00:00.000Z"),
                session("s2", project: "p-api", at: "2026-11-06T09:00:00.000Z"),
                session("s3", project: "p-site", at: "2026-11-06T10:00:00.000Z"),
            ])
        XCTAssertEqual(sections.map(\.title), ["Site", "API"], "Site has the newest session (s3)")
        XCTAssertEqual(sections[0].sessions.map(\.sessionId), ["s3", "s1"])
    }

    func testAProjectWithNoSessionsStaysAfterThoseWithSessionsAndIsStillListed() {
        let sections = GatewayHomeLayout.sections(
            projects: [emptyProject, apiProject, siteProject],
            sessions: [session("s1", project: "p-api", at: "2026-11-06T08:00:00.000Z")])
        XCTAssertEqual(sections.map(\.title), ["API", "Brand New", "Site"], "the empty ones come last, by name")
        XCTAssertTrue(sections[1].sessions.isEmpty)
    }

    func testTiesAndMissingDatesHaveAStableOrder() {
        let time = "2026-11-06T08:00:00.000Z"
        let sections = GatewayHomeLayout.sections(
            projects: [siteProject],
            sessions: [session("b", project: "p-site", at: time), session("a", project: "p-site", at: time),
                       session("z", project: "p-site", at: nil), session("y", project: "p-site", at: nil)])
        XCTAssertEqual(sections[0].sessions.map(\.sessionId), ["a", "b", "y", "z"], "dated first; ties by id")
    }

    func testSessionsOfAnUnknownProjectGoToAnOtherSectionAtTheEnd() {
        let sections = GatewayHomeLayout.sections(
            projects: [siteProject],
            sessions: [session("s1", project: "gone", at: "2026-11-06T12:00:00.000Z"), session("s2", project: "p-site", at: "2026-11-06T08:00:00.000Z")])
        XCTAssertEqual(sections.map(\.title), ["Site", "Other"])
        XCTAssertNil(sections[1].project)
        XCTAssertEqual(sections[1].id, "other")
    }

    func testSearchMatchesTitleOrProjectNameAndDropsEmptySections() {
        let sessions = [
            session("s1", project: "p-site", at: "2026-11-06T08:00:00.000Z", title: "Fix the login page"),
            session("s2", project: "p-api", at: "2026-11-06T09:00:00.000Z", title: "Add rate limit"),
            session("s3", project: "p-api", at: "2026-11-06T07:00:00.000Z", title: nil),
        ]
        func titles(_ search: String) -> [String] {
            GatewayHomeLayout.sections(projects: [siteProject, apiProject, emptyProject], sessions: sessions, search: search).map(\.title)
        }
        XCTAssertEqual(titles("LOGIN"), ["Site"])
        XCTAssertEqual(titles("api"), ["API"], "a project name matches all its sessions")
        XCTAssertEqual(titles("new chat"), ["API"], "an untitled session is searched as 'New Chat'")
        XCTAssertEqual(titles("nothing like this"), [])
        XCTAssertEqual(titles("  ").count, 3, "blank search keeps everything")
    }

    func testSummaryCountsSplitRunningAndWaitingFromTheRest() {
        let time = "2026-11-06T08:00:00.000Z"
        let sessions = [
            session("a", project: "p-site", at: time, status: .running),
            session("b", project: "p-site", at: time, status: .awaitingApproval),
            session("c", project: "p-site", at: time, status: .idle),
            session("d", project: "p-api", at: time, status: .error),
            session("e", project: "p-api", at: time, status: .unknown("paused")),
        ]
        let counts = GatewayHomeLayout.counts(sessions)
        XCTAssertEqual(counts.active, 2)
        XCTAssertEqual(counts.idle, 3)
        XCTAssertEqual(GatewayHomeLayout.counts([]).active, 0)
        XCTAssertEqual(GatewayHomeLayout.counts([]).idle, 0)
    }

    func testSectionTotals() {
        let section = GatewayHomeLayout.sections(
            projects: [siteProject],
            sessions: [session("s1", project: "p-site", at: "2026-11-06T08:00:00.000Z", status: .awaitingApproval, unread: 2),
                       session("s2", project: "p-site", at: "2026-11-06T09:00:00.000Z", status: .running, unread: 1),
                       session("s3", project: "p-site", at: "2026-11-06T10:00:00.000Z", status: .awaitingApproval)])[0]
        XCTAssertEqual(section.unread, 3)
        XCTAssertEqual(section.awaitingApproval, 2)
    }
}

private final class FakeGatewayCalls: GatewayCalling, @unchecked Sendable {
    var results: [String: ACP.Value] = [:]
    var error: Error?
    var delay: UInt64 = 0
    // The model asks for projects and sessions at the same time, so the record needs a lock.
    private let lock = NSLock()
    private var recorded: [String] = []
    var methods: [String] { lock.lock(); defer { lock.unlock() }; return recorded }

    func gatewayCall(method: String, params: ACP.Value?) async throws -> ACP.Value {
        lock.lock(); recorded.append(method); lock.unlock()
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if let error { throw error }
        return results[method] ?? .null
    }
}

@MainActor
final class GatewayHomeModelTests: XCTestCase {
    private func fake(projects: [(String, String)], sessions: [(String, String, String)]) -> FakeGatewayCalls {
        let fake = FakeGatewayCalls()
        fake.results["_agmente/projects/list"] = .object(["projects": .array(projects.map { .object(["id": .string($0.0), "name": .string($0.1), "path": .string("/srv/\($0.1)"), "defaultMode": .null]) })])
        fake.results["_agmente/sessions/index"] = .object(["sessions": .array(sessions.map {
            .object(["sessionId": .string($0.0), "projectId": .string($0.1), "title": .null, "status": .string("idle"),
                     "lastActivity": .string($0.2), "headSeq": .number(3), "unread": .number(1)])
        })])
        return fake
    }

    func testRefreshLoadsProjectsAndSessions() async {
        let calls = fake(projects: [("p1", "Site")], sessions: [("s1", "p1", "2026-11-06T08:00:00.000Z")])
        let model = GatewayHomeModel()
        model.configure { GatewayClient(calls) }
        XCTAssertFalse(model.hasLoaded)
        await model.refresh()
        XCTAssertTrue(model.hasLoaded)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.projects.map(\.name), ["Site"])
        XCTAssertEqual(model.sessions.map(\.sessionId), ["s1"])
        XCTAssertEqual(model.totalUnread, 1)
        XCTAssertEqual(model.idleCount, 1, "the card counts the gateway's sessions")
        XCTAssertEqual(model.activeCount, 0)
        XCTAssertEqual(Set(calls.methods), ["_agmente/projects/list", "_agmente/sessions/index"])
        XCTAssertFalse(model.isLoading)
    }

    func testAFailedRefreshKeepsWhatWasShownAndSaysWhy() async {
        let calls = fake(projects: [("p1", "Site")], sessions: [("s1", "p1", "2026-11-06T08:00:00.000Z")])
        let model = GatewayHomeModel()
        model.configure { GatewayClient(calls) }
        await model.refresh()
        calls.error = ACPServiceError.rpc(id: .number(1), error: .internalError("cannot read projects"))
        await model.refresh()
        XCTAssertEqual(model.errorMessage, "cannot read projects")
        XCTAssertEqual(model.sessions.count, 1, "the last good list stays")
        calls.error = ACPServiceError.disconnected
        await model.refresh()
        XCTAssertEqual(model.errorMessage, "Not connected")
        calls.error = nil
        await model.refresh()
        XCTAssertNil(model.errorMessage, "a good refresh clears the error")
    }

    func testReconfiguringDropsTheOldServersListAndIgnoresItsLateAnswer() async {
        let slow = fake(projects: [("old", "OldServer")], sessions: [])
        slow.delay = 150_000_000
        let model = GatewayHomeModel()
        model.configure { GatewayClient(slow) }
        let pending = Task { await model.refresh() }
        try? await Task.sleep(nanoseconds: 30_000_000)
        let other = fake(projects: [("new", "NewServer")], sessions: [])
        model.configure { GatewayClient(other) }
        XCTAssertTrue(model.projects.isEmpty)
        await pending.value
        XCTAssertTrue(model.projects.isEmpty, "the answer of the old server arrived late and was dropped")
        XCTAssertFalse(model.hasLoaded)
        await model.refresh()
        XCTAssertEqual(model.projects.map(\.name), ["NewServer"])
    }

    func testWithNoClientRefreshDoesNothing() async {
        let model = GatewayHomeModel()
        model.configure(clientProvider: nil)
        await model.refresh()
        XCTAssertFalse(model.hasLoaded)
        XCTAssertFalse(model.isLoading)
        model.configure { nil }
        await model.refresh()
        XCTAssertFalse(model.hasLoaded, "not connected yet: nothing is asked")
    }
}
