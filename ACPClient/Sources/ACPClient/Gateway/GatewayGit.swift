import Foundation
import ACP

// Read-only git state from the gateway (FR-27, D-035, D-036, D-037). The app never sends a git
// command: it sends a project id, and a path that must come from the last `git/status` (FR-29).

/// A file's state in `git/status`. A value from a newer gateway decodes as `.unknown`.
public enum GatewayGitFileStatus: Equatable, Hashable, Sendable {
    case modified, added, deleted, renamed, copied, typeChanged, untracked, conflicted
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .modified: return "modified"
        case .added: return "added"
        case .deleted: return "deleted"
        case .renamed: return "renamed"
        case .copied: return "copied"
        case .typeChanged: return "type_changed"
        case .untracked: return "untracked"
        case .conflicted: return "conflicted"
        case .unknown(let value): return value
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "modified": self = .modified
        case "added": self = .added
        case "deleted": self = .deleted
        case "renamed": self = .renamed
        case "copied": self = .copied
        case "type_changed": self = .typeChanged
        case "untracked": self = .untracked
        case "conflicted": self = .conflicted
        default: self = .unknown(rawValue)
        }
    }
}

extension GatewayGitFileStatus: Codable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct GatewayGitFile: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let path: String
    public let status: GatewayGitFileStatus
    public let staged: Bool
    /// Line counts of the unstaged plus staged change; nil for untracked and binary files.
    public let added: Int?
    public let removed: Int?

    public var id: String { path }

    public init(path: String, status: GatewayGitFileStatus, staged: Bool, added: Int? = nil, removed: Int? = nil) {
        self.path = path
        self.status = status
        self.staged = staged
        self.added = added
        self.removed = removed
    }
}

public struct GatewayGitStatus: Codable, Equatable, Sendable {
    /// nil when HEAD is detached.
    public let branch: String?
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let files: [GatewayGitFile]
    /// The value `_agmente/git/changed` carries when the status changes.
    public let hash: String
    /// True when git's output was cut at the gateway's size cap: the list may be incomplete.
    public let truncated: Bool

    public init(branch: String?, upstream: String? = nil, ahead: Int = 0, behind: Int = 0, files: [GatewayGitFile] = [], hash: String, truncated: Bool = false) {
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.files = files
        self.hash = hash
        self.truncated = truncated
    }

    private enum CodingKeys: String, CodingKey { case branch, upstream, ahead, behind, files, hash, truncated }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        upstream = try c.decodeIfPresent(String.self, forKey: .upstream)
        ahead = try c.decodeIfPresent(Int.self, forKey: .ahead) ?? 0
        behind = try c.decodeIfPresent(Int.self, forKey: .behind) ?? 0
        files = try c.decode([GatewayGitFile].self, forKey: .files)
        hash = try c.decode(String.self, forKey: .hash)
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

/// The answer of `git/diff` and `git/turnDiff`.
public struct GatewayGitDiff: Codable, Equatable, Sendable {
    public let diff: String
    public let truncated: Bool
    /// Paths of secret files whose content the gateway hid (FR-30).
    public let hidden: [String]
    /// Set by `git/turnDiff` only.
    public let fromTree: String?
    public let toTree: String?

    public init(diff: String, truncated: Bool = false, hidden: [String] = [], fromTree: String? = nil, toTree: String? = nil) {
        self.diff = diff
        self.truncated = truncated
        self.hidden = hidden
        self.fromTree = fromTree
        self.toTree = toTree
    }

    private enum CodingKeys: String, CodingKey { case diff, truncated, hidden, fromTree, toTree }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        diff = try c.decode(String.self, forKey: .diff)
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        hidden = try c.decodeIfPresent([String].self, forKey: .hidden) ?? []
        fromTree = try c.decodeIfPresent(String.self, forKey: .fromTree)
        toTree = try c.decodeIfPresent(String.self, forKey: .toTree)
    }
}

public struct GatewayGitCommit: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let hash: String
    public let shortHash: String
    public let author: String
    /// ISO 8601 author date.
    public let date: String
    public let subject: String

    public var id: String { hash }

    public init(hash: String, shortHash: String, author: String, date: String, subject: String) {
        self.hash = hash
        self.shortHash = shortHash
        self.author = author
        self.date = date
        self.subject = subject
    }

    public var dateValue: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: date)
    }
}

