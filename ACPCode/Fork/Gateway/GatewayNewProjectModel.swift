import Foundation
import Combine
import ACPClient

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
    init(clientProvider: @escaping () -> GatewayClient?, connectionScheme: String = "wss", onCreated: @escaping (GatewayProject) async -> Void) {
        self.clientProvider = clientProvider
        self.onCreated = onCreated
        self.credentials = GatewayGitCredentialsModel(clientProvider: clientProvider, connectionScheme: connectionScheme)
        credentialChanges = credentials.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

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
        isCreating = true
        defer { isCreating = false }
        do {
            let created = try await client.createProject(name: sentName, path: root, git: git)
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
