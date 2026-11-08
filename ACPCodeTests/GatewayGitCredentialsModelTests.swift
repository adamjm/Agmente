import XCTest
import ACP
@testable import ACPCode
import ACPClient

/// Records each gateway call and answers from `results`, or throws `error`. No network.
private final class GitCredentialFakeGateway: GatewayCalling, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(method: String, params: ACP.Value?)] = []
    var results: [String: ACP.Value] = [:]
    var error: Error?

    var calls: [(method: String, params: ACP.Value?)] { lock.lock(); defer { lock.unlock() }; return recorded }
    func methods() -> [String] { calls.map(\.method) }

    func gatewayCall(method: String, params: ACP.Value?) async throws -> ACP.Value {
        lock.lock(); recorded.append((method, params)); lock.unlock()
        if let error { throw error }
        return results[method] ?? .null
    }
}

private func credentialValue(_ id: String, _ name: String, _ host: String) -> ACP.Value {
    .object(["id": .string(id), "name": .string(name), "host": .string(host),
             "createdAt": .string("2026-11-08T10:00:00.000Z"), "hasSecret": .bool(true)])
}

private func credentialsList(_ rows: [ACP.Value]) -> ACP.Value {
    .object(["credentials": .array(rows)])
}

@MainActor
final class GatewayGitCredentialsModelTests: XCTestCase {

    func testLoadReadsMetadataAndMarksGitSupported() async {
        let gateway = GitCredentialFakeGateway()
        gateway.results["_acpcode/git/credentials/list"] = credentialsList([credentialValue("0123456789ab", "Work GitHub", "github.com")])
        let model = GatewayGitCredentialsModel(clientProvider: { GatewayClient(gateway) }, connectionScheme: "wss")
        await model.load()
        XCTAssertEqual(model.support, .supported)
        XCTAssertEqual(model.credentials.map(\.name), ["Work GitHub"])
        XCTAssertEqual(model.credentials.first?.hasSecret, true)
    }

    func testMethodNotFoundMeansAGatewayWithoutGit() async {
        let gateway = GitCredentialFakeGateway()
        gateway.error = GatewayError.rpc(code: -32601, message: "Method not found")
        let model = GatewayGitCredentialsModel(clientProvider: { GatewayClient(gateway) })
        await model.load()
        XCTAssertEqual(model.support, .unsupported)
        XCTAssertNil(model.loadMessage)
    }

    func testOtherFailureIsUnknownWithItsText() async {
        let gateway = GitCredentialFakeGateway()
        gateway.error = GatewayError.rpc(code: -32000, message: "cannot read the credentials")
        let model = GatewayGitCredentialsModel(clientProvider: { GatewayClient(gateway) })
        await model.load()
        XCTAssertEqual(model.support, .unknown)
        XCTAssertEqual(model.loadMessage, "cannot read the credentials")
    }

    /// The ws:// refusal (D-105). If this test fails after a change, a secret may be sent in clear text.
    func testSecretIsRefusedOverWSBeforeAnythingIsSent() async {
        let gateway = GitCredentialFakeGateway()
        let model = GatewayGitCredentialsModel(clientProvider: { GatewayClient(gateway) }, connectionScheme: "ws")
        let outcome = await model.save(id: nil, name: "Work", host: "github.com", token: "ghp_abc123")
        XCTAssertEqual(outcome, .refused("Credentials can be added only over a secure connection (wss://)."))
        XCTAssertFalse(model.canEnterSecrets)
        XCTAssertFalse(gateway.methods().contains("_acpcode/git/credentials/set"), "no set request over ws://")
    }

    func testSecretIsSentOnceOverWSSAndOnlyMetadataComesBack() async {
        let gateway = GitCredentialFakeGateway()
        gateway.results["_acpcode/git/credentials/set"] = .object(["id": .string("0123456789ab")])
        gateway.results["_acpcode/git/credentials/list"] = credentialsList([credentialValue("0123456789ab", "Work", "github.com")])
        let model = GatewayGitCredentialsModel(clientProvider: { GatewayClient(gateway) }, connectionScheme: "wss")
        let outcome = await model.save(id: nil, name: "  Work  ", host: "github.com", token: "ghp_abc123")
        XCTAssertEqual(outcome, .saved(id: "0123456789ab"))
        let sets = gateway.calls.filter { $0.method == "_acpcode/git/credentials/set" }
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets.first?.params?.objectValue?["name"]?.stringValue, "Work", "the name is trimmed")
        XCTAssertEqual(sets.first?.params?.objectValue?["token"]?.stringValue, "ghp_abc123")
        XCTAssertEqual(model.credentials.map(\.id), ["0123456789ab"], "the list is reloaded from metadata")
    }

    func testDuplicateNameIsRefusedWithoutSending() async {
        let gateway = GitCredentialFakeGateway()
        gateway.results["_acpcode/git/credentials/list"] = credentialsList([credentialValue("0123456789ab", "Work", "github.com")])
        let model = GatewayGitCredentialsModel(clientProvider: { GatewayClient(gateway) }, connectionScheme: "wss")
        await model.load()
        let outcome = await model.save(id: nil, name: "work", host: "github.com", token: "ghp_abc123")
        XCTAssertEqual(outcome, .refused("A credential named “work” already exists."))
        XCTAssertFalse(gateway.methods().contains("_acpcode/git/credentials/set"))
    }

    func testBadTokenIsRefusedWithoutSending() async {
        let gateway = GitCredentialFakeGateway()
        let model = GatewayGitCredentialsModel(clientProvider: { GatewayClient(gateway) }, connectionScheme: "wss")
        let outcome = await model.save(id: nil, name: "Work", host: "github.com", token: "has space")
        if case .refused = outcome {} else { XCTFail("expected a refusal, got \(outcome)") }
        XCTAssertFalse(gateway.methods().contains("_acpcode/git/credentials/set"))
    }

    func testDeleteSendsTheIdAndReloads() async {
        let gateway = GitCredentialFakeGateway()
        gateway.results["_acpcode/git/credentials/list"] = credentialsList([])
        let model = GatewayGitCredentialsModel(clientProvider: { GatewayClient(gateway) }, connectionScheme: "wss")
        let credential = GatewayGitCredential(id: "0123456789ab", name: "Work", host: "github.com", createdAt: "", hasSecret: true)
        let failure = await model.delete(credential)
        XCTAssertNil(failure)
        let deletes = gateway.calls.filter { $0.method == "_acpcode/git/credentials/delete" }
        XCTAssertEqual(deletes.first?.params?.objectValue?["id"]?.stringValue, "0123456789ab")
    }
}

