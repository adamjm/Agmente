import Foundation
import ACP

public enum ACPConnectedProtocol: String, Equatable, Sendable {
    case acp
    case codexAppServer
}

public struct ACPAuthMethod: Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String?

    public init(id: String, name: String, description: String?) {
        self.id = id
        self.name = name
        self.description = description
    }
}

/// What the ACP Code gateway says about itself in `initialize` (`_meta["acpcode/gateway"]`, D-026).
/// A server that is not the gateway has none.
public struct GatewayInfo: Equatable, Sendable {
    public let version: String
    public let extensions: [String]

    public init(version: String, extensions: [String]) {
        self.version = version
        self.extensions = extensions
    }

    public func supports(_ name: String) -> Bool { extensions.contains(name) }
}

public struct ACPInitializeResult: Equatable, Sendable {
    public let connectedProtocol: ACPConnectedProtocol?
    public let agentInfo: AgentProfile?
    public let authMethods: [ACPAuthMethod]
    public let currentModeId: String?
    public let userAgent: String?
    public let promptCapabilitiesDeclared: Bool
    public let gateway: GatewayInfo?
}

public enum ACPInitializeParser {
    public static func parse(result: ACP.Value?) -> ACPInitializeResult? {
        guard let resultObject = result?.objectValue else { return nil }
        return parse(result: resultObject)
    }

    public static func parse(result: [String: ACP.Value]) -> ACPInitializeResult {
        let hasAcpMarkers = result["protocolVersion"] != nil
            || result["agentCapabilities"] != nil
            || result["agentInfo"] != nil
            || result["agent"] != nil

        let userAgent = result["userAgent"]?.stringValue
        let connectedProtocol: ACPConnectedProtocol? = hasAcpMarkers ? .acp : (userAgent != nil ? .codexAppServer : nil)

        let authMethods: [ACPAuthMethod]
        if case let .array(items)? = result["authMethods"] {
            authMethods = items.compactMap { item in
                guard let obj = item.objectValue,
                      let id = obj["id"]?.stringValue,
                      let name = obj["name"]?.stringValue else {
                    return nil
                }
                let description = obj["description"]?.stringValue
                return ACPAuthMethod(id: id, name: name, description: description)
            }
        } else {
            authMethods = []
        }

        let currentModeId = result["modes"]?.objectValue?["currentModeId"]?.stringValue

        let capabilitiesObj = result["agentCapabilities"]?.objectValue
            ?? result["capabilities"]?.objectValue
        let promptCapabilitiesDeclared = capabilitiesObj?["promptCapabilities"]?.objectValue != nil

        let agentInfo: AgentProfile?
        switch connectedProtocol {
        case .codexAppServer:
            if let userAgent {
                agentInfo = makeCodexAgentInfo(userAgent: userAgent)
            } else {
                agentInfo = nil
            }
        case .acp:
            agentInfo = AgentProfile.parse(from: result)
        case .none:
            agentInfo = nil
        }

        var gateway: GatewayInfo?
        if let meta = result["_meta"]?.objectValue?["acpcode/gateway"]?.objectValue,
           let version = meta["version"]?.stringValue {
            let names = meta["extensions"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            gateway = GatewayInfo(version: version, extensions: names)
        }

        return ACPInitializeResult(
            connectedProtocol: connectedProtocol,
            agentInfo: agentInfo,
            authMethods: authMethods,
            currentModeId: currentModeId,
            userAgent: userAgent,
            promptCapabilitiesDeclared: promptCapabilitiesDeclared,
            gateway: gateway
        )
    }

    private static func makeCodexAgentInfo(userAgent: String) -> AgentProfile {
        var capabilities = AgentCapabilityState()
        capabilities.loadSession = false
        capabilities.resumeSession = false
        capabilities.listSessions = true
        capabilities.sessionListRequiresCwd = false
        capabilities.promptCapabilities = PromptCapabilityState()

        // Extract version from userAgent string (e.g., "codex/1.0.0" -> "1.0.0")
        let version = parseCodexVersion(from: userAgent)

        return AgentProfile(
            id: nil,
            name: "codex-app-server",
            title: "Codex app-server",
            version: version,
            description: userAgent,
            modes: [],
            capabilities: capabilities,
            verifications: []
        )
    }
    
    private static func parseCodexVersion(from userAgent: String) -> String? {
        // Expected format: "codex/1.0.0" or similar
        let components = userAgent.split(separator: "/")
        guard components.count == 2 else { return nil }
        let versionString = String(components[1])
        return versionString.isEmpty ? nil : versionString
    }
}