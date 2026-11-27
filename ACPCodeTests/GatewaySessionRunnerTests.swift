import XCTest
import ACP
@testable import ACPCode
import ACPClient

/// Records each gateway call and answers from `results`, or fails with `error`.
private final class SessionRunnerFakeGateway: GatewayCalling, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(method: String, params: ACP.Value?)] = []
    var results: [String: ACP.Value] = [:]
    var error: Error?
    var onCall: ((String) -> Void)?

    var calls: [(method: String, params: ACP.Value?)] { lock.lock(); defer { lock.unlock() }; return recorded }

    func gatewayCall(method: String, params: ACP.Value?) async throws -> ACP.Value {
        lock.lock(); recorded.append((method, params)); lock.unlock()
        onCall?(method)
        if let error { throw error }
        return results[method] ?? .null
    }
}

private let bob = GatewayRunner(id: "bob", name: "Bob")
private let codex = GatewayRunner(id: "codex", name: "Codex")
private let claude = GatewayRunner(id: "claude", name: "Claude Code")

private let siteProject = GatewayProject(id: "p1", name: "Site", path: "/srv/site", runner: "bob")

final class GatewaySessionRunnerRulesTests: XCTestCase {
    func testThePickerIsOfferedOnlyWithTwoOrMoreRunners() {
        XCTAssertTrue(GatewaySessionRunnerRules.choices([]).isEmpty, "an old gateway")
        XCTAssertTrue(GatewaySessionRunnerRules.choices([bob]).isEmpty)
        XCTAssertEqual(GatewaySessionRunnerRules.choices([bob, codex]).map(\.id), ["bob", "codex"])
    }

    func testTheDefaultSelectionIsTheProjectsRunnerThenTheGatewayDefaultThenTheFirst() {
        let onCodex = GatewayProject(id: "p", name: "P", path: "/p", runner: "codex")
        XCTAssertEqual(GatewaySessionRunnerRules.defaultSelection(project: onCodex, runners: [bob, codex], defaultRunner: "bob"), "codex")
        let unlisted = GatewayProject(id: "p", name: "P", path: "/p", runner: "gone")
        XCTAssertEqual(GatewaySessionRunnerRules.defaultSelection(project: unlisted, runners: [bob, codex], defaultRunner: "codex"), "codex")
        let none = GatewayProject(id: "p", name: "P", path: "/p")
        XCTAssertEqual(GatewaySessionRunnerRules.defaultSelection(project: none, runners: [bob, codex], defaultRunner: "nope"), "bob")
        XCTAssertNil(GatewaySessionRunnerRules.defaultSelection(project: onCodex, runners: [codex], defaultRunner: "codex"), "one runner is no choice")
        XCTAssertNil(GatewaySessionRunnerRules.defaultSelection(project: onCodex, runners: [], defaultRunner: nil))
    }

    func testTheWorktreeToggleNeedsARunnerChoiceADifferentRunnerAndANonWorktreeProject() {
        XCTAssertFalse(GatewaySessionRunnerRules.offersWorktree(project: siteProject, runners: [bob, codex], selected: "bob", defaultRunner: "bob"), "the project's own runner")
        XCTAssertTrue(GatewaySessionRunnerRules.offersWorktree(project: siteProject, runners: [bob, codex], selected: "codex", defaultRunner: "bob"))
        XCTAssertFalse(GatewaySessionRunnerRules.offersWorktree(project: siteProject, runners: [bob], selected: "codex", defaultRunner: "bob"), "one runner offers nothing")
        XCTAssertFalse(GatewaySessionRunnerRules.offersWorktree(project: siteProject, runners: [], selected: nil, defaultRunner: nil), "an old gateway")
        let child = GatewayProject(id: "c", name: "Site (Codex)", path: "/srv/site-codex-1", runner: "codex", parentId: "p1", branch: "acpcode/codex/1")
        XCTAssertFalse(GatewaySessionRunnerRules.offersWorktree(project: child, runners: [bob, codex], selected: "bob", defaultRunner: "bob"), "a worktree project has no worktree of its own")
    }

    func testAProjectWithoutARunnerComparesAgainstTheGatewayDefault() {
        let old = GatewayProject(id: "p", name: "P", path: "/p")
        XCTAssertFalse(GatewaySessionRunnerRules.differsFromProject(selected: "bob", project: old, defaultRunner: "bob"))
        XCTAssertTrue(GatewaySessionRunnerRules.differsFromProject(selected: "codex", project: old, defaultRunner: "bob"))
    }

