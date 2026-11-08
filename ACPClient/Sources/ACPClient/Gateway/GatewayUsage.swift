import Foundation
import ACP

// The context and cost figures of one session (contract C1, D-093). The gateway stores the last
// `usage_update` Bob sent for each session and returns it as an optional `usage` object on each row of
// `_acpcode/sessions/index`. ACPCode never estimates these numbers: each one is a number Bob sent.

/// Context and cost figures for one session.
public struct GatewayUsage: Equatable, Hashable, Sendable {
    /// Tokens in the context window, as Bob reported them.
    public let used: Int
    /// The context window size in tokens, as Bob reported it. Zero means no usable size.
    public let size: Int
    /// Cumulative session cost, only when Bob sent one. Never computed by the app.
    public let costAmount: Double?
    /// The currency of `costAmount`, only when Bob sent one.
    public let costCurrency: String?
    /// When the figures were stored: the gateway's time for a stored value, or the time this device
    /// received a live update.
    public let updatedAt: Date

    public init(used: Int, size: Int, costAmount: Double? = nil, costCurrency: String? = nil, updatedAt: Date) {
        self.used = used
        self.size = size
        self.costAmount = costAmount
        self.costCurrency = costCurrency
        self.updatedAt = updatedAt
    }

    /// Tokens left in the window (`size - used`, never below zero). Nil unless the size is known.
    public var left: Int? {
        size > 0 ? max(0, size - used) : nil
    }

    /// The share of the window in use, as a fraction. Nil unless the size is known. Bob can report
    /// more than the window, so this is not capped here.
    public var percent: Double? {
        size > 0 ? Double(used) / Double(size) : nil
    }

    /// Decodes the optional `usage` object of one sessions index row. Anything malformed gives nil, so a
    /// bad object never hides its session. Required: `used` and `size` as non-negative integers, and
    /// `updatedAt` as an RFC 3339 time. A malformed cost is dropped and the rest is kept. A currency
    /// is kept only when it is a short, non-empty text.
    public init?(gatewayValue value: ACP.Value?) {
        guard let object = value?.objectValue,
              let used = object["used"]?.intValue, used >= 0,
              let size = object["size"]?.intValue, size >= 0,
              let stamp = object["updatedAt"]?.stringValue,
              let updatedAt = Self.parseTimestamp(stamp) else { return nil }
        var amount = object["costAmount"]?.numberValue
        if let value = amount, !value.isFinite { amount = nil }
        var currency = object["costCurrency"]?.stringValue
        if let text = currency, text.isEmpty || text.count > 8 { currency = nil }
        if amount == nil { currency = nil }
        self.init(used: used, size: size, costAmount: amount, costCurrency: currency, updatedAt: updatedAt)
    }

    /// Figures from a live ACP `usage_update`, stamped with the time this device received them. Nil
    /// unless Bob sent both the used tokens and the window size.
    public init?(live usage: ACPSessionUsage, updatedAt: Date) {
        guard let used = usage.usedTokens, let size = usage.contextSize else { return nil }
        let amount = usage.costAmount
        self.init(used: used, size: size, costAmount: amount,
                  costCurrency: amount == nil ? nil : usage.costCurrency, updatedAt: updatedAt)
    }

    /// RFC 3339 with or without fractional seconds (the gateway writes milliseconds).
    private static func parseTimestamp(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}
