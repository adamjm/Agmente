import ActivityKit
import Foundation

/// The Live Activity for the open approvals of one gateway. The content state is the whole payload:
/// a count, a project name, the oldest approval's id and option ids, and the session link. It holds no
/// tool title and no command (NFR-11, D-038), and the initializer clamps every field so the state stays
/// far below ActivityKit's size limit.
public struct ApprovalActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        /// Open approvals on the selected gateway.
        public let pendingCount: Int
        /// The project of the oldest approval, for the card.
        public let projectName: String
        /// The oldest open approval. The Once and Deny intents answer this one.
        public let approvalId: String
        /// The option id of the offered `allow_once` option, or nil when the agent offered none.
        public let allowOnceOptionId: String?
        /// The option id of the offered `reject_once` option, or nil when the agent offered none.
        public let denyOptionId: String?
        /// The `acpcode://session/...` link for the Open button, or nil.
        public let openLink: String?

        public init(
            pendingCount: Int,
            projectName: String,
            approvalId: String,
            allowOnceOptionId: String?,
            denyOptionId: String?,
            openLink: String?
        ) {
            self.pendingCount = max(0, pendingCount)
            self.projectName = ApprovalActivityLimits.clamp(projectName, toBytes: ApprovalActivityLimits.maxProjectNameBytes)
            self.approvalId = ApprovalActivityLimits.clamp(approvalId, toBytes: ApprovalActivityLimits.maxIdBytes)
            self.allowOnceOptionId = Self.optionalId(allowOnceOptionId)
            self.denyOptionId = Self.optionalId(denyOptionId)
            self.openLink = Self.optionalLink(openLink)
        }

        private static func optionalId(_ value: String?) -> String? {
            guard let value else { return nil }
            let clamped = ApprovalActivityLimits.clamp(value, toBytes: ApprovalActivityLimits.maxIdBytes)
            return clamped.isEmpty ? nil : clamped
        }

        private static func optionalLink(_ value: String?) -> String? {
            guard let value else { return nil }
            let clamped = ApprovalActivityLimits.clamp(value, toBytes: ApprovalActivityLimits.maxLinkBytes)
            return clamped.isEmpty ? nil : clamped
        }
    }

    public init() {}
}

/// Size and text limits for the Live Activity content state.
public enum ApprovalActivityLimits {
    public static let maxProjectNameBytes = 120
    public static let maxIdBytes = 200
    public static let maxLinkBytes = 400
    /// The content state must stay under this many bytes (about 4 KB; ActivityKit limit, verify on device).
    public static let maxEncodedBytes = 4_096

    /// The longest prefix of `text`, in UTF-8 bytes, with control characters removed. Control characters
    /// are removed so that JSON escaping cannot grow the encoded state past the limit.
    public static func clamp(_ text: String, toBytes limit: Int) -> String {
        var result = ""
        var used = 0
        for character in text where !character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            let size = String(character).utf8.count
            if used + size > limit { break }
            used += size
            result.append(character)
        }
        return result
    }
}