    func testTheToggleResetsWhenTheRunnerGoesBackAndIsNeverOnByDefault() {
        var state = GatewayNewSessionRunnerState(runners: [bob, codex], defaultRunner: "bob", project: siteProject)
        XCTAssertEqual(state.selectedRunner, "bob")
        XCTAssertFalse(state.worktree, "never on by default")
        XCTAssertFalse(state.offersWorktree)
        state.setWorktree(true)
        XCTAssertFalse(state.worktree, "the toggle cannot be on while it is not offered")

        state.select(runner: "codex")
        XCTAssertTrue(state.offersWorktree)
        XCTAssertFalse(state.worktree, "choosing another runner does not turn it on")
        state.setWorktree(true)
        XCTAssertTrue(state.worktree)
        XCTAssertEqual(state.choice, GatewayNewSessionChoice(runner: "codex", worktree: true))

        state.select(runner: "bob")
        XCTAssertFalse(state.worktree, "back to the project's own runner resets it")
        state.select(runner: "codex")
        XCTAssertFalse(state.worktree, "and it stays off when the other runner is chosen again")
        XCTAssertEqual(state.choice, GatewayNewSessionChoice(runner: "codex", worktree: false))
    }

    func testChoosingAnotherProjectResetsThePickerAndTheToggle() {
        let other = GatewayProject(id: "p2", name: "API", path: "/srv/api", runner: "codex")
        var state = GatewayNewSessionRunnerState(runners: [bob, codex], defaultRunner: "bob", project: siteProject)
        state.select(runner: "codex")
        state.setWorktree(true)
        state.select(project: other)
        XCTAssertEqual(state.selectedRunner, "codex")
        XCTAssertFalse(state.worktree)
    }

    func testTheProjectsOwnRunnerSendsNoRunnerAndNoWorktree() {
        let state = GatewayNewSessionRunnerState(runners: [bob, codex], defaultRunner: "bob", project: siteProject)
        XCTAssertEqual(state.choice, .projectDefault)
    }

    func testAnOldGatewayChangesNothing() {
        var state = GatewayNewSessionRunnerState(runners: [], defaultRunner: nil, project: siteProject)
        XCTAssertFalse(state.offersRunner)
        XCTAssertFalse(state.offersWorktree)
        XCTAssertNil(state.selectedRunner)
        state.select(runner: "codex")
        state.setWorktree(true)
        XCTAssertEqual(state.choice, .projectDefault)
        let single = GatewayNewSessionRunnerState(runners: [bob], defaultRunner: "bob", project: siteProject)
        XCTAssertFalse(single.offersRunner)
        XCTAssertEqual(single.choice, .projectDefault)
    }

    func testTheSessionLabelShowsRunnerAndBranchOnlyWithTwoOrMoreRunners() {
        func session(_ runner: String?) -> GatewaySession {
            GatewaySession(sessionId: "s", projectId: "p1", title: nil, status: .idle, lastActivity: "2026-01-01T00:00:00.000Z", headSeq: 0, unread: 0, runner: runner)
        }
        let child = GatewayProject(id: "c", name: "Site (Codex)", path: "/c", runner: "codex", parentId: "p1", branch: "acpcode/codex/1")
        XCTAssertEqual(GatewaySessionRunnerRules.sessionLabel(session("codex"), project: siteProject, runners: [bob, codex]), "Codex")
        XCTAssertEqual(GatewaySessionRunnerRules.sessionLabel(session("codex"), project: child, runners: [bob, codex]), "Codex · acpcode/codex/1")
        XCTAssertNil(GatewaySessionRunnerRules.sessionLabel(session("codex"), project: child, runners: [codex]), "a single runner shows nothing")
        XCTAssertNil(GatewaySessionRunnerRules.sessionLabel(session("codex"), project: child, runners: []), "an old gateway shows nothing")
        XCTAssertNil(GatewaySessionRunnerRules.sessionLabel(session(nil), project: siteProject, runners: [bob, codex]), "no runner on the row")
    }
}

@MainActor
final class GatewayNewSessionStarterTests: XCTestCase {
    private let childValue: ACP.Value = .object(["project": .object([
        "id": .string("c1"), "name": .string("Site (Codex)"), "path": .string("/srv/site-codex-1a2b3c4d"),
        "runner": .string("codex"), "parentId": .string("p1"), "branch": .string("acpcode/codex/1a2b3c4d"),
    ])])

    /// The steps the starter took, in order.
    private final class Log { var steps: [String] = [] }

