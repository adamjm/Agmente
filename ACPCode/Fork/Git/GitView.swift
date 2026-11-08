import SwiftUI
import ACPClient

// Git views for a gateway project (FR-31): a branch chip, a Git tab, and a turn diff. All read-only.

// MARK: - Branch chip

/// The branch, ahead/behind and a dot when the working tree has changes. Shown only once a status loaded.
struct GitBranchChip: View {
    @ObservedObject var model: GitProjectModel
    var action: (() -> Void)?

    var body: some View {
        if let status = model.status {
            let content = HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                Text(status.branch ?? "detached")
                    .lineLimit(1)
                    .truncationMode(.middle)
                if status.ahead > 0 { Text("↑\(status.ahead)") }
                if status.behind > 0 { Text("↓\(status.behind)") }
                if model.isDirty {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .frame(maxWidth: 180)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(GitChipText.accessibilityLabel(status: status))
            .accessibilityIdentifier("gitBranchChip")
            if let action {
                Button(action: action) { content.contentShape(Rectangle().inset(by: -12)) }.buttonStyle(.plain)
            } else {
                content
            }
        }
    }
}

enum GitChipText {
    static func accessibilityLabel(status: GatewayGitStatus) -> String {
        var parts = ["Branch \(status.branch ?? "detached head")"]
        if status.ahead > 0 { parts.append("\(status.ahead) ahead") }
        if status.behind > 0 { parts.append("\(status.behind) behind") }
        parts.append(status.files.isEmpty ? "no changes" : "\(status.files.count) changed")
        return parts.joined(separator: ", ")
    }
}

/// The chip in a project's header on the gateway home. It loads the status once when shown, and again
/// after a reconnect or a `git/changed` (not on a timer: each load starts a git container).
struct GitHomeChip: View {
    @ObservedObject var store: GitStore
    let projectId: String
    /// In a session the Git tab stays reachable without a status (for "not a repository" and errors).
    var inSession = false

    var body: some View {
        GitHomeChipInner(store: store, model: store.model(for: projectId), inSession: inSession)
    }
}

private struct GitHomeChipInner: View {
    @ObservedObject var store: GitStore
    @ObservedObject var model: GitProjectModel
    let inSession: Bool

    var body: some View {
        Group {
            if model.status != nil {
                GitBranchChip(model: model) { open() }
            } else if inSession {
                Button(action: open) { Image(systemName: "arrow.triangle.branch") }
                    .accessibilityLabel("Git")
                    .accessibilityIdentifier("gitOpenButton")
            }
        }
        .task(id: store.epoch) { await model.loadIfNeeded() }
    }

    private func open() {
        if inSession { store.openSessionTab(projectId: model.projectId) } else { store.openHomeTab(projectId: model.projectId) }
    }
}

/// Presents the Git tab opened from a chip on the gateway home.
struct GitHomeTabSheet: ViewModifier {
    @ObservedObject var store: GitStore

    func body(content: Content) -> some View {
        content.sheet(item: $store.homeTab) { request in
            GitTabView(model: store.model(for: request.projectId))
        }
    }
}

// MARK: - Git tab

struct GitTabView: View {
    @ObservedObject var model: GitProjectModel
    @Environment(\.dismiss) private var dismiss
    @State private var part: Part = .changes
    @State private var showDiff = false

