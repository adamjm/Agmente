import XCTest
@testable import ACPCode

/// A blank working directory is stored as blank, not as "/" (bug A).
/// Only a working directory the user typed as "/" triggers the root warning.
/// A display-name-only edit skips the agent-limitations acknowledgement; any other change still shows it (bug B).
@MainActor
final class ServerEditWorkingDirectoryTests: XCTestCase {

    private func makeModel() -> AppViewModel {
        let suiteName = "ServerEditWorkingDirectoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppViewModel(
            storage: .inMemory(),
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )
    }

    private func addServer(_ model: AppViewModel, name: String, host: String, workingDirectory: String) {
        model.addServer(
            name: name,
            scheme: "ws",
            host: host,
            token: "",
            cfAccessClientId: "",
            cfAccessClientSecret: "",
            workingDirectory: workingDirectory
        )
    }

    private func storedServer(_ model: AppViewModel, named name: String) -> ACPServerConfiguration? {
        model.servers.first { $0.name == name }
    }

    /// The form's validated result for `original`, with the given fields changed.
    private func edit(
        _ original: ACPServerConfiguration,
        name: String? = nil,
        scheme: String? = nil,
        host: String? = nil,
        token: String? = nil,
        cfAccessClientId: String? = nil,
        cfAccessClientSecret: String? = nil,
        workingDirectory: String? = nil,
        serverType: ServerType? = nil,
        localOnly: Bool? = nil,
        spkiPins: String? = nil,
        clientIdentityChanged: Bool = false
    ) -> ValidatedServerConfiguration {
        ValidatedServerConfiguration(
            name: name ?? original.name,
            scheme: scheme ?? original.scheme,
            host: host ?? original.host,
            token: token ?? original.token,
            cfAccessClientId: cfAccessClientId ?? original.cfAccessClientId,
            cfAccessClientSecret: cfAccessClientSecret ?? original.cfAccessClientSecret,
            workingDirectory: workingDirectory ?? original.workingDirectory,
            serverType: serverType ?? original.serverType,
            agentInfo: nil,
            localOnly: localOnly ?? original.localOnly,
            spkiPins: spkiPins ?? original.spkiPins,
            clientIdentity: nil,
            clientIdentityChanged: clientIdentityChanged
        )
    }

    private var original: ACPServerConfiguration {
        ACPServerConfiguration(
            id: UUID(),
            name: "Office",
            scheme: "ws",
            host: "localhost:18480",
            token: "tok",
            cfAccessClientId: "cf-id",
            cfAccessClientSecret: "cf-secret",
            workingDirectory: "/Users/me/project",
            serverType: .acp,
            localOnly: true
        )
    }

    // MARK: - Bug A: blank working directory

    func testBlankWorkingDirectoryIsStoredAsBlankOnAdd() {
        let model = makeModel()
        addServer(model, name: "Blank", host: "localhost:18481", workingDirectory: "")
        XCTAssertEqual(storedServer(model, named: "Blank")?.workingDirectory, "")
    }

    func testWhitespaceOnlyWorkingDirectoryIsStoredAsBlankOnAdd() {
        let model = makeModel()
        addServer(model, name: "Spaces", host: "localhost:18482", workingDirectory: "   ")
        XCTAssertEqual(storedServer(model, named: "Spaces")?.workingDirectory, "")
    }

    func testBlankWorkingDirectoryIsStoredAsBlankOnUpdate() throws {
        let model = makeModel()
        addServer(model, name: "Office", host: "localhost:18483", workingDirectory: "/tmp/work")
        let id = try XCTUnwrap(storedServer(model, named: "Office")?.id)
        let current = try XCTUnwrap(storedServer(model, named: "Office"))
        model.updateServer(id, with: edit(current, workingDirectory: ""))
        XCTAssertEqual(storedServer(model, named: "Office")?.workingDirectory, "")
    }

    /// Editing the selected server must update the values the app copies back into the stored server
    /// when it switches servers; otherwise the old working directory is written back.
    func testBlankWorkingDirectorySurvivesSwitchingServersAfterEditingTheSelectedServer() throws {
        let model = makeModel()
        addServer(model, name: "A", host: "localhost:18485", workingDirectory: "/tmp/work")
        addServer(model, name: "B", host: "localhost:18486", workingDirectory: "/tmp/other")
        let a = try XCTUnwrap(storedServer(model, named: "A"))
        let b = try XCTUnwrap(storedServer(model, named: "B"))
        model.selectServer(a.id)
        model.updateServer(a.id, with: edit(a, workingDirectory: ""))
        model.selectServer(b.id)
        XCTAssertEqual(storedServer(model, named: "A")?.workingDirectory, "")
    }

    func testEndpointEditOfTheSelectedServerSurvivesSwitchingServers() throws {
        let model = makeModel()
        addServer(model, name: "A", host: "localhost:18487", workingDirectory: "/tmp/work")
        addServer(model, name: "B", host: "localhost:18488", workingDirectory: "/tmp/other")
        let a = try XCTUnwrap(storedServer(model, named: "A"))
        let b = try XCTUnwrap(storedServer(model, named: "B"))
        model.selectServer(a.id)
        model.updateServer(a.id, with: edit(a, host: "localhost:18489"))
        model.selectServer(b.id)
        XCTAssertEqual(storedServer(model, named: "A")?.host, "localhost:18489")
    }

    func testTypedRootIsStoredAsRoot() {
        let model = makeModel()
        addServer(model, name: "Root", host: "localhost:18484", workingDirectory: "/")
        XCTAssertEqual(storedServer(model, named: "Root")?.workingDirectory, "/")
    }

    // MARK: - Root warning

    func testTypedRootTriggersRootWarning() {
        XCTAssertTrue(AddServerView.isRootWorkingDirectory("/"))
        XCTAssertTrue(AddServerView.isRootWorkingDirectory("  /  "))
    }

    func testBlankAndOrdinaryDirectoriesDoNotTriggerRootWarning() {
        XCTAssertFalse(AddServerView.isRootWorkingDirectory(""))
        XCTAssertFalse(AddServerView.isRootWorkingDirectory("   "))
        XCTAssertFalse(AddServerView.isRootWorkingDirectory("/tmp"))
        XCTAssertFalse(AddServerView.isRootWorkingDirectory("/Users/me/project"))
    }

    // MARK: - Bug B: acknowledgement

    func testRenameDoesNotNeedAcknowledgement() {
        let base = original
        let renamed = edit(base, name: "Renamed office")
        XCTAssertTrue(AddServerView.changesOnlyName(renamed, from: base))
    }

    func testRenameWithSurroundingWhitespaceInWorkingDirectoryStillOnlyRenames() {
        let base = original
        let renamed = edit(base, name: "Renamed office", workingDirectory: "  /Users/me/project  ")
        XCTAssertTrue(AddServerView.changesOnlyName(renamed, from: base))
    }

    func testUnchangedEditSkipsAcknowledgement() {
        let base = original
        XCTAssertTrue(AddServerView.changesOnlyName(edit(base), from: base))
    }

    func testEndpointAndSecurityChangesStillNeedAcknowledgement() {
        let base = original
        let changes: [(String, ValidatedServerConfiguration)] = [
            ("scheme", edit(base, scheme: "wss")),
            ("host", edit(base, host: "localhost:18499")),
            ("token", edit(base, token: "other-token")),
            ("cf client id", edit(base, cfAccessClientId: "other")),
            ("cf client secret", edit(base, cfAccessClientSecret: "other")),
            ("agent kind", edit(base, serverType: .codexAppServer)),
            ("local only", edit(base, localOnly: false)),
            ("spki pins", edit(base, spkiPins: "pin-a")),
            ("client identity", edit(base, clientIdentityChanged: true)),
            ("working directory", edit(base, workingDirectory: "/tmp/other")),
            ("working directory to root", edit(base, workingDirectory: "/")),
            ("name and host", edit(base, name: "Renamed", host: "localhost:18499")),
        ]
        for (label, change) in changes {
            XCTAssertFalse(AddServerView.changesOnlyName(change, from: base), "\(label) change skipped the acknowledgement")
        }
    }
}
