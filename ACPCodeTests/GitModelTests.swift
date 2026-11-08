import XCTest
import ACP
@testable import ACPCode
import ACPClient

private final class GitCalls: GatewayCalling, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(method: String, params: ACP.Value?)] = []
    var handler: @Sendable (String, ACP.Value?) async throws -> ACP.Value = { _, _ in .null }

    var calls: [(method: String, params: ACP.Value?)] { lock.lock(); defer { lock.unlock() }; return _calls }
    func count(_ method: String) -> Int { calls.filter { $0.method == method }.count }

    func gatewayCall(method: String, params: ACP.Value?) async throws -> ACP.Value {
        lock.lock(); _calls.append((method, params)); lock.unlock()
        return try await handler(method, params)
    }
}

private func statusValue(branch: String? = "main", hash: String = "h1", files: [(String, String, Bool)] = [("a.txt", "modified", false)]) -> ACP.Value {
    .object([
        "branch": branch.map { .string($0) } ?? .null, "upstream": .null, "ahead": .number(1), "behind": .number(0),
        "files": .array(files.map { .object(["path": .string($0.0), "status": .string($0.1), "staged": .bool($0.2), "added": .number(1), "removed": .number(0)]) }),
        "hash": .string(hash), "truncated": .bool(false),
    ])
}

private func commit(_ h: String) -> ACP.Value {
    .object(["hash": .string(h), "shortHash": .string(h), "author": .string("A"), "date": .string("2026-11-06T08:00:00Z"), "subject": .string("s\(h)")])
}

private func rpcError(_ message: String, code: Int = -32000) -> Error {
    ACPServiceError.rpc(id: .number(1), error: .serverError(code: code, message: message))
}

@MainActor
final class GitProjectModelTests: XCTestCase {
    private func make(_ calls: GitCalls) -> GitProjectModel {
        GitProjectModel(projectId: "p1", clientProvider: { GatewayClient(calls) })
    }

