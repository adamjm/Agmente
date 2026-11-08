import Foundation

/// The text shown for MCP entries that the owner has to read (PLAN 6B.2, owner decision 5).
enum MCPServerWarning {
    /// Shown for every stdio entry. The command runs in the project container, not on the phone.
    static let stdio = "This runs a command inside the project container. It must be configured on the gateway."
    /// Shown where `alwaysAllow` is edited (D-089): these tools run without the phone's prompt.
    static let alwaysAllow = "Tools listed here run without asking first. Only list tools you trust."
}

/// One MCP server the phone sends in `session/new` and `session/resume` (FR-40, D-084, D-086, D-089).
///
/// Holds names, URLs, commands and flags only. Header values and environment values are in the
/// Keychain (`MCPHeaderStore`), so this value can be written to a file with no secret in it.
struct MCPServerEntry: Codable, Equatable, Identifiable, Sendable {
    enum Transport: String, Codable, Sendable {
        case http
        case stdio
    }

    var id: UUID
    var name: String
    var transport: Transport
    /// A disabled entry is kept in the list but not sent (PLAN 6B.2).
    var isEnabled: Bool
    /// http: the endpoint. https to any host; http only to a loopback host (the gateway's rule, D-019).
    var url: String?
    /// http: header names. The values are in the Keychain.
    var headerNames: [String]
    /// stdio: the command. It runs inside the project container.
    var command: String?
    /// stdio: arguments. They are stored in the file, so they must not hold secrets.
    var args: [String]
    /// stdio: environment variable names. The values are in the Keychain.
    var envNames: [String]
    /// Tool names that run without the phone's prompt (D-089).
    var alwaysAllow: [String]
    /// stdio: the owner has read the warning and confirmed it. Without this the entry is not sent.
    var stdioAcknowledged: Bool

    init(
        id: UUID = UUID(),
        name: String,
        transport: Transport,
        isEnabled: Bool = true,
        url: String? = nil,
        headerNames: [String] = [],
        command: String? = nil,
        args: [String] = [],
        envNames: [String] = [],
        alwaysAllow: [String] = [],
        stdioAcknowledged: Bool = false
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.isEnabled = isEnabled
        self.url = url
        self.headerNames = headerNames
        self.command = command
        self.args = args
        self.envNames = envNames
        self.alwaysAllow = alwaysAllow
        self.stdioAcknowledged = stdioAcknowledged
    }

    /// The entry with the fields of the other transport cleared, so stored data matches the transport.
    func normalized() -> MCPServerEntry {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch transport {
        case .http:
            copy.command = nil
            copy.args = []
            copy.envNames = []
            copy.stdioAcknowledged = false
        case .stdio:
            copy.url = nil
            copy.headerNames = []
        }
        return copy
    }

    /// The first problem with the entry, or nil. Values are checked separately (`isValidSecretValue`).
    func validationError() -> MCPServerEntryError? {
        let name = self.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .emptyName }
        if name.count > 200 || Self.hasControl(name) { return .invalidName }
        if !alwaysAllow.allSatisfy({ Self.isPlainText($0, max: 128) }) || alwaysAllow.count > 64 {
            return .invalidToolName
        }
        if Set(alwaysAllow).count != alwaysAllow.count { return .invalidToolName }

        switch transport {
        case .http:
            guard let url, Self.urlAllowed(url) else { return .invalidURL }
            if headerNames.count > 32 { return .tooMany("headers") }
            var seen = Set<String>()
            for header in headerNames {
                guard Self.isHeaderName(header) else { return .invalidHeaderName }
                guard seen.insert(header.lowercased()).inserted else { return .duplicateHeader }
            }
        case .stdio:
            guard stdioAcknowledged else { return .stdioNotAcknowledged }
            guard let command, Self.isPlainText(command.trimmingCharacters(in: .whitespaces), max: 1024) else {
                return .invalidCommand
            }
            if args.count > 64 || !args.allSatisfy({ $0.count <= 1024 && !Self.hasControl($0) }) {
                return .invalidArgument
            }
            if envNames.count > 32 { return .tooMany("environment variables") }
            var seen = Set<String>()
            for env in envNames {
                guard Self.isEnvName(env) else { return .invalidEnvName }
                guard seen.insert(env).inserted else { return .duplicateEnv }
            }
        }
        return nil
    }

    func validate() throws {
        if let problem = validationError() { throw problem }
    }

    // MARK: Rules

    /// https to any host, or http to a loopback host, with no user or password in the URL.
    static func urlAllowed(_ raw: String) -> Bool {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
        switch scheme {
        case "https":
            return true
        case "http":
            return TransportPolicy.isLoopback(host)
        default:
            return false
        }
    }

    /// A header name: 1 to 128 ASCII letters, digits, `-` or `_`.
    static func isHeaderName(_ name: String) -> Bool {
        (1...128).contains(name.count) && name.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_" }
    }

    /// An environment variable name: `[A-Za-z_][A-Za-z0-9_]*`, at most 128 characters.
    static func isEnvName(_ name: String) -> Bool {
        guard (1...128).contains(name.count), let first = name.first else { return false }
        guard first == "_" || (first.isASCII && first.isLetter) else { return false }
        return name.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
    }

    /// A secret value (a header or environment value): non-empty, at most 4096 bytes, no line break or NUL.
    static func isValidSecretValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 && !value.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" })
    }

    static func isPlainText(_ value: String, max: Int) -> Bool {
        !value.isEmpty && value.count <= max && !hasControl(value)
    }

    static func hasControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

enum MCPServerEntryError: LocalizedError, Equatable {
    case emptyName
    case invalidName
    case invalidURL
    case invalidHeaderName
    case duplicateHeader
    case invalidCommand
    case invalidArgument
    case invalidEnvName
    case duplicateEnv
    case invalidToolName
    case tooMany(String)
    case stdioNotAcknowledged
    case invalidValue(String)
    case missingValue(String)
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .emptyName: return "Give the server a name."
        case .invalidName: return "The name is too long or has control characters."
        case .invalidURL: return "The URL must be https://, or http:// to this computer (localhost). It must not contain a user name or password."
        case .invalidHeaderName: return "A header name uses letters, digits, - and _ only."
        case .duplicateHeader: return "Two headers have the same name."
        case .invalidCommand: return "Enter the command the server starts."
        case .invalidArgument: return "An argument is too long or has control characters."
        case .invalidEnvName: return "An environment variable name uses letters, digits and _, and does not start with a digit."
        case .duplicateEnv: return "Two environment variables have the same name."
        case .invalidToolName: return "Tool names must be unique, non-empty and at most 128 characters."
        case .tooMany(let what): return "Too many \(what)."
        case .stdioNotAcknowledged: return "Read the warning and confirm it before saving a command."
        case .invalidValue(let name): return "The value for \(name) is empty or too long."
        case .missingValue(let name): return "No value is stored for \(name). Enter it again."
        case .unreadableFile: return "The saved MCP server list cannot be read, so it cannot be changed."
        }
    }
}
