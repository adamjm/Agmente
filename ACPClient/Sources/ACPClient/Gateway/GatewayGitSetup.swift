import Foundation
import ACP

// Git at project creation and git credentials (D-105). The gateway runs git and keeps every token.
// The phone sends a token once, reads back metadata only, and never receives a secret.

/// The git part of a create request. It is sent only when the person turned on "Create Git repository".
public struct GatewayGitSetup: Equatable, Sendable {
    /// An https remote, or nil for an empty repository with no remote.
    public var remote: String?
    /// A credential profile whose host is the remote's host. Sent only together with a remote.
    public var credentialId: String?

    public init(remote: String? = nil, credentialId: String? = nil) {
        self.remote = remote
        self.credentialId = credentialId
    }
}

/// The `git` field of a create result. A new repository has `branch` "" and `unborn` true.
public struct GatewayGitInit: Decodable, Equatable, Sendable {
    public let initialized: Bool
    public let remote: String?
    public let branch: String
    public let unborn: Bool
}

/// A created project and, when git was asked for, the git result.
public struct GatewayProjectCreated: Equatable, Sendable {
    public let project: GatewayProject
    public let git: GatewayGitInit?
}

/// A stored git credential as the gateway lists it. It never carries the token (D-105).
public struct GatewayGitCredential: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let host: String
    public let createdAt: String
    public let hasSecret: Bool

    public init(id: String, name: String, host: String, createdAt: String, hasSecret: Bool) {
        self.id = id
        self.name = name
        self.host = host
        self.createdAt = createdAt
        self.hasSecret = hasSecret
    }
}

/// The answer of `_acpcode/git/push` (D-105).
public struct GatewayGitPushResult: Decodable, Equatable, Sendable {
    public let pushed: Bool
    public let branch: String
    public let commit: String
    public let remote: String
}

/// Builds the params of `_acpcode/projects/create` for a folder the app makes inside a root (D-091).
public enum GatewayProjectCreateRequest {
    /// `createFolder` is always true here, because the sheet only makes folders. The git fields are added
    /// only when `git` is non-nil: `gitInit` true, `gitRemote` when there is a remote, and `credentialId`
    /// only together with a remote, since the gateway refuses it without one.
    public static func params(name: String, path: String, git: GatewayGitSetup?, runner: String? = nil) -> ACP.Value {
        var params: [String: ACP.Value] = [
            "name": .string(name),
            "path": .string(path),
            "createFolder": .bool(true),
        ]
        if let runner, !runner.isEmpty { params["runner"] = .string(runner) }
        if let git {
            params["gitInit"] = .bool(true)
            if let remote = git.remote, !remote.isEmpty {
                params["gitRemote"] = .string(remote)
                if let credentialId = git.credentialId, !credentialId.isEmpty {
                    params["credentialId"] = .string(credentialId)
                }
            }
        }
        return .object(params)
    }
}

public extension GatewayError {
    /// `-32601`: the gateway has no such method. A gateway without D-105 has no git methods, so this is how
    /// the phone finds out (`extensions` does not list git).
    var isMethodNotFound: Bool {
        if case .rpc(let code, _) = self { return code == -32601 }
        return false
    }
}

public extension GatewayClient {
    /// `_acpcode/projects/create` with a git setup (D-105). The folder, the `git init`, and the remote are
    /// all made by the gateway, and a failure leaves nothing behind. Refusals come back as `GatewayError.rpc`.
    func createProject(name: String, path: String, git: GatewayGitSetup?, runner: String? = nil) async throws -> GatewayProjectCreated {
        let result = try await call("_acpcode/projects/create", GatewayProjectCreateRequest.params(name: name, path: path, git: git, runner: runner))
        let project = try decode(GatewayProject.self, from: result["project"], what: "project")
        var gitResult: GatewayGitInit?
        if let value = result["git"], !Self.isNull(value) {
            gitResult = try decode(GatewayGitInit.self, from: value, what: "git")
        }
        return GatewayProjectCreated(project: project, git: gitResult)
    }

    /// `_acpcode/git/credentials/list`: metadata only (D-105). Answers `-32601` on a gateway without git.
    func gitCredentials() async throws -> [GatewayGitCredential] {
        let result = try await call("_acpcode/git/credentials/list", .object([:]))
        return try decode([GatewayGitCredential].self, from: result["credentials"], what: "credentials")
    }

    /// `_acpcode/git/credentials/set`. With `id`, it replaces the token of that profile (its host stays).
    /// The token is sent once and never comes back. The gateway refuses it over ws://. Returns the profile id.
    func setGitCredential(id: String?, name: String, host: String, token: String) async throws -> String {
        var params: [String: ACP.Value] = ["name": .string(name), "host": .string(host), "token": .string(token)]
        if let id { params["id"] = .string(id) }
        let result = try await call("_acpcode/git/credentials/set", .object(params))
        guard let newId = result["id"]?.stringValue, !newId.isEmpty else {
            throw GatewayError.invalidResponse("credential id")
        }
        return newId
    }

    /// `_acpcode/git/credentials/delete`: removes the token and the metadata.
    func deleteGitCredential(id: String) async throws {
        _ = try await call("_acpcode/git/credentials/delete", .object(["id": .string(id)]))
    }

    /// `_acpcode/git/push` (D-105). `confirm` is always sent as true, so the app must ask the person first.
    func gitPush(projectId: String, credentialId: String, branch: String? = nil) async throws -> GatewayGitPushResult {
        var params: [String: ACP.Value] = [
            "projectId": .string(projectId),
            "credentialId": .string(credentialId),
            "confirm": .bool(true),
        ]
        if let branch { params["branch"] = .string(branch) }
        let result = try await call("_acpcode/git/push", .object(params))
        return try decode(GatewayGitPushResult.self, from: result, what: "push")
    }

    private static func isNull(_ value: ACP.Value) -> Bool {
        if case .null = value { return true }
        return false
    }
}
