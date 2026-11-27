import XCTest
import ACP
@testable import ACPClient

private final class RunnerFakeGateway: GatewayCalling, @unchecked Sendable {
    var calls: [(method: String, params: ACP.Value?)] = []
    var results: [String: ACP.Value] = [:]
    var error: Error?

    func gatewayCall(method: String, params: ACP.Value?) async throws -> ACP.Value {
        calls.append((method, params))
        if let error { throw error }
        return results[method] ?? .null
    }
}

final class GatewayPerSessionRunnerTests: XCTestCase {
    private func decodeProject(_ json: String) throws -> GatewayProject {
        try JSONDecoder().decode(GatewayProject.self, from: Data(json.utf8))
    }

    func testProjectParentIdAndBranchDecodeAndEmptyOrMissingIsNil() throws {
        let child = try decodeProject(#"{"id":"c","name":"Site (Codex)","path":"/a-codex-1","runner":"codex","parentId":"p","branch":"acpcode/codex/1a2b3c4d"}"#)
        XCTAssertEqual(child.parentId, "p")
        XCTAssertEqual(child.branch, "acpcode/codex/1a2b3c4d")
        XCTAssertTrue(child.isWorktree)
        let empty = try decodeProject(#"{"id":"a","name":"A","path":"/a","parentId":"","branch":""}"#)
        XCTAssertNil(empty.parentId)
        XCTAssertNil(empty.branch)
        let missing = try decodeProject(#"{"id":"a","name":"A","path":"/a"}"#)
        XCTAssertNil(missing.parentId)
        XCTAssertNil(missing.branch)
        XCTAssertFalse(missing.isWorktree)
        XCTAssertEqual(GatewayProject(id: "a", name: "A", path: "/a"), missing, "the old init defaults still build an equal project")
        XCTAssertNotEqual(child, GatewayProject(id: "c", name: "Site (Codex)", path: "/a-codex-1", runner: "codex"))
    }

    func testSessionRunnerDecodesAndEmptyOrMissingIsNil() throws {
        let base = #""sessionId":"s","projectId":"p","title":null,"status":"idle","lastActivity":"2026-01-01T00:00:00.000Z","headSeq":1,"unread":0"#
        let with = try JSONDecoder().decode(GatewaySession.self, from: Data(("{" + base + #","runner":"codex"}"#).utf8))
        XCTAssertEqual(with.runner, "codex")
        let empty = try JSONDecoder().decode(GatewaySession.self, from: Data(("{" + base + #","runner":""}"#).utf8))
        XCTAssertNil(empty.runner)
        let missing = try JSONDecoder().decode(GatewaySession.self, from: Data(("{" + base + "}").utf8))
        XCTAssertNil(missing.runner)
        XCTAssertNil(missing.stalled)
    }

    func testCreateWorktreeSendsTheProjectAndTheRunnerOnlyWhenGiven() async throws {
        let fake = RunnerFakeGateway()
        fake.results["_acpcode/projects/createWorktree"] = .object(["project": .object([
            "id": .string("c1"), "name": .string("Site (Codex)"), "path": .string("/srv/site-codex-1a2b3c4d"),
            "runner": .string("codex"), "parentId": .string("p1"), "branch": .string("acpcode/codex/1a2b3c4d"),
        ])])
        let child = try await GatewayClient(fake).createWorktree(projectId: "p1", runner: "codex")
        XCTAssertEqual(fake.calls.last?.method, "_acpcode/projects/createWorktree")
        XCTAssertEqual(fake.calls.last?.params, .object(["projectId": .string("p1"), "runner": .string("codex")]))
        XCTAssertEqual(child.id, "c1")
        XCTAssertEqual(child.parentId, "p1")
        XCTAssertEqual(child.branch, "acpcode/codex/1a2b3c4d")

        _ = try await GatewayClient(fake).createWorktree(projectId: "p1")
        XCTAssertEqual(fake.calls.last?.params, .object(["projectId": .string("p1")]))
        _ = try await GatewayClient(fake).createWorktree(projectId: "p1", runner: "")
        XCTAssertEqual(fake.calls.last?.params, .object(["projectId": .string("p1")]), "an empty runner is not sent")
    }

    func testCreateWorktreeAlsoReadsAProjectObjectWithoutAWrapper() async throws {
        let fake = RunnerFakeGateway()
        fake.results["_acpcode/projects/createWorktree"] = .object([
            "id": .string("c1"), "name": .string("Site"), "path": .string("/srv/c"), "parentId": .string("p1"), "branch": .string("b"),
        ])
        let child = try await GatewayClient(fake).createWorktree(projectId: "p1")
        XCTAssertEqual(child.id, "c1")
    }

    func testCreateWorktreeRefusalCarriesTheGatewaysText() async {
        let fake = RunnerFakeGateway()
        fake.error = ACPServiceError.rpc(id: .number(1), error: .invalidParams("project is not a git repository with a commit"))
        do {
            _ = try await GatewayClient(fake).createWorktree(projectId: "p1", runner: "codex")
            XCTFail("expected a refusal")
        } catch let error as GatewayError {
            XCTAssertEqual(error.message, "project is not a git repository with a commit")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testSessionsCreateSendsTheRunnerOnlyWhenNonEmpty() async throws {
        let fake = RunnerFakeGateway()
        fake.results["_acpcode/sessions/create"] = .object(["sessionId": .string("s"), "turnId": .string("t"), "status": .string("accepted")])
        _ = try await GatewayClient(fake).createSession(cwd: "/srv/site", prompt: "x", runner: "codex")
        XCTAssertEqual(fake.calls.last?.params?["runner"], .string("codex"))
        _ = try await GatewayClient(fake).createSession(cwd: "/srv/site", prompt: "x")
        XCTAssertNil(fake.calls.last?.params?["runner"])
        _ = try await GatewayClient(fake).createSession(cwd: "/srv/site", prompt: "x", runner: "")
        XCTAssertNil(fake.calls.last?.params?["runner"])
    }

    func testSessionNewMetaCarriesTheRunnerOnlyForAGatewayAndANonEmptyRunner() {
        XCTAssertEqual(GatewayRunnerMeta.metaKey, "acpcode/runner")
        XCTAssertEqual(GatewayRunnerMeta.sessionNewMeta(isGateway: true, runner: "codex"), ["acpcode/runner": .string("codex")])
        XCTAssertTrue(GatewayRunnerMeta.sessionNewMeta(isGateway: true, runner: nil).isEmpty)
        XCTAssertTrue(GatewayRunnerMeta.sessionNewMeta(isGateway: true, runner: "").isEmpty)
        XCTAssertTrue(GatewayRunnerMeta.sessionNewMeta(isGateway: false, runner: "codex").isEmpty)
    }
}