    func testRefreshLoadsTheStatusAndLoadIfNeededLoadsOnlyOnce() async {
        let calls = GitCalls()
        calls.handler = { _, _ in statusValue() }
        let model = make(calls)
        await model.loadIfNeeded()
        await model.loadIfNeeded()
        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.status?.branch, "main")
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(calls.count("_acpcode/git/status"), 1)
    }

    func testNotARepositoryAndOtherErrorsAreDistinguished() async {
        let calls = GitCalls()
        calls.handler = { _, _ in throw rpcError("not a git repository") }
        let model = make(calls)
        await model.refresh()
        XCTAssertEqual(model.state, .notRepository)
        XCTAssertNil(model.status)

        calls.handler = { _, _ in throw rpcError("git timeout") }
        await model.refresh()
        XCTAssertEqual(model.state, .failed("git timeout"))
    }

    func testAFailedRefreshKeepsTheLastStatusForTheChip() async {
        let calls = GitCalls()
        calls.handler = { _, _ in statusValue() }
        let model = make(calls)
        await model.refresh()
        calls.handler = { _, _ in throw rpcError("git failed") }
        await model.refresh()
        XCTAssertEqual(model.state, .failed("git failed"))
        XCTAssertEqual(model.status?.branch, "main", "the branch chip survives a failed refresh")
    }

    func testChangedWithTheHeldHashDoesNothingAndANewHashRefreshes() async {
        let calls = GitCalls()
        calls.handler = { _, _ in statusValue(hash: "h1") }
        let model = make(calls)
        await model.refresh()
        await model.changed(hash: "h1")
        XCTAssertEqual(calls.count("_acpcode/git/status"), 1, "same hash: no refresh")
        calls.handler = { _, _ in statusValue(branch: "dev", hash: "h2") }
        await model.changed(hash: "h2")
        XCTAssertEqual(calls.count("_acpcode/git/status"), 2)
        XCTAssertEqual(model.status?.branch, "dev")
    }

    func testRefreshesDuringALoadFoldIntoOneMoreLoad() async {
        let calls = GitCalls()
        let gate = AsyncGate()
        calls.handler = { _, _ in await gate.wait(); return statusValue() }
        let model = make(calls)
        let first = Task { await model.refresh() }
        while calls.count("_acpcode/git/status") == 0 { await Task.yield() }
        await model.refresh() // returns at once, marks one more load
        await model.refresh()
        await gate.open()
        await first.value
        XCTAssertEqual(calls.count("_acpcode/git/status"), 2, "three requests during one load make exactly one more")
    }

    func testDiffIsRequestedOnlyForAPathInTheStatus() async {
        let calls = GitCalls()
        calls.handler = { method, _ in
            method == "_acpcode/git/status" ? statusValue(files: [("a.txt", "modified", true), ("-x.txt", "untracked", false)])
                : .object(["diff": .string("diff --git a/a.txt b/a.txt\n"), "truncated": .bool(false), "hidden": .array([])])
        }
        let model = make(calls)
        await model.openDiff(path: "a.txt", staged: false)
        XCTAssertEqual(calls.count("_acpcode/git/diff"), 0, "no status yet: no diff call")
        await model.refresh()
        await model.openDiff(path: "../etc/passwd", staged: false)
        XCTAssertEqual(calls.count("_acpcode/git/diff"), 0, "a path that is not in the status is never sent")
        await model.openDiff(path: "-x.txt", staged: false)
        XCTAssertEqual(calls.count("_acpcode/git/diff"), 1)
        XCTAssertEqual(calls.calls.last?.params, .object(["projectId": .string("p1"), "path": .string("-x.txt")]))
        await model.openDiff(path: "a.txt", staged: true)
        XCTAssertEqual(calls.calls.last?.params, .object(["projectId": .string("p1"), "path": .string("a.txt"), "staged": .bool(true)]))
        guard case .loaded(let diff) = model.diff else { return XCTFail("expected a loaded diff") }
        XCTAssertTrue(diff.diff.hasPrefix("diff --git"))
    }

    func testDiffErrorIsShown() async {
        let calls = GitCalls()
        calls.handler = { method, _ in
            if method == "_acpcode/git/status" { return statusValue() }
            throw rpcError("path is not in the current status", code: -32602)
        }
        let model = make(calls)
        await model.refresh()
        await model.openDiff(path: "a.txt", staged: false)
        XCTAssertEqual(model.diff, .failed("path is not in the current status"))
    }

    func testLogPagesAndDropsACommitSeenOnAnEarlierPage() async {
        let calls = GitCalls()
        calls.handler = { _, params in
            if params?.objectValue?["cursor"]?.stringValue == "50" {
                return .object(["commits": .array([commit("c2"), commit("c3")])])
            }
            return .object(["commits": .array([commit("c1"), commit("c2")]), "nextCursor": .string("50")])
        }
        let model = make(calls)
        await model.loadLog()
        XCTAssertEqual(model.commits.map(\.hash), ["c1", "c2"])
        XCTAssertEqual(model.nextCursor, "50")
        await model.loadMoreLog()
        XCTAssertEqual(model.commits.map(\.hash), ["c1", "c2", "c3"], "c2 shifted onto the second page and is not shown twice")
        XCTAssertNil(model.nextCursor)
        await model.loadMoreLog()
        XCTAssertEqual(calls.count("_acpcode/git/log"), 2, "no cursor, no call")
    }

    func testLogOnANonRepository() async {
        let calls = GitCalls()
        calls.handler = { _, _ in throw rpcError("not a git repository") }
        let model = make(calls)
        await model.loadLog()
        XCTAssertEqual(model.logState, .notRepository)
    }
}

@MainActor
final class GitTurnDiffModelTests: XCTestCase {
    private func run(_ handler: @escaping @Sendable (String, ACP.Value?) async throws -> ACP.Value) async -> GitTurnDiffModel {
        let calls = GitCalls()
        calls.handler = handler
        let model = GitTurnDiffModel(sessionId: "s1", turn: 2, clientProvider: { GatewayClient(calls) })
        await model.load()
        return model
    }

    func testLoadedDiffIsSplitIntoFiles() async {
        let model = await run { _, _ in
            .object(["diff": .string("diff --git a/new.txt b/new.txt\nnew file mode 100644\n--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1 @@\n+x\n"),
                     "truncated": .bool(false), "hidden": .array([]), "fromTree": .string("aa"), "toTree": .string("bb")])
        }
        XCTAssertEqual(model.files.map(\.path), ["new.txt"])
    }

    func testNoSnapshotRunningAndOtherErrorsAreDistinctStates() async {
        let none = await run { _, _ in throw rpcError("no snapshot for this turn") }
        XCTAssertEqual(none.state, .noSnapshot)
        let running = await run { _, _ in throw rpcError("turn is still running") }
        XCTAssertEqual(running.state, .running)
        let other = await run { _, _ in throw rpcError("git failed") }
        XCTAssertEqual(other.state, .failed("git failed"))
        let bad = await run { _, _ in throw rpcError("unknown session", code: -32602) }
        XCTAssertEqual(bad.state, .failed("unknown session"), "only the -32000 texts map to the special states")
    }

