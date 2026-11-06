import XCTest
import ACP
@testable import ACPClient

private final class GitFake: GatewayCalling, @unchecked Sendable {
    var calls: [(method: String, params: ACP.Value?)] = []
    var results: [String: ACP.Value] = [:]
    var error: Error?

    func gatewayCall(method: String, params: ACP.Value?) async throws -> ACP.Value {
        calls.append((method, params))
        if let error { throw error }
        return results[method] ?? .null
    }
}

final class GatewayGitTests: XCTestCase {
    func testStatusDecodesTheDocumentedShape() async throws {
        let fake = GitFake()
        fake.results["_agmente/git/status"] = .object([
            "branch": .string("main"), "upstream": .string("origin/main"), "ahead": .number(2), "behind": .number(1),
            "files": .array([
                .object(["path": .string("a.txt"), "status": .string("modified"), "staged": .bool(true), "added": .number(3), "removed": .number(1)]),
                .object(["path": .string("new.txt"), "status": .string("untracked"), "staged": .bool(false), "added": .null, "removed": .null]),
                .object(["path": .string("odd"), "status": .string("future_status"), "staged": .bool(false), "added": .null, "removed": .null]),
            ]),
            "hash": .string("abc"), "truncated": .bool(true),
        ])
        let status = try await GatewayClient(fake).gitStatus(projectId: "p1")
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.upstream, "origin/main")
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 1)
        XCTAssertTrue(status.truncated)
        XCTAssertEqual(status.hash, "abc")
        XCTAssertEqual(status.files[0], GatewayGitFile(path: "a.txt", status: .modified, staged: true, added: 3, removed: 1))
        XCTAssertNil(status.files[1].added, "untracked has no counts")
        XCTAssertEqual(status.files[2].status, .unknown("future_status"))
        XCTAssertEqual(fake.calls.first?.params, .object(["projectId": .string("p1")]))
    }

    func testStatusWithDetachedHeadAndNoUpstreamDecodes() async throws {
        let fake = GitFake()
        fake.results["_agmente/git/status"] = .object(["branch": .null, "upstream": .null, "ahead": .number(0), "behind": .number(0),
                                                       "files": .array([]), "hash": .string("h"), "truncated": .bool(false)])
        let status = try await GatewayClient(fake).gitStatus(projectId: "p1")
        XCTAssertNil(status.branch)
        XCTAssertNil(status.upstream)
        XCTAssertTrue(status.files.isEmpty)
    }

    func testPathDiffSendsPathAndStagedOnlyWhenSet() async throws {
        let fake = GitFake()
        fake.results["_agmente/git/diff"] = .object(["diff": .string("d"), "truncated": .bool(false), "hidden": .array([])])
        let client = GatewayClient(fake)
        _ = try await client.gitDiff(projectId: "p1", path: "-x.txt")
        XCTAssertEqual(fake.calls.last?.params, .object(["projectId": .string("p1"), "path": .string("-x.txt")]))
        _ = try await client.gitDiff(projectId: "p1", path: "a.txt", staged: true)
        XCTAssertEqual(fake.calls.last?.params, .object(["projectId": .string("p1"), "path": .string("a.txt"), "staged": .bool(true)]))
        _ = try await client.gitDiff(projectId: "p1")
        XCTAssertEqual(fake.calls.last?.params, .object(["projectId": .string("p1")]), "no path means the whole tree")
    }

    func testTreeDiffSendsBothTrees() async throws {
        let fake = GitFake()
        fake.results["_agmente/git/diff"] = .object(["diff": .string(""), "truncated": .bool(false), "hidden": .array([])])
        _ = try await GatewayClient(fake).gitDiff(projectId: "p1", fromTree: "aa", toTree: "bb", path: "f")
        XCTAssertEqual(fake.calls.last?.params, .object(["projectId": .string("p1"), "fromTree": .string("aa"), "toTree": .string("bb"), "path": .string("f")]))
    }

    func testDiffKeepsHiddenNamesAndToleratesMissingOptionalKeys() async throws {
        let fake = GitFake()
        fake.results["_agmente/git/diff"] = .object(["diff": .string("secret file changed: .env (content hidden)\n"), "hidden": .array([.string(".env")])])
        let diff = try await GatewayClient(fake).gitDiff(projectId: "p1")
        XCTAssertEqual(diff.hidden, [".env"])
        XCTAssertFalse(diff.truncated)
    }

    func testLogPagesWithTheCursor() async throws {
        let fake = GitFake()
        fake.results["_agmente/git/log"] = .object([
            "commits": .array([.object(["hash": .string("1234567890"), "shortHash": .string("1234567"), "author": .string("Ann"),
                                        "date": .string("2026-11-06T08:08:11+10:00"), "subject": .string("Fix")])]),
            "nextCursor": .string("50"),
        ])
        let client = GatewayClient(fake)
        let page = try await client.gitLog(projectId: "p1", limit: 50, cursor: "0")
        XCTAssertEqual(page.commits.map(\.subject), ["Fix"])
        XCTAssertEqual(page.nextCursor, "50")
        XCTAssertNotNil(page.commits[0].dateValue)
        XCTAssertEqual(fake.calls.last?.params, .object(["projectId": .string("p1"), "limit": .int(50), "cursor": .string("0")]))
        fake.results["_agmente/git/log"] = .object(["commits": .array([])])
        let empty = try await client.gitLog(projectId: "p1")
        XCTAssertNil(empty.nextCursor)
        XCTAssertEqual(fake.calls.last?.params, .object(["projectId": .string("p1")]))
    }

    func testTurnDiffAndItsErrors() async throws {
        let fake = GitFake()
        fake.results["_agmente/git/turnDiff"] = .object(["diff": .string("x"), "truncated": .bool(false), "hidden": .array([]),
                                                         "fromTree": .string("aa"), "toTree": .string("bb")])
        let client = GatewayClient(fake)
        let diff = try await client.gitTurnDiff(sessionId: "s1", turn: 3)
        XCTAssertEqual(diff.fromTree, "aa")
        XCTAssertEqual(fake.calls.last?.params, .object(["sessionId": .string("s1"), "turn": .int(3)]))

        func failure(_ message: String) async -> GatewayError? {
            fake.error = ACPServiceError.rpc(id: .number(1), error: .serverError(code: -32000, message: message))
            do { _ = try await client.gitTurnDiff(sessionId: "s1", turn: 1); return nil } catch { return error as? GatewayError }
        }
        let none = await failure("no snapshot for this turn")
        XCTAssertEqual(none?.isNoSnapshot, true)
        XCTAssertEqual(none?.isTurnRunning, false)
        let running = await failure("turn is still running")
        XCTAssertEqual(running?.isTurnRunning, true)
        let notRepo = await failure("not a git repository")
        XCTAssertEqual(notRepo?.isNotARepository, true)
        XCTAssertEqual(notRepo?.isNoSnapshot, false)
        XCTAssertFalse(GatewayError.rpc(code: -32602, message: "not a git repository").isNotARepository, "the code matters too")
    }

    func testChangedNotificationParsing() {
        XCTAssertEqual(GatewayGitChanged.parse(.object(["projectId": .string("p1"), "hash": .string("h")])), GatewayGitChanged(projectId: "p1", hash: "h"))
        XCTAssertNil(GatewayGitChanged.parse(.object(["projectId": .string("p1")])))
        XCTAssertNil(GatewayGitChanged.parse(.object(["projectId": .string(""), "hash": .string("h")])))
        XCTAssertNil(GatewayGitChanged.parse(nil))
    }
}
