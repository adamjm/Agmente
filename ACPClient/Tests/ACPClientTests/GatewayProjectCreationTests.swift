import XCTest
import ACP
@testable import ACPClient

private final class CreationFakeGateway: GatewayCalling, @unchecked Sendable {
    var calls: [(method: String, params: ACP.Value?)] = []
    var results: [String: ACP.Value] = [:]
    var error: Error?

    func gatewayCall(method: String, params: ACP.Value?) async throws -> ACP.Value {
        calls.append((method, params))
        if let error { throw error }
        return results[method] ?? .null
    }
}

final class GatewayProjectCreationClientTests: XCTestCase {
    func testCreateFolderSendsTheParentPathAndTheNameAndDecodesTheProject() async throws {
        let fake = CreationFakeGateway()
        fake.results["_acpcode/projects/create"] = .object(["project": .object([
            "id": .string("9f2c1a7b3e10"), "name": .string("Fresh"), "path": .string("/srv/root/Fresh"), "defaultMode": .null,
        ])])
        let project = try await GatewayClient(fake).createProject(name: "Fresh", path: "/srv/root", createFolder: true)
        XCTAssertEqual(project, GatewayProject(id: "9f2c1a7b3e10", name: "Fresh", path: "/srv/root/Fresh", defaultMode: nil))
        XCTAssertEqual(fake.calls.map(\.method), ["_acpcode/projects/create"])
        XCTAssertEqual(fake.calls.first?.params, .object([
            "name": .string("Fresh"), "path": .string("/srv/root"), "createFolder": .bool(true),
        ]))
    }

    func testPathModeLeavesCreateFolderOut() async throws {
        let fake = CreationFakeGateway()
        fake.results["_acpcode/projects/create"] = .object(["project": .object([
            "id": .string("a1"), "name": .string("Site"), "path": .string("/srv/site"),
        ])])
        let project = try await GatewayClient(fake).createProject(name: "Site", path: "/srv/site")
        XCTAssertEqual(project.defaultMode, nil)
        XCTAssertEqual(fake.calls.first?.params, .object(["name": .string("Site"), "path": .string("/srv/site")]),
                       "the path-based call sends the same params it always did")
    }

    func testTheRunnerIsSentOnlyWhenGiven() async throws {
        let fake = CreationFakeGateway()
        fake.results["_acpcode/projects/create"] = .object(["project": .object([
            "id": .string("a1"), "name": .string("Fresh"), "path": .string("/srv/root/Fresh"),
        ])])
        _ = try await GatewayClient(fake).createProject(name: "Fresh", path: "/srv/root", createFolder: true, runner: "codex")
        XCTAssertEqual(fake.calls.last?.params, .object([
            "name": .string("Fresh"), "path": .string("/srv/root"), "createFolder": .bool(true), "runner": .string("codex"),
        ]))
    }

    func testANilOrEmptyRunnerLeavesTheParamsUnchanged() async throws {
        let fake = CreationFakeGateway()
        fake.results["_acpcode/projects/create"] = .object(["project": .object([
            "id": .string("a1"), "name": .string("Fresh"), "path": .string("/srv/root/Fresh"),
        ])])
        let expected: ACP.Value = .object(["name": .string("Fresh"), "path": .string("/srv/root"), "createFolder": .bool(true)])
        _ = try await GatewayClient(fake).createProject(name: "Fresh", path: "/srv/root", createFolder: true, runner: nil)
        _ = try await GatewayClient(fake).createProject(name: "Fresh", path: "/srv/root", createFolder: true, runner: "")
        _ = try await GatewayClient(fake).createProject(name: "Fresh", path: "/srv/root", createFolder: true)
        XCTAssertEqual(fake.calls.map(\.params), [expected, expected, expected])
    }

    func testTheGitCreateSendsTheRunnerToo() async throws {
        let fake = CreationFakeGateway()
        fake.results["_acpcode/projects/create"] = .object(["project": .object([
            "id": .string("a1"), "name": .string("Fresh"), "path": .string("/srv/root/Fresh"),
        ])])
        _ = try await GatewayClient(fake).createProject(name: "Fresh", path: "/srv/root", git: nil, runner: "bob")
        XCTAssertEqual(fake.calls.last?.params, .object([
            "name": .string("Fresh"), "path": .string("/srv/root"), "createFolder": .bool(true), "runner": .string("bob"),
        ]))
        _ = try await GatewayClient(fake).createProject(name: "Fresh", path: "/srv/root", git: nil)
        XCTAssertEqual(fake.calls.last?.params, .object([
            "name": .string("Fresh"), "path": .string("/srv/root"), "createFolder": .bool(true),
        ]), "without a runner the git create is unchanged")
    }