    enum Part: String, CaseIterable, Identifiable {
        case changes = "Changes"
        case history = "History"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Part", selection: $part) {
                    ForEach(Part.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .accessibilityIdentifier("gitSectionPicker")

                switch part {
                case .changes: changes
                case .history: GitLogList(model: model)
                }
            }
            .navigationTitle(model.status?.branch ?? "Git")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("gitTabDone")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh")
                        .accessibilityIdentifier("gitRefresh")
                }
            }
            .navigationDestination(isPresented: $showDiff) {
                GitFileDiffView(model: model)
                    .onDisappear { model.closeDiff() }
            }
        }
        .accessibilityIdentifier("gitTab")
        .task { await model.refresh() }
    }

    @ViewBuilder
    private var changes: some View {
        switch model.state {
        case .idle, .loading where model.status == nil:
            ProgressView("Loading status")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("gitLoading")
        case .notRepository:
            GitMessageView(icon: "questionmark.folder", title: "Not a git repository",
                           detail: "This project's folder has no git repository.", identifier: "gitNotRepository")
        case .failed(let message) where model.status == nil:
            GitMessageView(icon: "exclamationmark.triangle", title: "Could not read git status", detail: message,
                           identifier: "gitError", retry: { Task { await model.refresh() } })
        default:
            if let status = model.status {
                statusList(status)
            }
        }
    }

    private func statusList(_ status: GatewayGitStatus) -> some View {
        List {
            Section {
                HStack {
                    Image(systemName: "arrow.triangle.branch")
                    Text(status.branch ?? "Detached HEAD").font(.headline)
                    Spacer()
                    if let upstream = status.upstream {
                        Text(upstream).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if status.ahead > 0 || status.behind > 0 {
                    Text("\(status.ahead) ahead, \(status.behind) behind")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if case .failed(let message) = model.state {
                    Label("Refresh failed: \(message)", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                        .accessibilityIdentifier("gitRefreshError")
                }
                if status.truncated {
                    Label("The list was cut because the output was too large. Some files may be missing.", systemImage: "scissors")
                        .font(.footnote).foregroundStyle(.orange)
                        .accessibilityIdentifier("gitTruncated")
                }
            }
            Section(status.files.isEmpty ? "" : "Changed files (\(status.files.count))") {
                if status.files.isEmpty {
                    Text("No changes").foregroundStyle(.secondary).accessibilityIdentifier("gitClean")
                }
                ForEach(status.files) { file in
                    Button {
                        showDiff = true
                        Task { await model.openDiff(path: file.path, staged: file.staged) }
                    } label: {
                        GitFileRow(file: file)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("gitFile.\(file.path)")
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.refresh() }
    }
}

struct GitFileRow: View {
    let file: GatewayGitFile

    var body: some View {
        HStack(spacing: 10) {
            Text(GitFileText.letter(file.status))
                .font(.caption.monospaced().weight(.bold))
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(GitFileText.color(file.status).opacity(0.2)))
                .foregroundStyle(GitFileText.color(file.status))
            VStack(alignment: .leading, spacing: 2) {
                Text(file.path).font(.footnote).lineLimit(2).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(GitFileText.label(file.status))
                    if file.staged { Text("staged").foregroundStyle(.green) }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if let added = file.added, let removed = file.removed {
                Text("+\(added)").foregroundStyle(.green).font(.caption.monospaced())
                Text("-\(removed)").foregroundStyle(.red).font(.caption.monospaced())
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

enum GitFileText {
    static func letter(_ status: GatewayGitFileStatus) -> String {
        switch status {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .typeChanged: return "T"
        case .untracked: return "?"
        case .conflicted: return "U"
        case .unknown: return "•"
        }
    }

    static func label(_ status: GatewayGitFileStatus) -> String {
        switch status {
        case .typeChanged: return "type changed"
        case .unknown(let value): return value
        default: return status.rawValue
        }
    }

    static func color(_ status: GatewayGitFileStatus) -> Color {
        switch status {
        case .added, .untracked: return .green
        case .deleted, .conflicted: return .red
        case .renamed, .copied: return .blue
        default: return .orange
        }
    }
}

struct GitMessageView: View {
    let icon: String
    let title: String
    let detail: String
    let identifier: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let retry {
                Button("Try again", action: retry).buttonStyle(.bordered).accessibilityIdentifier("\(identifier).retry")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Diff of one file

struct GitFileDiffView: View {
    @ObservedObject var model: GitProjectModel

    private var file: GatewayGitFile? { model.status?.files.first { $0.path == model.diffPath } }

    var body: some View {
        VStack(spacing: 0) {
            if let file, file.staged {
                Picker("Version", selection: Binding(
                    get: { model.diffStaged },
                    set: { staged in Task { await model.openDiff(path: file.path, staged: staged) } })) {
                    Text("Unstaged").tag(false)
                    Text("Staged").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .accessibilityIdentifier("gitDiffVersion")
            }
            switch model.diff {
            case .none, .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("gitDiffLoading")
            case .failed(let message):
                GitMessageView(icon: "exclamationmark.triangle", title: "Could not load the diff", detail: message,
                               identifier: "gitDiffError",
                               retry: { if let file { Task { await model.openDiff(path: file.path, staged: model.diffStaged) } } })
            case .loaded(let diff):
                GitDiffBody(diff: diff, emptyText: "No textual changes to show")
            }
        }
        .navigationTitle(model.diffPath.map { ($0 as NSString).lastPathComponent } ?? "Diff")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }
}

/// Renders a gateway diff: truncated notice, hidden secret files as "content hidden", then each file.
struct GitDiffBody: View {
    let diff: GatewayGitDiff
    let emptyText: String

    var body: some View {
        let files = GitDiffText.split(diff.diff)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if diff.truncated {
                    Label("This diff was cut because it was too large.", systemImage: "scissors")
                        .font(.footnote).foregroundStyle(.orange)
                        .accessibilityIdentifier("gitDiffTruncated")
                }
                if files.isEmpty && !diff.truncated {
                    Text(emptyText).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("gitDiffEmpty")
                }
                ForEach(files) { file in
                    GitDiffFileView(file: file)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct GitDiffFileView: View {
    let file: GitDiffFile

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: file.hidden ? "lock.fill" : "doc.text").foregroundStyle(.secondary)
                Text(file.path).font(.footnote.weight(.semibold)).lineLimit(2).truncationMode(.middle)
                Spacer()
                if !file.hidden {
                    Text("+\(file.added)").foregroundStyle(.green).font(.caption.monospaced())
                    Text("-\(file.removed)").foregroundStyle(.red).font(.caption.monospaced())
                }
            }
            .padding(.bottom, 6)
            if file.hidden {
                Text("Content hidden")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("gitHidden.\(file.path)")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(file.lines) { line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Self.color(line.kind))
                                .padding(.horizontal, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Self.background(line.kind))
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .accessibilityIdentifier("gitDiffFile.\(file.path)")
    }

    private static func color(_ kind: GitDiffLine.Kind) -> Color {
        switch kind {
        case .added: return .green
        case .removed: return .red
        case .hunk: return .blue
        case .meta, .note: return .secondary
        case .context: return .primary
        }
    }

    private static func background(_ kind: GitDiffLine.Kind) -> Color {
        switch kind {
        case .added: return Color.green.opacity(0.12)
        case .removed: return Color.red.opacity(0.12)
        default: return .clear
        }
    }
}

// MARK: - Log

struct GitLogList: View {
    @ObservedObject var model: GitProjectModel

    var body: some View {
        Group {
            switch model.logState {
            case .idle, .loading where model.commits.isEmpty:
                ProgressView("Loading history").frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("gitLogLoading")
            case .notRepository:
                GitMessageView(icon: "questionmark.folder", title: "Not a git repository",
                               detail: "This project's folder has no git repository.", identifier: "gitLogNotRepository")
            case .failed(let message) where model.commits.isEmpty:
                GitMessageView(icon: "exclamationmark.triangle", title: "Could not read history", detail: message,
                               identifier: "gitLogError", retry: { Task { await model.loadLog() } })
            default:
                if model.commits.isEmpty {
                    GitMessageView(icon: "clock", title: "No commits yet", detail: "This repository has no history.", identifier: "gitLogEmpty")
                } else {
                    List {
                        ForEach(model.commits) { commit in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(commit.subject).font(.subheadline).lineLimit(2)
                                HStack(spacing: 6) {
                                    Text(commit.shortHash).font(.caption.monospaced())
                                    Text(commit.author)
                                    if let date = commit.dateValue { Text(date, style: .relative) }
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("gitCommit.\(commit.shortHash)")
                        }
                        if model.nextCursor != nil {
                            Button("Load more") { Task { await model.loadMoreLog() } }
                                .accessibilityIdentifier("gitLogMore")
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
        }
        .task { if model.commits.isEmpty { await model.loadLog() } }
    }
}

// MARK: - Turn diff

struct GitTurnDiffView: View {
    @ObservedObject var model: GitTurnDiffModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .loading:
                    ProgressView("Loading turn diff").frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("turnDiffLoading")
                case .noSnapshot:
                    GitMessageView(icon: "camera.metering.unknown", title: "No snapshot for this turn",
                                   detail: "The gateway did not record the files for this turn, so it cannot show what changed.",
                                   identifier: "turnDiffNoSnapshot")
                case .running:
                    GitMessageView(icon: "hourglass", title: "Turn is still running",
                                   detail: "The diff is ready when the turn has finished.", identifier: "turnDiffRunning",
                                   retry: { Task { await model.load() } })
                case .failed(let message):
                    GitMessageView(icon: "exclamationmark.triangle", title: "Could not load the turn diff", detail: message,
                                   identifier: "turnDiffError", retry: { Task { await model.load() } })
                case .loaded(let diff):
                    GitDiffBody(diff: diff, emptyText: "This turn changed no files")
                }
            }
            .navigationTitle("Turn \(model.turn) changes")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("turnDiffDone")
                }
            }
        }
        .accessibilityIdentifier("turnDiffSheet")
        .task { await model.load() }
    }
}

// MARK: - Session header

/// Adds the branch chip and the Git tab to a session on a gateway that offers git, and presents the
/// turn-diff sheet. It does nothing for other servers.
struct GitSessionToolbar: ViewModifier {
    @ObservedObject var store: GitStore
    let sessionId: String
    let enabled: Bool
    @State private var projectId: String?

    func body(content: Content) -> some View {
        content
            .toolbar {
                if enabled, let projectId {
                    ToolbarItem(placement: Self.placement) {
                        GitHomeChip(store: store, projectId: projectId, inSession: true)
                    }
                }
            }
            .task(id: "\(sessionId)|\(enabled)|\(store.epoch)") {
                guard enabled, !sessionId.isEmpty else { projectId = nil; return }
                projectId = await store.projectId(forSession: sessionId)
            }
            .sheet(item: $store.sessionTab) { request in
                GitTabView(model: store.model(for: request.projectId))
            }
            .sheet(item: $store.turnRequest) { request in
                GitTurnDiffView(model: store.turnDiffModel(for: request))
            }
    }

    private static var placement: ToolbarItemPlacement {
#if os(macOS)
        .primaryAction
#else
        .topBarTrailing
#endif
    }
}

extension View {
    func gitHomeTabSheet(store: GitStore) -> some View {
        modifier(GitHomeTabSheet(store: store))
    }

    func gitSessionToolbar(store: GitStore, sessionId: String, enabled: Bool) -> some View {
        modifier(GitSessionToolbar(store: store, sessionId: sessionId, enabled: enabled))
    }
}
