import XCTest
import ACP
@testable import ACPCode
import ACPClient

/// Records each gateway call and answers from `results`, or fails with `error`.
private final class NewProjectFakeGateway: GatewayCalling, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(method: String, params: ACP.Value?)] = []
    var results: [String: ACP.Value] = [:]
    var error: Error?
    /// Runs before each call answers, so a test can act while a request is in flight.
    var onCall: ((String) async -> Void)?

    var calls: [(method: String, params: ACP.Value?)] { lock.lock(); defer { lock.unlock() }; return recorded }

    func gatewayCall(method: String, params: ACP.Value?) async throws -> ACP.Value {
        lock.lock(); recorded.append((method, params)); lock.unlock()
        if let onCall { await onCall(method) }
        if let error { throw error }
        return results[method] ?? .null
    }
}

/// Collects the projects the sheet reports as created.
@MainActor
private final class CreatedBox {
    var projects: [GatewayProject] = []
}

private func rootsValue(_ roots: [String]) -> ACP.Value {
    .object(["roots": .array(roots.map { .string($0) })])
}

private func projectValue(_ id: String, _ name: String, _ path: String) -> ACP.Value {
    .object(["id": .string(id), "name": .string(name), "path": .string(path), "defaultMode": .null])
}

@MainActor
final class GatewayNewProjectModelTests: XCTestCase {
    private func makeModel(_ gateway: NewProjectFakeGateway, created: CreatedBox? = nil) -> GatewayNewProjectModel {
        GatewayNewProjectModel(clientProvider: { GatewayClient(gateway) }, onCreated: { project in
            created?.projects.append(project)
        })
    }

    func testTypingSendsNothingAndTheNameIsCheckedAsItIsTyped() {
        let gateway = NewProjectFakeGateway()
        let model = makeModel(gateway)
        XCTAssertNil(model.nameProblem, "an empty field shows no complaint yet")
        model.name = "a/b"
        XCTAssertEqual(model.nameProblem, "Use only letters, digits, spaces, dots, hyphens and underscores.")
        model.name = ".hidden"
        XCTAssertEqual(model.nameProblem, "The name must not start with a dot.")
        model.name = "site"
        XCTAssertNil(model.nameProblem)
        XCTAssertTrue(gateway.calls.isEmpty, "no request is sent by typing")
    }

    func testCreateStaysOffUntilTheNameIsValidAndARootIsChosen() async {
        let gateway = NewProjectFakeGateway()
        gateway.results["_acpcode/projects/roots"] = rootsValue(["/srv/root"])
        let model = makeModel(gateway)
        XCTAssertFalse(model.canCreate, "no root has loaded yet")
        await model.loadRoots()
        XCTAssertFalse(model.canCreate, "no name yet")
        model.name = "bad name/x"
        XCTAssertFalse(model.canCreate, "an invalid name")
        model.name = "good"
        XCTAssertTrue(model.canCreate)
        XCTAssertEqual(model.folderPreview, "/srv/root/good")
    }

    func testOneRootIsChosenAndSeveralLetThePersonPick() async {
        let gateway = NewProjectFakeGateway()
        gateway.results["_acpcode/projects/roots"] = rootsValue(["/srv/a", "/srv/b"])
        let model = makeModel(gateway)
        await model.loadRoots()
        XCTAssertEqual(model.roots, ["/srv/a", "/srv/b"])
        XCTAssertEqual(model.selectedRoot, "/srv/a", "the first root is the default")
        model.name = "site"
        model.selectedRoot = "/srv/b"
        XCTAssertEqual(model.folderPreview, "/srv/b/site")
        XCTAssertNil(model.rootsMessage)
    }

    func testNoRootsSaysWhereToAddOneAndCreateStaysOff() async {
        let gateway = NewProjectFakeGateway()
        gateway.results["_acpcode/projects/roots"] = rootsValue([])
        let model = makeModel(gateway)
        await model.loadRoots()
        XCTAssertNil(model.selectedRoot)
        XCTAssertEqual(model.rootsMessage, "The gateway has no project roots. Add one under projects.roots in its config.")
        model.name = "site"
        XCTAssertFalse(model.canCreate)
        let accepted = await model.create()
        XCTAssertFalse(accepted)
        XCTAssertFalse(gateway.calls.contains { $0.method == "_acpcode/projects/create" })
    }

