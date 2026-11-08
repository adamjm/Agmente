import Foundation
import ACP
import ACPClient

/// Read-only git state of one gateway project (FR-27, FR-31). It only reads: nothing here changes a
/// repository, and nothing runs on its own except a status refresh when the gateway says the status
/// changed. Paths for a diff come from the last status (FR-29).
@MainActor
final class GitProjectModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case notRepository
        case failed(String)
    }

    enum DiffState: Equatable {
        case loading
        case loaded(GatewayGitDiff)
        case failed(String)
    }

    enum LogState: Equatable {
        case idle
        case loading
        case loaded
        case notRepository
        case failed(String)
    }

    let projectId: String
    @Published private(set) var state: LoadState = .idle
    /// The last status that loaded. Kept when a later refresh fails, so the chip does not vanish.
    @Published private(set) var status: GatewayGitStatus?

    @Published private(set) var diffPath: String?
    @Published private(set) var diffStaged = false
    @Published private(set) var diff: DiffState?

    @Published private(set) var commits: [GatewayGitCommit] = []
    @Published private(set) var nextCursor: String?
    @Published private(set) var logState: LogState = .idle

    private let clientProvider: () -> GatewayClient?
    private var refreshing = false
    private var refreshAgain = false
    private var diffGeneration = 0
    private var loadingMore = false

    init(projectId: String, clientProvider: @escaping () -> GatewayClient?) {
        self.projectId = projectId
        self.clientProvider = clientProvider
    }

    var isDirty: Bool { !(status?.files.isEmpty ?? true) }

    /// The gateway client of the connection this project belongs to, for the push sheet (D-105).
    func gitClient() -> GatewayClient? { clientProvider() }

    /// Loads the status once; later calls do nothing until `invalidate()`.
    func loadIfNeeded() async {
        guard state == .idle else { return }
        await refresh()
    }

    /// The connection was replaced: the gateway no longer sends `git/changed` to us, so load again.
    func invalidate() {
        if state != .loading { state = .idle }
    }

    /// `_acpcode/git/changed`: refresh only when the hash is not the one we hold.
    func changed(hash: String) async {
        guard hash != status?.hash else { return }
        await refresh()
    }

    /// Reloads the status. A call during a load is folded into one more load after it.
    func refresh() async {
        guard clientProvider() != nil else { return }
        if refreshing {
            refreshAgain = true
            return
        }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            guard let client = clientProvider() else { return }
            if status == nil { state = .loading }
            do {
                status = try await client.gitStatus(projectId: projectId)
                state = .loaded
            } catch let error as GatewayError where error.isNotARepository {
                status = nil
                state = .notRepository
            } catch {
                state = .failed((error as? GatewayError)?.message ?? error.localizedDescription)
            }
        } while refreshAgain
    }

    /// Shows the diff of one file. The path must be in the current status; anything else is ignored
    /// (the gateway refuses it too, FR-29).
    func openDiff(path: String, staged: Bool) async {
        guard status?.files.contains(where: { $0.path == path }) == true else { return }
        guard let client = clientProvider() else { return }
        diffGeneration += 1
        let mine = diffGeneration
        diffPath = path
        diffStaged = staged
        diff = .loading
        do {
            let result = try await client.gitDiff(projectId: projectId, path: path, staged: staged)
            guard mine == diffGeneration else { return }
            diff = .loaded(result)
        } catch {
            guard mine == diffGeneration else { return }
            diff = .failed((error as? GatewayError)?.message ?? error.localizedDescription)
        }
    }

    func closeDiff() {
        diffGeneration += 1
        diffPath = nil
        diff = nil
    }

    /// Loads the first page of the log, replacing what is shown.
    func loadLog() async {
        guard let client = clientProvider() else { return }
        logState = .loading
        do {
            let page = try await client.gitLog(projectId: projectId, limit: 50)
            commits = page.commits
            nextCursor = page.nextCursor
            logState = .loaded
        } catch let error as GatewayError where error.isNotARepository {
            logState = .notRepository
        } catch {
            logState = .failed((error as? GatewayError)?.message ?? error.localizedDescription)
        }
    }

    /// Loads the next page. A commit already shown (the history moved between pages) is not added twice.
    func loadMoreLog() async {
        guard let cursor = nextCursor, !loadingMore, let client = clientProvider() else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await client.gitLog(projectId: projectId, limit: 50, cursor: cursor)
            let known = Set(commits.map(\.hash))
            commits += page.commits.filter { !known.contains($0.hash) }
            nextCursor = page.nextCursor
        } catch {
            logState = .failed((error as? GatewayError)?.message ?? error.localizedDescription)
        }
    }
}

