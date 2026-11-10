import Foundation
import ACP

// MARK: - Session Response Models

/// Parsed result from a session/new or session/create response.
public struct ACPSessionNewResult: Sendable, Equatable {
    /// The server-assigned session ID.
    public let sessionId: String
    
    /// The working directory for this session, if returned by the server.
    public let cwd: String?
    
    /// Mode information if returned by the server.
    public let modes: ACPModesInfo?

    /// Session config options if returned by the server.
    public let configOptions: [ACPSessionConfigOption]

    /// Model information from the unstable `models` field, if returned by the server (verify: not in upstream schema).
    public let models: ACPSessionModelInfo?

    public init(
        sessionId: String,
        cwd: String? = nil,
        modes: ACPModesInfo? = nil,
        configOptions: [ACPSessionConfigOption] = [],
        models: ACPSessionModelInfo? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.modes = modes
        self.configOptions = configOptions
        self.models = models
    }
}

/// Parsed result from a session/load or session/resume response.
public struct ACPSessionLoadResult: Sendable, Equatable {
    /// The session ID (confirmed by server).
    public let sessionId: String
    
    /// The working directory for this session, if returned by the server.
    public let cwd: String?
    
    /// Mode information if returned by the server.
    public let modes: ACPModesInfo?

    /// Session config options if returned by the server.
    public let configOptions: [ACPSessionConfigOption]
    
    /// Chat history if returned by the server.
    public let history: [ACPHistoryMessage]?

    /// Model information from the unstable `models` field, if returned by the server (verify: not in upstream schema).
    public let models: ACPSessionModelInfo?

    public init(
        sessionId: String,
        cwd: String? = nil,
        modes: ACPModesInfo? = nil,
        configOptions: [ACPSessionConfigOption] = [],
        history: [ACPHistoryMessage]? = nil,
        models: ACPSessionModelInfo? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.modes = modes
        self.configOptions = configOptions
        self.history = history
        self.models = models
    }
}

/// A model the agent offers for a session (unstable `models.availableModels` entry, verify: not in upstream schema).
public struct AgentModelOption: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let description: String?

    public init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
}

/// Model information from a session response (unstable `models` object, verify: not in upstream schema).
public struct ACPSessionModelInfo: Sendable, Equatable {
    /// Models the agent offers for this session.
    public let availableModels: [AgentModelOption]

    /// The currently active model ID, as reported by the server. May not match an entry in `availableModels`.
    public let currentModelId: String?

    public init(availableModels: [AgentModelOption] = [], currentModelId: String? = nil) {
        self.availableModels = availableModels
        self.currentModelId = currentModelId
    }

    /// Whether this contains any meaningful model information.
    public var isEmpty: Bool {
        availableModels.isEmpty && currentModelId == nil
    }
}

/// Mode information from session responses.
public struct ACPModesInfo: Sendable, Equatable {
    /// Available modes for this session.
    public let availableModes: [AgentModeOption]
    
    /// The currently active mode ID.
    public let currentModeId: String?
    
    public init(availableModes: [AgentModeOption] = [], currentModeId: String? = nil) {
        self.availableModes = availableModes
        self.currentModeId = currentModeId
    }
    
    /// Whether this contains any meaningful mode information.
    public var isEmpty: Bool {
        availableModes.isEmpty && currentModeId == nil
    }
}

/// A message from chat history returned by session/load.
public struct ACPHistoryMessage: Sendable, Equatable {
    public enum Role: String, Sendable {
        case user
        case assistant
        case system
    }
    
    public let role: Role
    public let content: String
    public let timestamp: Date?
    
    public init(role: Role, content: String, timestamp: Date? = nil) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

/// Parsed result from a session/set_mode response.
public struct ACPSetModeResult: Sendable, Equatable {
    /// The new current mode ID.
    public let currentModeId: String
    
    public init(currentModeId: String) {
        self.currentModeId = currentModeId
    }
}

// MARK: - Session Response Parser

/// Parses session-related RPC responses (session/new, session/load, session/set_mode).
public enum ACPSessionResponseParser {
    
    // MARK: - Session New/Create
    
    /// Parse a session/new or session/create response.
    /// - Parameters:
    ///   - result: The result object from the JSON-RPC response.
    ///   - fallbackSessionId: A fallback session ID if not present in response.
    ///   - fallbackCwd: A fallback working directory if not present in response.
    /// - Returns: Parsed session result, or nil if no session ID could be determined.
    public static func parseSessionNew(
        result: ACP.Value?,
        fallbackSessionId: String? = nil,
        fallbackCwd: String? = nil
    ) -> ACPSessionNewResult? {
        let resultDict = result?.objectValue
        
        // Extract session ID with fallback chain
        let sessionId = resultDict?["sessionId"]?.stringValue
            ?? resultDict?["session"]?.stringValue
            ?? resultDict?["id"]?.stringValue
            ?? fallbackSessionId
        
        guard let sessionId, !sessionId.isEmpty else {
            return nil
        }
        
        // Extract working directory
        let cwd = resultDict?["cwd"]?.stringValue
            ?? resultDict?["workingDirectory"]?.stringValue
            ?? fallbackCwd
        
        // Parse modes
        let configOptions = ACPSessionConfigOptionParser.parse(from: resultDict)
        let modes = parseModes(from: resultDict) ?? ACPSessionConfigOptionParser.modeInfo(from: configOptions)
        let models = parseModels(from: resultDict)

        return ACPSessionNewResult(
            sessionId: sessionId,
            cwd: cwd,
            modes: modes,
            configOptions: configOptions,
            models: models
        )
    }
    
    // MARK: - Session Load/Resume
    
