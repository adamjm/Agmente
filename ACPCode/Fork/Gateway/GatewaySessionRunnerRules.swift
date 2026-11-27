import Foundation
import ACPClient

/// What the new-session sheet chose about the runner (per-session runner, D-125). Pure data, so the rules and the
/// start sequence are tested without a view.
struct GatewayNewSessionChoice: Equatable {
    /// The runner id to send, or nil when the session uses the project's own runner (or the gateway offers no choice).
    var runner: String?
    /// True when the session starts in a new git worktree of the project.
    var worktree: Bool

    /// What a session without a runner choice sends: the project's runner, no worktree.
    static let projectDefault = GatewayNewSessionChoice(runner: nil, worktree: false)
}

/// The rules of the runner picker and the "Separate worktree" toggle on the new-session sheet.
enum GatewaySessionRunnerRules {
    /// The runners the picker offers: all of them with two or more, else none (so an old gateway or a single
    /// runner changes nothing).
    static func choices(_ runners: [GatewayRunner]) -> [GatewayRunner] {
        GatewayRunnerRules.choices(runners)
    }

    /// The project's own runner: its `runner`, else the gateway's default (a project without one runs on it).
    static func ownRunner(of project: GatewayProject, defaultRunner: String?) -> String? {
        if let runner = project.runner, !runner.isEmpty { return runner }
        if let defaultRunner, !defaultRunner.isEmpty { return defaultRunner }
        return nil
    }

    /// The runner the picker starts on: the project's runner when it is listed, else the gateway's default when
    /// it is listed, else the first runner. Nil when there is no choice to make.
    static func defaultSelection(project: GatewayProject?, runners: [GatewayRunner], defaultRunner: String?) -> String? {
        let offered = choices(runners)
        guard !offered.isEmpty else { return nil }
        if let id = project?.runner, offered.contains(where: { $0.id == id }) { return id }
        return GatewayRunnerRules.defaultSelection(runners, defaultRunner: defaultRunner)
    }

    /// True when the chosen runner is not the project's own.
    static func differsFromProject(selected: String?, project: GatewayProject?, defaultRunner: String?) -> Bool {
        guard let selected, !selected.isEmpty, let project else { return false }
        return selected != ownRunner(of: project, defaultRunner: defaultRunner)
    }

    /// The toggle is shown only when a runner is offered, the chosen runner differs from the project's, and the
    /// project is not itself a worktree project.
    static func offersWorktree(project: GatewayProject?, runners: [GatewayRunner], selected: String?, defaultRunner: String?) -> Bool {
        guard let project, !choices(runners).isEmpty, project.parentId == nil else { return false }
        return differsFromProject(selected: selected, project: project, defaultRunner: defaultRunner)
    }

    /// The label under a session row and in its header: the runner's name and, for a worktree project, its
    /// branch. Nil unless the gateway lists two or more runners, and nil when there is nothing to say.
    static func sessionLabel(_ session: GatewaySession, project: GatewayProject?, runners: [GatewayRunner]) -> String? {
        guard !choices(runners).isEmpty else { return nil }
        var parts: [String] = []
        if let id = session.runner, let name = runners.first(where: { $0.id == id })?.name { parts.append(name) }
        if let branch = project?.branch { parts.append(branch) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The runner and worktree state of one new-session sheet.
struct GatewayNewSessionRunnerState: Equatable {
    let runners: [GatewayRunner]
    let defaultRunner: String?
    private(set) var project: GatewayProject?
    private(set) var selectedRunner: String?
    private(set) var worktree = false

    init(runners: [GatewayRunner], defaultRunner: String?, project: GatewayProject?) {
        self.runners = runners
        self.defaultRunner = defaultRunner
        self.project = project
        self.selectedRunner = GatewaySessionRunnerRules.defaultSelection(project: project, runners: runners, defaultRunner: defaultRunner)
    }

    var offersRunner: Bool { !GatewaySessionRunnerRules.choices(runners).isEmpty }

    var offersWorktree: Bool {
        GatewaySessionRunnerRules.offersWorktree(project: project, runners: runners, selected: selectedRunner, defaultRunner: defaultRunner)
    }

    /// A new project resets the picker to its default and the toggle to off.
    mutating func select(project: GatewayProject?) {
        guard project?.id != self.project?.id else { return }
        self.project = project
        selectedRunner = GatewaySessionRunnerRules.defaultSelection(project: project, runners: runners, defaultRunner: defaultRunner)
        worktree = false
    }

    /// Choosing the project's own runner again turns the toggle off.
    mutating func select(runner: String?) {
        selectedRunner = runner
        if !offersWorktree { worktree = false }
    }

    mutating func setWorktree(_ on: Bool) {
        worktree = on && offersWorktree
    }

    /// What the sheet sends. A runner is named only when it differs from the project's own.
    var choice: GatewayNewSessionChoice {
        guard offersRunner,
              GatewaySessionRunnerRules.differsFromProject(selected: selectedRunner, project: project, defaultRunner: defaultRunner)
        else { return .projectDefault }
        return GatewayNewSessionChoice(runner: selectedRunner, worktree: worktree && offersWorktree)
    }
}

/// The start sequence of a new gateway session with a runner and worktree choice.
enum GatewayNewSessionStarter {
    /// Starts a session in `project`. Without a worktree, `begin` runs at once with the project's path and the
    /// runner (nil when it is the project's own). With a worktree, the gateway makes it first
    /// (`_acpcode/projects/createWorktree`); then `reload` runs with the new project so the list shows it, and
    /// `begin` runs with the new project's path and the runner. When the worktree cannot be made, nothing is
    /// started and the gateway's message is returned. Returns nil on success.
    @MainActor
    static func start(
        project: GatewayProject,
        choice: GatewayNewSessionChoice,
        client: GatewayClient?,
        reload: (GatewayProject?) async -> Void,
        begin: (String, String?) -> Void
    ) async -> String? {
        guard choice.worktree else {
            guard let cwd = gatewayNewSessionCwd(selectedProjectPath: project.path) else { return nil }
            begin(cwd, choice.runner)
            return nil
        }
        guard let client else { return "Not connected to the gateway." }
        let child: GatewayProject
        do {
            child = try await client.createWorktree(projectId: project.id, runner: choice.runner)
        } catch {
            return (error as? GatewayError)?.message ?? error.localizedDescription
        }
        await reload(child)
        guard let cwd = gatewayNewSessionCwd(selectedProjectPath: child.path) else {
            return "The gateway made a worktree without a folder."
        }
        begin(cwd, choice.runner)
        return nil
    }
}