@MainActor
final class GatewayNewProjectGitTests: XCTestCase {

    private func gateway(withCredentials rows: [ACP.Value] = []) -> GitCredentialFakeGateway {
        let gateway = GitCredentialFakeGateway()
        gateway.results["_acpcode/projects/roots"] = .object(["roots": .array([.string("/srv/root")])])
        gateway.results["_acpcode/git/credentials/list"] = credentialsList(rows)
        gateway.results["_acpcode/projects/create"] = .object([
            "project": .object(["id": .string("9f2c1a7b3e10"), "name": .string("api"), "path": .string("/srv/root/api"), "defaultMode": .null]),
            "git": .object(["initialized": .bool(true), "remote": .string("https://github.com/owner/repo.git"), "branch": .string(""), "unborn": .bool(true)]),
        ])
        return gateway
    }

    private func makeModel(_ gateway: GitCredentialFakeGateway, created: @escaping (GatewayProject) -> Void = { _ in }) -> GatewayNewProjectModel {
        GatewayNewProjectModel(clientProvider: { GatewayClient(gateway) }, connectionScheme: "wss", onCreated: { created($0) })
    }

    private func readyModel(_ gateway: GitCredentialFakeGateway) async -> GatewayNewProjectModel {
        let model = makeModel(gateway)
        await model.loadRoots()
        model.name = "api"
        await model.credentials.load()
        return model
    }

    func testToggleOffSendsTheSameRequestAsBefore() async {
        let gateway = gateway()
        let model = await readyModel(gateway)
        let accepted = await model.create()
        XCTAssertTrue(accepted)
        let params = gateway.calls.last { $0.method == "_acpcode/projects/create" }?.params?.objectValue ?? [:]
        XCTAssertEqual(Set(params.keys), ["name", "path", "createFolder"])
    }

    func testToggleOnSendsGitFieldsAndTheCredentialForTheRemoteHost() async {
        let gateway = gateway(withCredentials: [credentialValue("0123456789ab", "Work GitHub", "github.com")])
        let model = await readyModel(gateway)
        model.gitEnabled = true
        model.remoteURL = "https://GitHub.com/owner/repo.git"
        await model.credentials.load()
        XCTAssertEqual(model.credentialRows.map(\.id), ["0123456789ab"])
        model.selectedCredentialId = "0123456789ab"
        XCTAssertTrue(model.canCreate)
        let accepted = await model.create()
        XCTAssertTrue(accepted)
        let params = gateway.calls.last { $0.method == "_acpcode/projects/create" }?.params?.objectValue ?? [:]
        XCTAssertEqual(params["gitInit"]?.boolValue, true)
        XCTAssertEqual(params["gitRemote"]?.stringValue, "https://GitHub.com/owner/repo.git")
        XCTAssertEqual(params["credentialId"]?.stringValue, "0123456789ab")
    }

    func testChangingTheRemoteToAnotherHostDropsTheCredential() async {
        let gateway = gateway(withCredentials: [credentialValue("0123456789ab", "Work GitHub", "github.com")])
        let model = await readyModel(gateway)
        model.gitEnabled = true
        model.remoteURL = "https://github.com/owner/repo.git"
        await model.credentials.load()
        model.selectedCredentialId = "0123456789ab"
        model.remoteURL = "https://gitlab.com/owner/repo.git"
        XCTAssertNil(model.selectedCredentialId)
        XCTAssertNil(model.gitSetup?.credentialId)
    }

    func testAnInvalidRemoteKeepsCreateOff() async {
        let gateway = gateway()
        let model = await readyModel(gateway)
        model.gitEnabled = true
        model.remoteURL = "http://github.com/owner/repo.git"
        XCTAssertEqual(model.remoteProblem, "Use https:// for the remote.")
        XCTAssertFalse(model.canCreate)
        let accepted = await model.create()
        XCTAssertFalse(accepted)
        XCTAssertFalse(gateway.methods().contains("_acpcode/projects/create"))
    }

    func testAGatewayWithoutGitDisablesTheToggle() async {
        let fake = GitCredentialFakeGateway()
        fake.results["_acpcode/projects/roots"] = .object(["roots": .array([.string("/srv/root")])])
        let model = makeModel(fake)
        await model.loadRoots()
        model.name = "api"
        // Only the credentials call fails, with method-not-found: a gateway without D-105.
        fake.error = GatewayError.rpc(code: -32601, message: "Method not found")
        await model.credentials.load()
        XCTAssertTrue(model.gitUnsupported)
        model.gitEnabled = true
        XCTAssertFalse(model.canCreate, "Git cannot be on when the gateway has no git methods")
        model.gitEnabled = false
        XCTAssertTrue(model.canCreate, "a plain create still works")
    }
}
