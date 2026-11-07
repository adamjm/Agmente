import Foundation
import ACPClient

/// The state of the New Project sheet (D-091). It loads the gateway's roots, checks the name as the
/// person types, and sends `_agmente/projects/create` with `createFolder` only when Create is tapped.
/// A refusal keeps the name and shows the gateway's own text. Nothing is sent by typing.
@MainActor
final class GatewayNewProjectModel: ObservableObject {
    @Published var name: String = "" {
        didSet {
            if name != oldValue { createMessage = nil }
        }
    }
    @Published var selectedRoot: String?
    @Published private(set) var roots: [String] = []
    @Published private(set) var isLoadingRoots = false
    @Published private(set) var rootsMessage: String?
    @Published private(set) var isCreating = false
    @Published private(set) var createMessage: String?

    private let clientProvider: () -> GatewayClient?
    private let onCreated: (GatewayProject) async -> Void

    /// `onCreated` runs once the gateway has made and registered the project. The caller refreshes its
    /// project list and selects the new project there.
    init(clientProvider: @escaping () -> GatewayClient?, onCreated: @escaping (GatewayProject) async -> Void) {
        self.clientProvider = clientProvider
        self.onCreated = onCreated
    }

    /// The text under the name field, or nil while the name is empty or valid. Empty shows nothing,
    /// so the field does not complain before anything is typed.
    var nameProblem: String? {
        name.isEmpty ? nil : GatewayFolderName.problem(with: name)
    }

    /// Create is on when the name is valid, a root is chosen, and nothing is already in flight.
    var canCreate: Bool {
        !name.isEmpty && GatewayFolderName.isValid(name) && selectedRoot != nil && !isCreating && !isLoadingRoots
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
    /// person can change it.
    @discardableResult
    func create() async -> Bool {
        guard canCreate, let root = selectedRoot else { return false }
        guard let client = clientProvider() else {
            createMessage = "Not connected to the gateway."
            return false
        }
        isCreating = true
        defer { isCreating = false }
        do {
            let project = try await client.createProject(name: name, path: root, createFolder: true)
            createMessage = nil
            await onCreated(project)
            return true
        } catch {
            createMessage = (error as? GatewayError)?.message ?? error.localizedDescription
            return false
        }
    }
}
