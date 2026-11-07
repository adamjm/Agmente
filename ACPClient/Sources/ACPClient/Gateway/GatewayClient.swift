import Foundation
import ACP

/// What the gateway client needs from a connection: one JSON-RPC call. `ACPService` is the real one;
/// tests use a fake.
public protocol GatewayCalling: Sendable {
    func gatewayCall(method: String, params: ACP.Value?) async throws -> ACP.Value
}

extension ACPService: GatewayCalling {
    public func gatewayCall(method: String, params: ACP.Value?) async throws -> ACP.Value {
        let response = try await call(method: method, params: params)
        return response.resultValue ?? .null
    }
}

public enum GatewayError: Error, Equatable, Sendable {
    /// The gateway answered with a JSON-RPC error.
    case rpc(code: Int, message: String)
    /// The connection is closed.
    case disconnected
    /// The answer was not in the documented shape.
    case invalidResponse(String)

    /// The text for a person.
    public var message: String {
        switch self {
        case .rpc(_, let message): return message
        case .disconnected: return "Not connected"
        case .invalidResponse(let what): return "Unexpected answer from the gateway (\(what))"
        }
    }
}

/// Typed calls to the gateway's `_agmente/*` methods (SPEC 6.2).
public struct GatewayClient: Sendable {
    private let caller: any GatewayCalling

    public init(_ caller: any GatewayCalling) {
        self.caller = caller
    }

    /// `_agmente/projects/list`
    public func projects() async throws -> [GatewayProject] {
        let result = try await call("_agmente/projects/list", .object([:]))
        return try decode([GatewayProject].self, from: result["projects"], what: "projects")
    }

    /// `_agmente/projects/create` (D-091). With `createFolder`, the gateway makes `<path>/<name>`:
    /// `path` is the parent folder, a configured root (see `projectRoots()`), and `name` is both the new
    /// folder's name and the project's name. Without it, `path` is an existing folder the project uses.
    /// Gateway refusals come back as `GatewayError.rpc` with the gateway's own text.
    public func createProject(name: String, path: String, createFolder: Bool = false) async throws -> GatewayProject {
        var params: [String: ACP.Value] = ["name": .string(name), "path": .string(path)]
        if createFolder { params["createFolder"] = .bool(true) }
        let result = try await call("_agmente/projects/create", .object(params))
        return try decode(GatewayProject.self, from: result["project"], what: "project")
    }

    /// `_agmente/projects/roots`: the configured roots that exist, as the gateway resolves them (D-091).
    /// A new project folder is made inside one of them.
    public func projectRoots() async throws -> [String] {
        let result = try await call("_agmente/projects/roots", .object([:]))
        return try decode(GatewayRootsResult.self, from: result, what: "roots").roots
    }

    /// `_agmente/sessions/index`, for one project or all.
    public func sessions(projectId: String? = nil) async throws -> [GatewaySession] {
        var params: [String: ACP.Value] = [:]
        if let projectId { params["projectId"] = .string(projectId) }
        let result = try await call("_agmente/sessions/index", .object(params))
        return try decode([GatewaySession].self, from: result["sessions"], what: "sessions")
    }

    /// `_agmente/sessions/subscribe`: the gateway answers with the head seq, then sends `_agmente/event`
    /// for each logged event after `afterSeq`, then live ones (D-028). Returns the head seq.
    @discardableResult
    public func subscribe(sessionId: String, afterSeq: Int) async throws -> Int {
        let result = try await call("_agmente/sessions/subscribe", .object(["sessionId": .string(sessionId), "afterSeq": .int(afterSeq)]))
        guard let head = result["headSeq"]?.intValue else { throw GatewayError.invalidResponse("headSeq") }
        return head
    }

    /// `_agmente/sessions/read`: marks the session read up to `seq` for this identity (D-030).
    @discardableResult
    public func markRead(sessionId: String, seq: Int) async throws -> Int {
        let result = try await call("_agmente/sessions/read", .object(["sessionId": .string(sessionId), "seq": .int(seq)]))
        guard let seen = result["lastSeenSeq"]?.intValue else { throw GatewayError.invalidResponse("lastSeenSeq") }
        return seen
    }

    func call(_ method: String, _ params: ACP.Value) async throws -> ACP.Value {
        do {
            return try await caller.gatewayCall(method: method, params: params)
        } catch let error as ACPServiceError {
            switch error {
            case .rpc(_, let rpc): throw GatewayError.rpc(code: rpc.code, message: rpc.message)
            case .disconnected: throw GatewayError.disconnected
            case .unsupportedMessage: throw GatewayError.invalidResponse("unsupported message")
            }
        }
    }

    func decode<T: Decodable>(_ type: T.Type, from value: ACP.Value?, what: String) throws -> T {
        guard let value else { throw GatewayError.invalidResponse(what) }
        do {
            return try value.decoded(as: type)
        } catch {
            throw GatewayError.invalidResponse(what)
        }
    }
}