    func testGatewayProjectDecodesTheRunnerAndTreatsEmptyAsNone() async throws {
        let fake = CreationFakeGateway()
        fake.results["_acpcode/projects/list"] = .object(["projects": .array([
            .object(["id": .string("a1"), "name": .string("Old"), "path": .string("/srv/old"), "defaultMode": .null]),
            .object(["id": .string("b2"), "name": .string("Empty"), "path": .string("/srv/empty"), "defaultMode": .null, "runner": .string("")]),
            .object(["id": .string("c3"), "name": .string("Bob"), "path": .string("/srv/bob"), "defaultMode": .null, "runner": .string("bob")]),
        ])])
        let projects = try await GatewayClient(fake).projects()
        XCTAssertEqual(projects.map(\.runner), [nil, nil, "bob"])
        XCTAssertEqual(projects[2], GatewayProject(id: "c3", name: "Bob", path: "/srv/bob", defaultMode: nil, runner: "bob"))
    }

    func testAGatewayRefusalKeepsItsCodeAndText() async {
        let fake = CreationFakeGateway()
        fake.error = ACPServiceError.rpc(id: .number(3), error: .invalidParams("a folder with that name already exists"))
        do {
            _ = try await GatewayClient(fake).createProject(name: "site", path: "/srv/root", createFolder: true)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? GatewayError, .rpc(code: -32602, message: "a folder with that name already exists"))
            XCTAssertEqual((error as? GatewayError)?.message, "a folder with that name already exists")
        }
    }

    func testADisconnectDuringCreateIsReported() async {
        let fake = CreationFakeGateway()
        fake.error = ACPServiceError.disconnected
        do {
            _ = try await GatewayClient(fake).createProject(name: "x", path: "/srv/root", createFolder: true)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? GatewayError, .disconnected)
        }
    }

    func testAnAnswerWithoutAProjectIsNamed() async {
        let fake = CreationFakeGateway()
        fake.results["_acpcode/projects/create"] = .object(["id": .string("a1")])
        do {
            _ = try await GatewayClient(fake).createProject(name: "x", path: "/srv/root", createFolder: true)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? GatewayError, .invalidResponse("project"))
        }
    }

    func testRootsDecodeAndSendNoParams() async throws {
        let fake = CreationFakeGateway()
        fake.results["_acpcode/projects/roots"] = .object(["roots": .array([.string("/srv/root"), .string("/srv/other")])])
        let roots = try await GatewayClient(fake).projectRoots()
        XCTAssertEqual(roots, ["/srv/root", "/srv/other"])
        XCTAssertEqual(fake.calls.first?.method, "_acpcode/projects/roots")
        XCTAssertEqual(fake.calls.first?.params, .object([:]))
    }

    func testRootsWithTheWrongShapeIsNamed() async {
        let fake = CreationFakeGateway()
        fake.results["_acpcode/projects/roots"] = .object(["roots": .string("/srv/root")])
        do {
            _ = try await GatewayClient(fake).projectRoots()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? GatewayError, .invalidResponse("roots"))
        }
    }
}

final class GatewayFolderNameTests: XCTestCase {
    func testAValidNameHasNoProblem() {
        for name in ["site", "My-app_v1.2 beta", "A", "0", String(repeating: "x", count: 64)] {
            XCTAssertNil(GatewayFolderName.problem(with: name), name)
            XCTAssertTrue(GatewayFolderName.isValid(name), name)
        }
    }

    func testEachRuleGivesItsOwnText() {
        XCTAssertEqual(GatewayFolderName.problem(with: ""), "Enter a folder name.")
        XCTAssertEqual(GatewayFolderName.problem(with: String(repeating: "x", count: 65)), "Use at most 64 characters.")
        XCTAssertEqual(GatewayFolderName.problem(with: ".hidden"), "The name must not start with a dot.")
        XCTAssertEqual(GatewayFolderName.problem(with: "..") , "The name must not start with a dot.")
        XCTAssertEqual(GatewayFolderName.problem(with: " lead"), "The name must not start or end with a space.")
        XCTAssertEqual(GatewayFolderName.problem(with: "trail "), "The name must not start or end with a space.")
        for name in ["a/b", "a\\b", "a*b", "a:b", "café", "a\nb", "a\u{0}b", "tab\tname"] {
            XCTAssertEqual(GatewayFolderName.problem(with: name), "Use only letters, digits, spaces, dots, hyphens and underscores.", name)
        }
    }

    func testTheLengthIsCountedInBytesLikeTheGateway() {
        // "é" is two bytes in UTF-8. The gateway counts bytes, so 33 of them are 66 bytes.
        XCTAssertEqual(GatewayFolderName.problem(with: String(repeating: "é", count: 33)), "Use at most 64 characters.")
    }

    func testTheRulesDoNotTrimWhatIsTyped() {
        XCTAssertFalse(GatewayFolderName.isValid(" site"))
        XCTAssertFalse(GatewayFolderName.isValid("site "))
        XCTAssertTrue(GatewayFolderName.isValid("my site"))
    }
}
