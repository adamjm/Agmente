import Foundation
import ACPClient

/// Plan, title and usage of one session, from its `session/update` events (FR-33). Pure state, so the
/// rules are unit-tested without a view model.
struct ForkSessionMeta: Equatable {
    /// The current plan, or nil when there is none (never shown when empty).
    private(set) var plan: [ACPPlanEntry]?
    /// The session title from `session_info_update`, or nil.
    private(set) var title: String?
    /// The latest usage figures, or nil.
    private(set) var usage: ACPSessionUsage?

    /// Applies one event. Returns true when the event was one of the four kinds this type handles.
    @discardableResult
    mutating func apply(_ event: ACPSessionUpdateEvent) -> Bool {
        switch event {
        case .planUpdate(let entries):
            plan = entries.isEmpty ? nil : entries
            return true
        case .planRemoved:
            plan = nil
            return true
        case .sessionInfo(let newTitle):
            // A title the agent sends empty leaves the last one in place.
            if let newTitle, !newTitle.isEmpty { title = newTitle }
            return true
        case .usage(let newUsage):
            usage = newUsage
            return true
        default:
            return false
        }
    }
}

/// Which status a plan row shows, from its ACP status.
enum ForkPlanRowState: Equatable {
    case pending
    case inProgress
    case completed

    init(_ status: ACPPlanEntry.Status) {
        switch status {
        case .inProgress: self = .inProgress
        case .completed: self = .completed
        case .pending, .unknown: self = .pending
        }
    }
}

/// The text of the usage footer. Nil when there is nothing to show.
enum ForkUsageFormat {
    static func line(_ usage: ACPSessionUsage?) -> String? {
        guard let usage, !usage.isEmpty else { return nil }
        var parts: [String] = []
        if let used = usage.usedTokens {
            if let size = usage.contextSize, size > 0 {
                parts.append("\(used.formatted()) of \(size.formatted()) tokens")
            } else {
                parts.append("\(used.formatted()) tokens")
            }
        }
        if let amount = usage.costAmount {
            let value = amount.formatted(.number.precision(.fractionLength(2)))
            if let currency = usage.costCurrency, !currency.isEmpty {
                parts.append("\(value) \(currency)")
            } else {
                parts.append(value)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