    func testAFailedRootsLoadShowsTheGatewaysText() async {
        let gateway = NewProjectFakeGateway()
        gateway.error = ACPServiceError.rpc(id: .number(1), error: .internalError("cannot read roots"))
        let model = makeModel(gateway)
        await model.loadRoots()
        XCTAssertEqual(model.rootsMessage, "cannot read roots")
        XCTAssertNil(model.selectedRoot)
    }

    func testAMissingConnectionIsSaidAndNothingIsSent() async {
        let model = GatewayNewProjectModel(clientProvider: { nil }, onCreated: { _ in })
        await model.loadRoots()
        XCTAssertEqual(model.rootsMessage, "Not connected to the gateway.")
        model.name = "site"
        let accepted = await model.create()
        XCTAssertFalse(accepted)
    }

    func testCreateSendsTheFolderRequestAndReportsTheProjectOnce() async {
        let gateway = NewProjectFakeGateway()
        gateway.results["_acpcode/projects/roots"] = rootsValue(["/srv/root"])
        gateway.results["_acpcode/projects/create"] = .object(["project": projectValue("9f2c1a7b3e10", "good", "/srv/root/good")])
        let created = CreatedBox()
        let model = makeModel(gateway, created: created)
        await model.loadRoots()
        model.name = "good"
        let accepted = await model.create()
        XCTAssertTrue(accepted)
        XCTAssertEqual(created.projects, [GatewayProject(id: "9f2c1a7b3e10", name: "good", path: "/srv/root/good")])
        XCTAssertEqual(gateway.calls.last?.method, "_acpcode/projects/create")
        XCTAssertEqual(gateway.calls.last?.params, .object([
            "name": .string("good"), "path": .string("/srv/root"), "createFolder": .bool(true),
        ]))
        XCTAssertFalse(model.isCreating)
        XCTAssertNil(model.createMessage)
    }

    func testARefusalKeepsTheNameAndShowsTheGatewaysTextAndCreatesNothing() async {
        let gateway = NewProjectFakeGateway()
        gateway.results["_acpcode/projects/roots"] = rootsValue(["/srv/root"])
        let created = CreatedBox()
        let model = makeModel(gateway, created: created)
        await model.loadRoots()
        model.name = "site"
        gateway.error = ACPServiceError.rpc(id: .number(2), error: .invalidParams("a folder with that name already exists"))
        let accepted = await model.create()
        XCTAssertFalse(accepted)
        XCTAssertEqual(model.createMessage, "a folder with that name already exists")
        XCTAssertEqual(model.name, "site", "the name is kept so the person can change it")
        XCTAssertTrue(created.projects.isEmpty)
        XCTAssertTrue(model.canCreate, "Create is back on after a refusal")
    }

    func testEditingTheNameClearsAGatewayRefusal() async {
        let gateway = NewProjectFakeGateway()
        gateway.results["_acpcode/projects/roots"] = rootsValue(["/srv/root"])
        let model = makeModel(gateway)
        await model.loadRoots()
        model.name = "site"
        gateway.error = ACPServiceError.rpc(id: .number(2), error: .invalidParams("a folder with that name already exists"))
        _ = await model.create()
        XCTAssertNotNil(model.createMessage)
        model.name = "site2"
        XCTAssertNil(model.createMessage, "the old text no longer describes the name")
    }

    func testAnInvalidNameIsNeverSent() async {
        let gateway = NewProjectFakeGateway()
        gateway.results["_acpcode/projects/roots"] = rootsValue(["/srv/root"])
        let model = makeModel(gateway)
        await model.loadRoots()
        model.name = "x/../escape"
        let accepted = await model.create()
        XCTAssertFalse(accepted)
        XCTAssertFalse(gateway.calls.contains { $0.method == "_acpcode/projects/create" })
    }

    func testChangingTheRootClearsAGatewayRefusal() async {
        let gateway = NewProjectFakeGateway()
        gateway.results["_acpcode/projects/roots"] = rootsValue(["/srv/a", "/srv/b"])
        let model = makeModel(gateway)
        await model.loadRoots()
        model.name = "site"
        gateway.error = ACPServiceError.rpc(id: .number(2), error: .invalidParams("a folder with that name already exists"))
        _ = await model.create()
        XCTAssertEqual(model.createMessage, "a folder with that name already exists")
        model.selectedRoot = "/srv/b"
        XCTAssertNil(model.createMessage, "the refusal was about the other root")
    }