public struct GatewayGitLog: Codable, Equatable, Sendable {
    public let commits: [GatewayGitCommit]
    /// Opaque; pass it back as `cursor` for the next page. nil on the last page.
    public let nextCursor: String?

    public init(commits: [GatewayGitCommit], nextCursor: String? = nil) {
        self.commits = commits
        self.nextCursor = nextCursor
    }
}

/// `_agmente/git/changed {projectId, hash}`: the status of a project the socket asked about changed (D-037).
public struct GatewayGitChanged: Equatable, Sendable {
    public static let method = "_agmente/git/changed"

    public let projectId: String
    public let hash: String

    public init(projectId: String, hash: String) {
        self.projectId = projectId
        self.hash = hash
    }

    public static func parse(_ params: ACP.Value?) -> GatewayGitChanged? {
        guard let object = params?.objectValue,
              let projectId = object["projectId"]?.stringValue, !projectId.isEmpty,
              let hash = object["hash"]?.stringValue else { return nil }
        return GatewayGitChanged(projectId: projectId, hash: hash)
    }
}

public extension GatewayError {
    /// `-32000 "not a git repository"`: the project folder is not a git repository.
    var isNotARepository: Bool { isGit("not a git repository") }
    /// `-32000 "no snapshot for this turn"`: the gateway holds no snapshot of that turn (D-036).
    var isNoSnapshot: Bool { isGit("no snapshot for this turn") }
    /// `-32000 "turn is still running"`: the turn's end snapshot does not exist yet.
    var isTurnRunning: Bool { isGit("turn is still running") }

    private func isGit(_ text: String) -> Bool {
        if case .rpc(let code, let message) = self { return code == -32000 && message == text }
        return false
    }
}

public extension GatewayClient {
    /// `_agmente/git/status`. It also makes the gateway remember the file list as the only paths a diff
    /// accepts for this project (FR-29), and send `git/changed` to this socket (D-037).
    func gitStatus(projectId: String) async throws -> GatewayGitStatus {
        let result = try await call("_agmente/git/status", .object(["projectId": .string(projectId)]))
        return try decode(GatewayGitStatus.self, from: result, what: "git status")
    }

    /// `_agmente/git/diff` of one path (or the whole tree when `path` is nil). A path must be in the
    /// last status of the project, or the gateway answers `-32602`.
    func gitDiff(projectId: String, path: String? = nil, staged: Bool = false) async throws -> GatewayGitDiff {
        var params: [String: ACP.Value] = ["projectId": .string(projectId)]
        if let path { params["path"] = .string(path) }
        if staged { params["staged"] = .bool(true) }
        let result = try await call("_agmente/git/diff", .object(params))
        return try decode(GatewayGitDiff.self, from: result, what: "git diff")
    }

    /// `_agmente/git/diff` between two trees (from a turn's snapshots). A `path` must be one of the
    /// files that differ.
    func gitDiff(projectId: String, fromTree: String, toTree: String, path: String? = nil) async throws -> GatewayGitDiff {
        var params: [String: ACP.Value] = ["projectId": .string(projectId), "fromTree": .string(fromTree), "toTree": .string(toTree)]
        if let path { params["path"] = .string(path) }
        let result = try await call("_agmente/git/diff", .object(params))
        return try decode(GatewayGitDiff.self, from: result, what: "git diff")
    }

    /// `_agmente/git/log`, newest first. Pass the previous `nextCursor` for the next page.
    func gitLog(projectId: String, limit: Int? = nil, cursor: String? = nil) async throws -> GatewayGitLog {
        var params: [String: ACP.Value] = ["projectId": .string(projectId)]
        if let limit { params["limit"] = .int(limit) }
        if let cursor { params["cursor"] = .string(cursor) }
        let result = try await call("_agmente/git/log", .object(params))
        return try decode(GatewayGitLog.self, from: result, what: "git log")
    }

    /// `_agmente/git/turnDiff`: what one turn changed. `turn` counts from 1 per session. Errors:
    /// `isNoSnapshot`, `isTurnRunning`.
    func gitTurnDiff(sessionId: String, turn: Int) async throws -> GatewayGitDiff {
        let result = try await call("_agmente/git/turnDiff", .object(["sessionId": .string(sessionId), "turn": .int(turn)]))
        return try decode(GatewayGitDiff.self, from: result, what: "turn diff")
    }
}
