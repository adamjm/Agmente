import Foundation
import Combine
import ACPClient

/// The runner choice for a new project (multi-runner). A gateway that lists one runner, or none, offers no choice,
/// and no runner is sent, so the gateway uses its default.
enum GatewayRunnerRules {
    /// The runners the person may choose from: all of them when there are two or more, else none.
    static func choices(_ runners: [GatewayRunner]) -> [GatewayRunner] {
        runners.count >= 2 ? runners : []
    }

    /// The runner a new project starts with: the gateway's default when it is listed, else the first one.
    /// Nil when there is no choice to make.
    static func defaultSelection(_ runners: [GatewayRunner], defaultRunner: String?) -> String? {
        let offered = choices(runners)
        guard !offered.isEmpty else { return nil }
        if let defaultRunner, offered.contains(where: { $0.id == defaultRunner }) {
            return defaultRunner
        }
        return offered.first?.id
    }

    /// The name to show for a project's runner: nil unless the project has a runner, the gateway lists two or
    /// more, and the runner is one of them.
    static func projectRunnerName(_ project: GatewayProject, runners: [GatewayRunner]) -> String? {
        guard !choices(runners).isEmpty, let id = project.runner else { return nil }
        return runners.first(where: { $0.id == id })?.name
    }
}

/// The state of the New Project sheet (D-091, D-105). It loads the gateway's roots, checks the name as the
/// person types, and sends `_acpcode/projects/create` only when Create is tapped. With "Create Git
/// repository" on, the git fields go too; with it off, the request is the same as before.
/// A refusal keeps the name and shows the gateway's own text. Nothing is sent by typing.
@MainActor
final class GatewayNewProjectModel: ObservableObject {
    @Published var name: String = "" {
        didSet {
            if name != oldValue { createMessage = nil }
        }
    }
    @Published var selectedRoot: String? {
        didSet {
            if selectedRoot != oldValue { createMessage = nil }
        }
    }
    /// The runner the project will use. Nil when the gateway offers no choice, and then none is sent.
    @Published var selectedRunner: String? {
        didSet {
            if selectedRunner != oldValue { createMessage = nil }
        }
    }
    /// The runners the gateway lists, as it sent them. The picker shows them only when there are two or more.
    let runners: [GatewayRunner]
    /// "Create Git repository". Off by default, so today's request is unchanged.
    @Published var gitEnabled: Bool = false {
        didSet {
            if gitEnabled != oldValue { createMessage = nil }
        }
    }
    /// The optional remote, typed as is (no trimming: a space is a rule break, not a separator).
    @Published var remoteURL: String = "" {
        didSet {
            guard remoteURL != oldValue else { return }
            createMessage = nil
            // A credential is for one host. When the remote changes to another host, it is dropped.
            if let id = selectedCredentialId, !credentialRows.contains(where: { $0.id == id }) {
                selectedCredentialId = nil
            }
        }
    }
    @Published var selectedCredentialId: String?
    @Published private(set) var roots: [String] = []
    @Published private(set) var isLoadingRoots = false
    @Published private(set) var rootsMessage: String?
    @Published private(set) var isCreating = false
    @Published private(set) var createMessage: String?

    /// Git support and the stored profiles. Its changes reach the sheet through `objectWillChange` below.
    let credentials: GatewayGitCredentialsModel
    private var credentialChanges: AnyCancellable?

    private let clientProvider: () -> GatewayClient?
    private let onCreated: (GatewayProject) async -> Void