    func testWorktreeOnCreatesTheWorktreeThenReloadsThenStartsInTheChildsFolderWithTheRunner() async {
        let gateway = SessionRunnerFakeGateway()
        gateway.results["_acpcode/projects/createWorktree"] = childValue
        let log = Log()
        gateway.onCall = { log.steps.append("call:\($0)") }
        let message = await GatewayNewSessionStarter.start(
            project: siteProject,
            choice: GatewayNewSessionChoice(runner: "codex", worktree: true),
            client: GatewayClient(gateway),
            reload: { child in log.steps.append("reload:\(child?.id ?? "-")") },
            begin: { cwd, runner in log.steps.append("session/new:\(cwd):\(runner ?? "-")") }
        )
        XCTAssertNil(message)
        XCTAssertEqual(log.steps, [
            "call:_acpcode/projects/createWorktree",
            "reload:c1",
            "session/new:/srv/site-codex-1a2b3c4d:codex",
        ])
        XCTAssertEqual(gateway.calls.first?.params, .object(["projectId": .string("p1"), "runner": .string("codex")]))
    }

    func testAFailedWorktreeShowsTheGatewaysMessageAndStartsNothing() async {
        let gateway = SessionRunnerFakeGateway()
        gateway.error = ACPServiceError.rpc(id: .number(1), error: .invalidParams("project is not a git repository with a commit"))
        let log = Log()
        let message = await GatewayNewSessionStarter.start(
            project: siteProject,
            choice: GatewayNewSessionChoice(runner: "codex", worktree: true),
            client: GatewayClient(gateway),
            reload: { _ in log.steps.append("reload") },
            begin: { _, _ in log.steps.append("session/new") }
        )
        XCTAssertEqual(message, "project is not a git repository with a commit")
        XCTAssertTrue(log.steps.isEmpty, "no reload and no session")
    }

    func testWithoutAWorktreeNothingIsCreatedAndTheRunnerRidesOnSessionNew() async {
        let gateway = SessionRunnerFakeGateway()
        let log = Log()
        let message = await GatewayNewSessionStarter.start(
            project: siteProject,
            choice: GatewayNewSessionChoice(runner: "codex", worktree: false),
            client: GatewayClient(gateway),
            reload: { _ in log.steps.append("reload") },
            begin: { cwd, runner in log.steps.append("session/new:\(cwd):\(runner ?? "-")") }
        )
        XCTAssertNil(message)
        XCTAssertEqual(log.steps, ["session/new:/srv/site:codex"])
        XCTAssertTrue(gateway.calls.isEmpty, "no worktree call")
    }

    func testTheProjectsOwnRunnerSendsNoRunner() async {
        let log = Log()
        _ = await GatewayNewSessionStarter.start(
            project: siteProject,
            choice: .projectDefault,
            client: nil,
            reload: { _ in log.steps.append("reload") },
            begin: { cwd, runner in log.steps.append("session/new:\(cwd):\(runner ?? "-")") }
        )
        XCTAssertEqual(log.steps, ["session/new:/srv/site:-"], "an old gateway changes nothing: the same cwd, no runner")
    }

    func testWorktreeWithoutAConnectionStartsNothing() async {
        let log = Log()
        let message = await GatewayNewSessionStarter.start(
            project: siteProject,
            choice: GatewayNewSessionChoice(runner: "codex", worktree: true),
            client: nil,
            reload: { _ in log.steps.append("reload") },
            begin: { _, _ in log.steps.append("session/new") }
        )
        XCTAssertNotNil(message)
        XCTAssertTrue(log.steps.isEmpty)
    }

    func testTheNewProjectAppearsInTheHomeListAfterTheReload() async {
        let gateway = SessionRunnerFakeGateway()
        gateway.results["_acpcode/projects/createWorktree"] = childValue
        gateway.results["_acpcode/projects/list"] = .object(["projects": .array([
            .object(["id": .string("p1"), "name": .string("Site"), "path": .string("/srv/site")]),
            childValue.objectValue?["project"] ?? .null,
        ])])
        gateway.results["_acpcode/sessions/index"] = .object(["sessions": .array([])])
        let home = GatewayHomeModel()
        home.configure { GatewayClient(gateway) }
        let message = await GatewayNewSessionStarter.start(
            project: siteProject,
            choice: GatewayNewSessionChoice(runner: "codex", worktree: true),
            client: GatewayClient(gateway),
            reload: { child in
                await home.refresh()
                if let child { home.select(projectId: child.id) }
            },
            begin: { _, _ in }
        )
        XCTAssertNil(message)
        XCTAssertEqual(home.projects.map(\.id), ["p1", "c1"])
        XCTAssertEqual(home.projects.last?.parentId, "p1")
        XCTAssertEqual(home.selectedProjectId, "c1")
    }
}
