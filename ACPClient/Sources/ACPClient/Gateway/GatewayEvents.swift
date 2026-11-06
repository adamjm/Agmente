import Foundation
import ACP

/// One `_agmente/event` notification: a logged event of a session, with its sequence number
/// (D-028). `message` is the logged JSON-RPC message exactly as the gateway stored it (D-027).
public struct GatewayEvent: Equatable, Sendable {
    public let sessionId: String
    public let seq: Int
    public let message: ACP.Value

    public init(sessionId: String, seq: Int, message: ACP.Value) {
        self.sessionId = sessionId
        self.seq = seq
        self.message = message
    }

    public static let method = "_agmente/event"

    /// Reads the params of an `_agmente/event` notification, or nil when they are not in that shape.
    public static func parse(_ params: ACP.Value?) -> GatewayEvent? {
        guard let object = params?.objectValue,
              let sessionId = object["sessionId"]?.stringValue,
              let seq = object["seq"]?.intValue, seq >= 1,
              let message = object["message"], message.objectValue != nil else { return nil }
        return GatewayEvent(sessionId: sessionId, seq: seq, message: message)
    }

    /// What the app should do with this event.
    public var action: GatewayEventAction {
        let object = message.objectValue ?? [:]
        let method = object["method"]?.stringValue ?? ""
        let params = object["params"] ?? .null
        switch method {
        case "session/update":
            return .sessionUpdate(params)
        case "session/request_permission":
            guard let idValue = object["id"], let id = Self.requestID(idValue) else { return .other(method: method) }
            return .permissionRequest(ACP.AnyRequest(id: id, method: method, params: params))
        case "_agmente/turn_started":
            // Bob does not echo the user's message while a turn runs, so the gateway logs it here.
            // Each block becomes a user_message_chunk, as the gateway itself replays it (D-029).
            let blocks = params.objectValue?["prompt"]?.arrayValue ?? []
            let updates: [ACP.Value] = blocks.map { block in
                .object([
                    "sessionId": .string(sessionId),
                    "update": .object(["sessionUpdate": .string("user_message_chunk"), "content": block]),
                ])
            }
            return .userPrompt(updates)
        case "_agmente/turn_ended":
            let fields = params.objectValue ?? [:]
            return .turnEnded(stopReason: fields["stopReason"]?.stringValue,
                              error: fields["error"]?.objectValue?["message"]?.stringValue)
        case "_agmente/approval_answered":
            guard let approvalId = params.objectValue?["approvalId"]?.stringValue else { return .other(method: method) }
            return .approvalAnswered(approvalId: approvalId)
        default:
            return .other(method: method)
        }
    }

    private static func requestID(_ value: ACP.Value) -> ACP.ID? {
        switch value {
        case .string(let text): return .string(text)
        case .int(let number): return .number(number)
        default: return nil
        }
    }
}

public enum GatewayEventAction: Equatable, Sendable {
    /// The params of a `session/update` notification.
    case sessionUpdate(ACP.Value)
    /// The user's prompt, as `session/update` params with one `user_message_chunk` per content block.
    case userPrompt([ACP.Value])
    /// A permission request under the gateway's id; the answer is a plain response to that id (D-026).
    case permissionRequest(ACP.AnyRequest)
    /// The turn ended: the agent's stop reason, or the error text (for example "agent exited").
    case turnEnded(stopReason: String?, error: String?)
    /// A permission request was answered, by a device, a timeout or a cancel (D-031).
    case approvalAnswered(approvalId: String)
    /// Anything else, kept so the log can say what it was.
    case other(method: String)
}

/// Orders the events of one session for the app: each is applied once, in `seq` order, and a repeat
/// or an old one is dropped (a replay and live events can overlap after a resubscribe).
public struct GatewaySequence: Equatable, Sendable {
    public private(set) var lastSeq: Int

    public init(lastSeq: Int = 0) {
        self.lastSeq = lastSeq
    }

    public enum Decision: Equatable, Sendable {
        case apply
        case duplicate
        /// Events `expected` to `seq - 1` are missing. The app resubscribes from `lastSeq`.
        case gap(expected: Int)
    }

    /// Decides what to do with an event and, when it is applied, moves `lastSeq` to it.
    public mutating func accept(_ seq: Int) -> Decision {
        if seq <= lastSeq { return .duplicate }
        if seq != lastSeq + 1 { return .gap(expected: lastSeq + 1) }
        lastSeq = seq
        return .apply
    }

    public mutating func reset() { lastSeq = 0 }
}
