import ACP
import ACPClient
import Foundation

/// One skill as the gateway lists it (SPEC 6.2, D-087).
struct SkillSummary: Equatable, Identifiable, Sendable {
    let name: String
    let bytes: Int
    var id: String { name }
}

/// The skill calls the model needs. The gateway client is the real one; tests use a fake.
protocol SkillsClient: Sendable {
    func list() async throws -> [SkillSummary]
    func put(name: String, content: String) async throws
    func delete(name: String) async throws
}

/// The rules the app checks before any request (D-087, PLAN 6B.3). They match the gateway's own,
/// so an invalid skill never leaves the phone.
enum SkillRules {
    static let maxNameLength = 64
    /// The content cap in bytes (UTF-8), the gateway's rule (owner decision 8).
    static let maxContentBytes = 64 * 1024

    /// `^[a-z0-9]+(-[a-z0-9]+)*$`, at most 64 characters: lowercase letters and digits, single hyphens
    /// between them, no leading or trailing hyphen.
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= maxNameLength else { return false }
        guard name.allSatisfy({ ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-" }) else { return false }
        guard !name.hasPrefix("-"), !name.hasSuffix("-"), !name.contains("--") else { return false }
        return true
    }

    static func isValidContent(_ content: String) -> Bool {
        content.utf8.count <= maxContentBytes
    }
}

/// What a save did. Nothing is sent unless the outcome is `.saved` or the request failed on the gateway.
enum SkillSaveOutcome: Equatable {
    case saved
    case invalidName
    case contentTooLarge
    case notConfirmed
    case failed(String)
}

/// The gateway's skill calls (FR-43, SPEC 6.2). `projectId` names the project whose `.bob/skills` is used.
struct GatewaySkillsClient: SkillsClient {
    let caller: any GatewayCalling
    let projectId: String

    func list() async throws -> [SkillSummary] {
        let result = try await call("_acpcode/skills/list", extra: [:])
        guard let items = result.objectValue?["skills"]?.arrayValue else {
            throw GatewayError.invalidResponse("skills")
        }
        return items.compactMap { item -> SkillSummary? in
            guard let name = item.objectValue?["name"]?.stringValue else { return nil }
            return SkillSummary(name: name, bytes: item.objectValue?["bytes"]?.intValue ?? 0)
        }
    }

    func put(name: String, content: String) async throws {
        _ = try await call("_acpcode/skills/put", extra: ["name": .string(name), "content": .string(content)])
    }

    func delete(name: String) async throws {
        _ = try await call("_acpcode/skills/delete", extra: ["name": .string(name)])
    }

    private func call(_ method: String, extra: [String: ACP.Value]) async throws -> ACP.Value {
        var params = extra
        params["scope"] = .string("project")
        params["projectId"] = .string(projectId)
        do {
            return try await caller.gatewayCall(method: method, params: .object(params))
        } catch let error as ACPServiceError {
            switch error {
            case .rpc(_, let rpc): throw GatewayError.rpc(code: rpc.code, message: rpc.message)
            case .disconnected: throw GatewayError.disconnected
            case .unsupportedMessage: throw GatewayError.invalidResponse("unsupported message")
            }
        }
    }
}

/// The skills screen's state (PLAN 6B.3). Every save passes the rule check, then the gate, then one request.
@MainActor
final class SkillsModel: ObservableObject {
    @Published private(set) var skills: [SkillSummary] = []
    @Published private(set) var isLoading = false
    /// The last problem, in words for a person.
    @Published var message: String?

    private let client: SkillsClient
    private let gate: SkillSaveGate

    init(client: SkillsClient, gate: SkillSaveGate) {
        self.client = client
        self.gate = gate
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            skills = try await client.list().sorted { $0.name < $1.name }
            message = nil
        } catch {
            message = Self.describe(error)
        }
    }

    /// Saves a skill. The name and size are checked first, so an invalid skill never prompts for Face ID.
    /// The gate is asked next; the save request is sent only if it returns true.
    @discardableResult
    func save(name: String, content: String) async -> SkillSaveOutcome {
        guard SkillRules.isValidName(name) else {
            message = "A skill name uses lowercase letters, digits and single hyphens, at most 64 characters."
            return .invalidName
        }
        guard SkillRules.isValidContent(content) else {
            message = "The skill is larger than 64 KiB."
            return .contentTooLarge
        }
        guard await gate.confirmSave(skillName: name) else {
            message = "The skill was not saved. Face ID did not confirm."
            return .notConfirmed
        }
        do {
            try await client.put(name: name, content: content)
            message = nil
            await refresh()
            return .saved
        } catch {
            let text = Self.describe(error)
            message = text
            return .failed(text)
        }
    }

    /// Deletes one skill. Deleting is not gated by Face ID (owner decision 7 covers saves).
    func delete(name: String) async {
        do {
            try await client.delete(name: name)
            await refresh()
        } catch {
            message = Self.describe(error)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let gatewayError = error as? GatewayError { return gatewayError.message }
        return error.localizedDescription
    }
}