    /// Parse a session/load or session/resume response.
    /// - Parameters:
    ///   - result: The result object from the JSON-RPC response.
    ///   - requestedSessionId: The session ID that was requested.
    /// - Returns: Parsed session load result.
    public static func parseSessionLoad(
        result: ACP.Value?,
        requestedSessionId: String
    ) -> ACPSessionLoadResult {
        let resultDict = result?.objectValue
        
        // Session ID - prefer response, fall back to requested
        let sessionId = resultDict?["sessionId"]?.stringValue
            ?? resultDict?["session"]?.stringValue
            ?? resultDict?["id"]?.stringValue
            ?? requestedSessionId
        
        // Extract working directory
        let cwd = resultDict?["cwd"]?.stringValue
            ?? resultDict?["workingDirectory"]?.stringValue
        
        // Parse modes
        let configOptions = ACPSessionConfigOptionParser.parse(from: resultDict)
        let modes = parseModes(from: resultDict) ?? ACPSessionConfigOptionParser.modeInfo(from: configOptions)
        
        // Parse history if present
        let history = parseHistory(from: resultDict)

        let models = parseModels(from: resultDict)

        return ACPSessionLoadResult(
            sessionId: sessionId,
            cwd: cwd,
            modes: modes,
            configOptions: configOptions,
            history: history,
            models: models
        )
    }
    
    // MARK: - Session Set Mode
    
    /// Parse a session/set_mode response.
    /// - Parameter result: The result object from the JSON-RPC response.
    /// - Returns: Parsed set mode result, or nil if no mode ID found.
    public static func parseSetMode(result: ACP.Value?) -> ACPSetModeResult? {
        let resultDict = result?.objectValue
        
        let modeId = resultDict?["currentModeId"]?.stringValue
            ?? resultDict?["modeId"]?.stringValue
        
        guard let modeId else { return nil }
        
        return ACPSetModeResult(currentModeId: modeId)
    }

    public static func parseConfigOptions(result: ACP.Value?) -> [ACPSessionConfigOption] {
        ACPSessionConfigOptionParser.parse(from: result?.objectValue)
    }
    
    // MARK: - Helpers
    
    /// Parse modes information from a session response.
    public static func parseModes(from result: [String: ACP.Value]?) -> ACPModesInfo? {
        guard let result = result,
              let modesObj = result["modes"]?.objectValue else {
            return nil
        }
        
        // Parse available modes
        var modes: [AgentModeOption] = []
        if case let .array(availableModes)? = modesObj["availableModes"] {
            modes = availableModes.compactMap { modeValue -> AgentModeOption? in
                guard let modeObj = modeValue.objectValue,
                      let modeId = modeObj["id"]?.stringValue,
                      let modeName = modeObj["name"]?.stringValue else {
                    return nil
                }
                return AgentModeOption(
                    id: modeId,
                    name: modeName,
                    description: modeObj["description"]?.stringValue
                )
            }
        }
        
        // Get current mode ID
        let currentModeId = modesObj["currentModeId"]?.stringValue
        
        // Only return if we have some mode info
        if modes.isEmpty && currentModeId == nil {
            return nil
        }
        
        return ACPModesInfo(availableModes: modes, currentModeId: currentModeId)
    }
    
    /// Parse the unstable `models` object from a session response (verify: not in upstream schema).
    /// Entries without a string `modelId` or `name` are skipped.
    public static func parseModels(from result: [String: ACP.Value]?) -> ACPSessionModelInfo? {
        guard let result = result,
              let modelsObj = result["models"]?.objectValue else {
            return nil
        }

        var models: [AgentModelOption] = []
        if case let .array(availableModels)? = modelsObj["availableModels"] {
            models = availableModels.compactMap { modelValue -> AgentModelOption? in
                guard let modelObj = modelValue.objectValue,
                      let modelId = modelObj["modelId"]?.stringValue,
                      let modelName = modelObj["name"]?.stringValue else {
                    return nil
                }
                return AgentModelOption(
                    id: modelId,
                    name: modelName,
                    description: modelObj["description"]?.stringValue
                )
            }
        }

        let currentModelId = modelsObj["currentModelId"]?.stringValue

        if models.isEmpty && currentModelId == nil {
            return nil
        }

        return ACPSessionModelInfo(availableModels: models, currentModelId: currentModelId)
    }

    /// Parse chat history from a session/load response.
    private static func parseHistory(from result: [String: ACP.Value]?) -> [ACPHistoryMessage]? {
        guard let result = result,
              case let .array(historyArray)? = result["history"] ?? result["messages"] else {
            return nil
        }
        
        let messages = historyArray.compactMap { messageValue -> ACPHistoryMessage? in
            guard let msgObj = messageValue.objectValue,
                  let roleStr = msgObj["role"]?.stringValue,
                  let content = msgObj["content"]?.stringValue else {
                return nil
            }
            
            let role: ACPHistoryMessage.Role
            switch roleStr.lowercased() {
            case "user":
                role = .user
            case "assistant", "agent":
                role = .assistant
            case "system":
                role = .system
            default:
                role = .assistant
            }
            
            // Parse timestamp if present
            var timestamp: Date? = nil
            if let timestampStr = msgObj["timestamp"]?.stringValue {
                timestamp = ISO8601DateFormatter().date(from: timestampStr)
            } else if let timestampNum = msgObj["timestamp"]?.numberValue {
                timestamp = Date(timeIntervalSince1970: timestampNum)
            }
            
            return ACPHistoryMessage(role: role, content: content, timestamp: timestamp)
        }
        
        return messages.isEmpty ? nil : messages
    }
}