    func testNoClientIsReportedNotCrashed() async {
        let model = GitTurnDiffModel(sessionId: "s1", turn: 1, clientProvider: { nil })
        await model.load()
        XCTAssertEqual(model.state, .failed("Not connected"))
    }
}

@MainActor
final class GitStoreTests: XCTestCase {
    func testChangedRefreshesOnlyAKnownProjectOfTheSelectedServer() async {
        let calls = GitCalls()
        calls.handler = { _, _ in statusValue(hash: "h1") }
        let server = UUID()
        let store = GitStore(serverId: { server }, client: { GatewayClient(calls) })
        await store.model(for: "p1").refresh()
        calls.handler = { _, _ in statusValue(branch: "dev", hash: "h2") }
        store.handleChanged(.object(["projectId": .string("p-unknown"), "hash": .string("zz")]))
        store.handleChanged(.object(["projectId": .string("p1")])) // no hash: malformed
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(calls.count("_acpcode/git/status"), 1, "unknown project and malformed params do nothing")
        store.handleChanged(.object(["projectId": .string("p1"), "hash": .string("h2")]))
        for _ in 0..<100 where store.model(for: "p1").status?.branch != "dev" { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(store.model(for: "p1").status?.branch, "dev")
    }

    func testModelsAreKeptPerServer() {
        var server = UUID()
        let store = GitStore(serverId: { server }, client: { nil })
        let first = store.model(for: "p1")
        XCTAssertTrue(first === store.model(for: "p1"))
        server = UUID()
        XCTAssertFalse(first === store.model(for: "p1"), "another server does not share the first one's state")
    }

    func testSessionProjectComesFromTheIndexOnce() async {
        let calls = GitCalls()
        calls.handler = { _, _ in
            .object(["sessions": .array([.object(["sessionId": .string("s1"), "projectId": .string("p9"), "title": .null, "status": .string("idle"),
                                                  "lastActivity": .string("2026-11-06T08:00:00.000Z"), "headSeq": .number(1), "unread": .number(0)])])])
        }
        let store = GitStore(serverId: { nil }, client: { GatewayClient(calls) })
        let first = await store.projectId(forSession: "s1")
        let again = await store.projectId(forSession: "s1")
        let missing = await store.projectId(forSession: "nope")
        XCTAssertEqual(first, "p9")
        XCTAssertEqual(again, "p9")
        XCTAssertNil(missing)
        XCTAssertEqual(calls.count("_acpcode/sessions/index"), 2, "one call for s1 (cached after), one for the unknown session")
    }

    func testConnectionResetMakesModelsLoadAgainAndBumpsTheEpoch() async {
        let calls = GitCalls()
        calls.handler = { _, _ in statusValue() }
        let store = GitStore(serverId: { nil }, client: { GatewayClient(calls) })
        let model = store.model(for: "p1")
        await model.loadIfNeeded()
        let epoch = store.epoch
        store.connectionReset()
        XCTAssertEqual(store.epoch, epoch + 1)
        await model.loadIfNeeded()
        XCTAssertEqual(calls.count("_acpcode/git/status"), 2)
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

final class GitDiffTextTests: XCTestCase {
    func testASimpleModifiedFileGivesLinesOfEachKind() {
        let text = """
        diff --git a/a.txt b/a.txt
        index 111..222 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1,2 +1,2 @@
         same
        -old
        +new
        \\ No newline at end of file

        """
        let files = GitDiffText.split(text)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].path, "a.txt")
        XCTAssertEqual(files[0].lines.map(\.kind), [.meta, .meta, .meta, .meta, .hunk, .context, .removed, .added, .note])
        XCTAssertEqual(files[0].added, 1)
        XCTAssertEqual(files[0].removed, 1)
    }

    func testPlusPlusPlusInsideAHunkIsContentNotAHeader() {
        let text = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+++ b/evil\n"
        let files = GitDiffText.split(text)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].path, "x", "a content line cannot rename the file")
        XCTAssertEqual(files[0].added, 1)
    }

    func testSeveralFilesAndANewFileAndADeletedFile() {
        let text = """
        diff --git a/new.txt b/new.txt
        new file mode 100644
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1 @@
        +hello
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye

        """
        let files = GitDiffText.split(text)
        XCTAssertEqual(files.map(\.path), ["new.txt", "gone.txt"])
        XCTAssertEqual(files.map(\.id), [0, 1])
        XCTAssertEqual([files[0].added, files[1].removed], [1, 1])
    }

    func testRenameUsesTheNewName() {
        let text = "diff --git a/old name.txt b/new name.txt\nsimilarity index 90%\nrename from old name.txt\nrename to new name.txt\n"
        XCTAssertEqual(GitDiffText.split(text).map(\.path), ["new name.txt"])
    }

    func testQuotedPathsAreUnquoted() {
        let text = "diff --git \"a/with \\\"q\\\".txt\" \"b/with \\\"q\\\".txt\"\n--- \"a/with \\\"q\\\".txt\"\n+++ \"b/with \\\"q\\\".txt\"\n@@ -1 +1 @@\n-a\n+b\n"
        XCTAssertEqual(GitDiffText.split(text).map(\.path), ["with \"q\".txt"])
    }

    func testBinaryFilesAreANote() {
        let text = "diff --git a/i.png b/i.png\nindex 1..2 100644\nBinary files a/i.png and b/i.png differ\n"
        let file = GitDiffText.split(text)[0]
        XCTAssertEqual(file.lines.last?.kind, .note)
        XCTAssertEqual(file.added, 0)
    }

    func testSecretStubsAfterADiffBecomeHiddenFilesWithNoContent() {
        let text = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-a\n+b\nsecret file changed: .env (content hidden)\nsecret file changed: keys/id_rsa (content hidden)\n"
        let files = GitDiffText.split(text)
        XCTAssertEqual(files.map(\.path), ["a.txt", ".env", "keys/id_rsa"])
        XCTAssertEqual(files.map(\.hidden), [false, true, true])
        XCTAssertTrue(files[1].lines.isEmpty)
        XCTAssertEqual(files[0].added, 1, "the stub does not count as a line of the previous file")
    }

    func testAHiddenOnlyAnswerAndEmptyText() {
        XCTAssertEqual(GitDiffText.split("secret file changed: .env (content hidden)\n").map(\.path), [".env"])
        XCTAssertTrue(GitDiffText.split("").isEmpty)
    }

    func testAContentLineThatLooksLikeAStubIsNotHidden() {
        let text = "diff --git a/n.txt b/n.txt\n@@ -0,0 +1 @@\n+secret file changed: x (content hidden)\n"
        let files = GitDiffText.split(text)
        XCTAssertEqual(files.count, 1)
        XCTAssertFalse(files[0].hidden)
        XCTAssertEqual(files[0].added, 1)
    }

    func testTurnNumberIsTheCountOfUserMessagesUpToTheMessage() {
        let roles: [ChatMessage.Role] = [.user, .assistant, .system, .user, .assistant, .assistant]
        XCTAssertEqual(GitTurnIndex.turn(forMessageAt: 1, roles: roles), 1)
        XCTAssertEqual(GitTurnIndex.turn(forMessageAt: 4, roles: roles), 2)
        XCTAssertEqual(GitTurnIndex.turn(forMessageAt: 5, roles: roles), 2)
        XCTAssertNil(GitTurnIndex.turn(forMessageAt: 0, roles: [.assistant, .user]), "no user message before it")
        XCTAssertNil(GitTurnIndex.turn(forMessageAt: 9, roles: roles))
    }

    func testTurnNumberByMessageId() {
        let messages = [ChatMessage(role: .user, content: "a", isStreaming: false), ChatMessage(role: .assistant, content: "b", isStreaming: false),
                        ChatMessage(role: .user, content: "c", isStreaming: false), ChatMessage(role: .assistant, content: "d", isStreaming: false)]
        XCTAssertEqual(GitTurnIndex.turn(forMessageId: messages[3].id, in: messages), 2)
        XCTAssertNil(GitTurnIndex.turn(forMessageId: UUID(), in: messages))
    }

    func testChipAccessibilityLabel() {
        let status = GatewayGitStatus(branch: nil, ahead: 2, behind: 1, files: [GatewayGitFile(path: "a", status: .modified, staged: false)], hash: "h")
        XCTAssertEqual(GitChipText.accessibilityLabel(status: status), "Branch detached head, 2 ahead, 1 behind, 1 changed")
    }
}