    /// `onCreated` runs once the gateway has made and registered the project. The caller refreshes its
    /// project list and selects the new project there. `connectionScheme` is the scheme of the server's
    /// connection, which decides whether a credential may be entered.
    init(clientProvider: @escaping () -> GatewayClient?, connectionScheme: String = "wss", runners: [GatewayRunner] = [], defaultRunner: String? = nil, onCreated: @escaping (GatewayProject) async -> Void) {
        self.clientProvider = clientProvider
        self.onCreated = onCreated
        self.runners = runners
        self.selectedRunner = GatewayRunnerRules.defaultSelection(runners, defaultRunner: defaultRunner)
        self.credentials = GatewayGitCredentialsModel(clientProvider: clientProvider, connectionScheme: connectionScheme)
        credentialChanges = credentials.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// The runners the picker offers: none unless the gateway lists two or more.
    var runnerChoices: [GatewayRunner] { GatewayRunnerRules.choices(runners) }

    /// The text under the name field, or nil while the name is empty or valid. Empty shows nothing,
    /// so the field does not complain before anything is typed.
    var nameProblem: String? {
        name.isEmpty ? nil : GatewayFolderName.problem(with: name)
    }

    /// True when the gateway has no git methods. The toggle is then disabled (D-105).
    var gitUnsupported: Bool { credentials.support == .unsupported }

    /// The remote's problem text while Git is on, or nil when the remote is empty or valid.
    var remoteProblem: String? {
        gitEnabled ? GatewayGitRemoteRules.problem(with: remoteURL) : nil
    }

    /// The host of the remote when it is valid, else nil. The credential rows and the gateway's host check use it.
    var remoteHost: String? {
        gitEnabled ? GatewayGitRemoteRules.host(of: remoteURL) : nil
    }

    /// The credential rows for the remote's host.
    var credentialRows: [GatewayGitCredential] {
        GatewayGitCredentialRows.matching(credentials.credentials, remoteHost: remoteHost)
    }

    /// The name shown on the credential row: the chosen profile's name, or "None".
    var selectedCredentialName: String {
        guard let id = selectedCredentialId, let row = credentialRows.first(where: { $0.id == id }) else { return "None" }
        return row.name
    }

    /// The git part of the request, or nil when the toggle is off. A credential is sent only with a remote
    /// and only when it is one of the rows for that remote.
    var gitSetup: GatewayGitSetup? {
        guard gitEnabled else { return nil }
        let remote = remoteURL.isEmpty ? nil : remoteURL
        var credentialId: String?
        if remote != nil, let id = selectedCredentialId, credentialRows.contains(where: { $0.id == id }) {
            credentialId = id
        }
        return GatewayGitSetup(remote: remote, credentialId: credentialId)
    }

    /// Create is on when the name is valid, a root is chosen, nothing is in flight, and the Git section, if on,
    /// has a valid remote (or none) on a gateway that supports Git.
    var canCreate: Bool {
        !name.isEmpty && GatewayFolderName.isValid(name) && selectedRoot != nil && !isCreating && !isLoadingRoots
            && (!gitEnabled || (!gitUnsupported && remoteProblem == nil))
    }

    /// The folder the project will be made in, shown before Create, or nil without a root.
    var folderPreview: String? {
        guard let root = selectedRoot, !name.isEmpty else { return selectedRoot }
        return root.hasSuffix("/") ? root + name : root + "/" + name
    }

    /// Loads the roots a folder may be made in. The first one is chosen when none is.
    func loadRoots() async {
        guard let client = clientProvider() else {
            rootsMessage = "Not connected to the gateway."
            return
        }
        isLoadingRoots = true
        defer { isLoadingRoots = false }
        do {
            let list = try await client.projectRoots()
            roots = list
            rootsMessage = list.isEmpty ? "The gateway has no project roots. Add one under projects.roots in its config." : nil
            if let current = selectedRoot, list.contains(current) {
                return
            }
            selectedRoot = list.first
        } catch {
            roots = []
            selectedRoot = nil
            rootsMessage = (error as? GatewayError)?.message ?? error.localizedDescription
        }
    }

    /// Sends the request. Returns true when the project was made; the name is kept on a refusal so the
    /// person can change it. The git setup is captured with the name, so a change during the call cannot
    /// alter what was asked for.
    @discardableResult
    func create() async -> Bool {
        guard canCreate, let root = selectedRoot else { return false }
        guard let client = clientProvider() else {
            createMessage = "Not connected to the gateway."
            return false
        }
        let sentName = name
        let git = gitSetup
        // Sent only when the gateway offers a choice; otherwise the gateway's default applies.
        let runner = runnerChoices.isEmpty ? nil : selectedRunner
        isCreating = true
        defer { isCreating = false }
        do {
            let created = try await client.createProject(name: sentName, path: root, git: git, runner: runner)
            createMessage = nil
            await onCreated(created.project)
            return true
        } catch {
            // The refusal is about the name and root that were sent. If either changed while the
            // request was in flight, the text would describe something else, so it is not shown.
            if name == sentName && selectedRoot == root {
                createMessage = (error as? GatewayError)?.message ?? error.localizedDescription
            }
            return false
        }
    }
}