    func testARefusalThatArrivesAfterTheNameChangedIsNotShown() async {
        let gateway = NewProjectFakeGateway()
        gateway.results["_acpcode/projects/roots"] = rootsValue(["/srv/root"])
        let model = makeModel(gateway)
        await model.loadRoots()
        model.name = "site"
        gateway.error = ACPServiceError.rpc(id: .number(2), error: .invalidParams("a folder with that name already exists"))
        gateway.onCall = { method in
            guard method == "_acpcode/projects/create" else { return }
            await MainActor.run { model.name = "site2" }
        }
        let accepted = await model.create()
        XCTAssertFalse(accepted)
        XCTAssertEqual(model.name, "site2")
        XCTAssertNil(model.createMessage, "the refusal was for the name that was sent, not the one now typed")
    }

    func testASecondCreateWhileOneIsInFlightSendsNothing() async {
        let gateway = NewProjectFakeGateway()
        gateway.results["_acpcode/projects/roots"] = rootsValue(["/srv/root"])
        gateway.results["_acpcode/projects/create"] = .object(["project": projectValue("9f2c1a7b3e10", "site", "/srv/root/site")])
        let model = makeModel(gateway)
        await model.loadRoots()
        model.name = "site"
        var secondAccepted: Bool?
        gateway.onCall = { method in
            guard method == "_acpcode/projects/create", secondAccepted == nil else { return }
            secondAccepted = await Task { @MainActor in await model.create() }.value
        }
        let accepted = await model.create()
        XCTAssertTrue(accepted)
        XCTAssertEqual(secondAccepted, false, "a second Create while one is in flight is refused")
        XCTAssertEqual(gateway.calls.filter { $0.method == "_acpcode/projects/create" }.count, 1)
    }

    func testADisconnectDuringCreateKeepsTheNameAndSaysSo() async {
        let gateway = NewProjectFakeGateway()
        gateway.results["_acpcode/projects/roots"] = rootsValue(["/srv/root"])
        let model = makeModel(gateway)
        await model.loadRoots()
        model.name = "site"
        gateway.error = ACPServiceError.disconnected
        let accepted = await model.create()
        XCTAssertFalse(accepted)
        XCTAssertEqual(model.createMessage, "Not connected")
        XCTAssertEqual(model.name, "site")
    }
}

@MainActor
final class GatewayNewProjectSelectionTests: XCTestCase {
    private func gatewayWithTwoProjects() -> NewProjectFakeGateway {
        let gateway = NewProjectFakeGateway()
        gateway.results["_acpcode/projects/list"] = .object(["projects": .array([
            projectValue("p1", "Site", "/srv/root/site"),
            projectValue("p2", "Fresh", "/srv/root/fresh"),
        ])])
        gateway.results["_acpcode/sessions/index"] = .object(["sessions": .array([])])
        return gateway
    }

    func testTheSelectedProjectSurvivesARefreshAndIsForgottenForAnotherServer() async {
        let gateway = gatewayWithTwoProjects()
        let home = GatewayHomeModel()
        home.configure { GatewayClient(gateway) }
        await home.refresh()
        home.select(projectId: "p2")
        await home.refresh()
        XCTAssertEqual(home.selectedProjectId, "p2")
        XCTAssertEqual(gatewayNewSessionChosenProject(home.projects, selection: home.selectedProjectId)?.id, "p2")
        home.configure { nil }
        XCTAssertNil(home.selectedProjectId)
    }

    func testTheNewSessionStartsOnTheSelectedProjectOrOnTheFirstOne() {
        let projects = [
            GatewayProject(id: "p1", name: "Site", path: "/srv/root/site"),
            GatewayProject(id: "p2", name: "Fresh", path: "/srv/root/fresh"),
        ]
        XCTAssertEqual(gatewayNewSessionChosenProject(projects, selection: "p2")?.id, "p2")
        XCTAssertEqual(gatewayNewSessionChosenProject(projects, selection: nil)?.id, "p1")
        XCTAssertEqual(gatewayNewSessionChosenProject(projects, selection: "gone")?.id, "p1", "a project no longer listed falls back to the first")
    }
}