/// What one turn changed (`git/turnDiff`).
@MainActor
final class GitTurnDiffModel: ObservableObject {
    enum LoadState: Equatable {
        case loading
        case loaded(GatewayGitDiff)
        /// The gateway holds no snapshot of this turn (it ran before snapshots, or taking one failed).
        case noSnapshot
        case running
        case failed(String)
    }

    let sessionId: String
    let turn: Int
    @Published private(set) var state: LoadState = .loading

    private let clientProvider: () -> GatewayClient?

    init(sessionId: String, turn: Int, clientProvider: @escaping () -> GatewayClient?) {
        self.sessionId = sessionId
        self.turn = turn
        self.clientProvider = clientProvider
    }

    var files: [GitDiffFile] {
        if case .loaded(let diff) = state { return GitDiffText.split(diff.diff) }
        return []
    }

    func load() async {
        guard let client = clientProvider() else {
            state = .failed("Not connected")
            return
        }
        state = .loading
        do {
            state = .loaded(try await client.gitTurnDiff(sessionId: sessionId, turn: turn))
        } catch let error as GatewayError where error.isNoSnapshot {
            state = .noSnapshot
        } catch let error as GatewayError where error.isTurnRunning {
            state = .running
        } catch {
            state = .failed((error as? GatewayError)?.message ?? error.localizedDescription)
        }
    }
}

struct GitTabRequest: Identifiable, Equatable {
    let projectId: String
    var id: String { projectId }
}

struct GitTurnRequest: Identifiable, Equatable {
    let sessionId: String
    let turn: Int
    var id: String { "\(sessionId)#\(turn)" }
}

/// The git models of the selected gateway server, and the two sheets they open. One per app.
@MainActor
final class GitStore: ObservableObject {
    /// Raised when a connection is replaced; chips load again when it changes.
    @Published private(set) var epoch = 0
    @Published var homeTab: GitTabRequest?
    @Published var sessionTab: GitTabRequest?
    @Published var turnRequest: GitTurnRequest?

    private let serverId: () -> UUID?
    private let client: () -> GatewayClient?
    private let gitOffered: () -> Bool
    private var models: [String: GitProjectModel] = [:]
    private var sessionProjects: [String: String] = [:]

    init(serverId: @escaping () -> UUID?, client: @escaping () -> GatewayClient?, supportsGit: @escaping () -> Bool = { true }) {
        self.serverId = serverId
        self.client = client
        self.gitOffered = supportsGit
    }

    /// True when the selected server's gateway lists the `git` extension (FR-31).
    var supportsGit: Bool { gitOffered() }

    private func key(_ id: String) -> String { "\(serverId()?.uuidString ?? "-")/\(id)" }

    func model(for projectId: String) -> GitProjectModel {
        let k = key(projectId)
        if let existing = models[k] { return existing }
        let created = GitProjectModel(projectId: projectId, clientProvider: client)
        models[k] = created
        return created
    }

    /// The project a gateway session belongs to, from the gateway's session index.
    func projectId(forSession sessionId: String) async -> String? {
        let k = key(sessionId)
        if let known = sessionProjects[k] { return known }
        guard let client = client(), let sessions = try? await client.sessions() else { return nil }
        for session in sessions { sessionProjects[key(session.sessionId)] = session.projectId }
        return sessionProjects[k]
    }

    /// `_acpcode/git/changed` arrived on the selected server.
    func handleChanged(_ params: ACP.Value?) {
        guard let changed = GatewayGitChanged.parse(params), let model = models[key(changed.projectId)] else { return }
        Task { await model.changed(hash: changed.hash) }
    }

    /// The connection was replaced (a reconnect): every model loads again when next shown.
    func connectionReset() {
        for model in models.values { model.invalidate() }
        epoch += 1
    }

    func openHomeTab(projectId: String) { homeTab = GitTabRequest(projectId: projectId) }
    func openSessionTab(projectId: String) { sessionTab = GitTabRequest(projectId: projectId) }

    func requestTurnDiff(sessionId: String, turn: Int) { turnRequest = GitTurnRequest(sessionId: sessionId, turn: turn) }

    func turnDiffModel(for request: GitTurnRequest) -> GitTurnDiffModel {
        GitTurnDiffModel(sessionId: request.sessionId, turn: request.turn, clientProvider: client)
    }
}
