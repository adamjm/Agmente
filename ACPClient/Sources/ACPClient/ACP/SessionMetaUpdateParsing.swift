import Foundation
import ACP

// FR-33: plan, session title and usage updates. Shapes are read defensively: ACP's `plan` update
// carries `entries` with `content` and `status`. Bob's `plan_update`, `plan_removed`, `usage_update`
// shapes are not in the ACP schema or the fixtures (verify against a live Bob), so every field
// is optional and an unknown shape gives an empty result rather than an error.

/// One item of an agent plan.
public struct ACPPlanEntry: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case pending
        case inProgress
        case completed
        /// A status this app does not know. It is shown as pending.
        case unknown(String)
    }

    public let content: String
    public let status: Status

    public init(content: String, status: Status) {
        self.content = content
        self.status = status
    }
}

/// Token and cost figures from a `usage_update`. Every field is optional.
public struct ACPSessionUsage: Equatable, Sendable {
    public let usedTokens: Int?
    public let contextSize: Int?
    public let costAmount: Double?
    public let costCurrency: String?

    public init(usedTokens: Int? = nil, contextSize: Int? = nil, costAmount: Double? = nil, costCurrency: String? = nil) {
        self.usedTokens = usedTokens
        self.contextSize = contextSize
        self.costAmount = costAmount
        self.costCurrency = costCurrency
    }

    public var isEmpty: Bool {
        usedTokens == nil && contextSize == nil && costAmount == nil
    }
}

public enum ACPSessionMetaUpdateParser {
    /// Plans are capped so a hostile agent cannot make the app lay out thousands of rows.
    public static let maxPlanEntries = 200

    /// Plan entries from a `plan` or `plan_update` payload. Looks at `entries`, then `plan`, `items`
    /// and `steps` (verify: Bob's own key). An element without any text is skipped.
    public static func planEntries(from update: [String: ACP.Value]) -> [ACPPlanEntry] {
        let list = [update["entries"], update["plan"], update["items"], update["steps"]]
            .compactMap { value -> [ACP.Value]? in
                if case let .array(items)? = value { return items }
                return nil
            }
            .first ?? []

        var entries: [ACPPlanEntry] = []
        for element in list.prefix(maxPlanEntries) {
            guard let object = element.objectValue,
                  let content = text(from: object), !content.isEmpty else { continue }
            entries.append(ACPPlanEntry(content: content, status: status(from: object["status"]?.stringValue)))
        }
        return entries
    }

    /// The session title from a `session_info_update`, trimmed. Nil when absent or empty.
    public static func sessionTitle(from update: [String: ACP.Value]) -> String? {
        guard let title = update["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        return title
    }

    /// Usage from a `usage_update`. Accepts `used` or `usedTokens`, `size` or `contextSize`, and a
    /// cost as `cost: {amount, currency}` or as `costAmount` and `costCurrency` (verify: Bob's keys).
    public static func usage(from update: [String: ACP.Value]) -> ACPSessionUsage {
        let used = int(update["used"]) ?? int(update["usedTokens"])
        let size = int(update["size"]) ?? int(update["contextSize"])
        var amount: Double?
        var currency: String?
        if let cost = update["cost"]?.objectValue {
            amount = cost["amount"]?.numberValue
            currency = cost["currency"]?.stringValue
        } else {
            amount = update["cost"]?.numberValue ?? update["costAmount"]?.numberValue
            currency = update["costCurrency"]?.stringValue
        }
        let safeCurrency: String? = (currency?.count ?? 0) > 8 ? nil : currency
        let safeAmount: Double? = (amount?.isFinite ?? false) ? amount : nil
        return ACPSessionUsage(usedTokens: used, contextSize: size, costAmount: safeAmount, costCurrency: safeCurrency)
    }

    private static func text(from object: [String: ACP.Value]) -> String? {
        if let text = object["content"]?.stringValue { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let text = object["content"]?.objectValue?["text"]?.stringValue { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        for key in ["title", "text", "description"] {
            if let text = object[key]?.stringValue { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return nil
    }

    private static func status(from raw: String?) -> ACPPlanEntry.Status {
        switch raw {
        case "pending", nil: return .pending
        case "in_progress": return .inProgress
        case "completed": return .completed
        case let other?: return .unknown(other)
        }
    }

    private static func int(_ value: ACP.Value?) -> Int? {
        guard let number = value?.numberValue, number.isFinite, number >= 0, number < 1e12 else { return nil }
        return Int(number)
    }
}
