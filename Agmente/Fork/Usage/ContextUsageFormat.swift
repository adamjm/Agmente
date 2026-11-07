import Foundation
import ACPClient

/// The words and numbers of the context usage UI (D-093). Pure, so the text is tested without a view.
enum ContextUsageFormat {
    static let notReported = "Context: not reported by Bob"

    /// The header chip's text: "42%, 84k left" when the size is known, "12k used" when only the used
    /// tokens are known (size zero), and "Context: not reported by Bob" when there are no figures.
    static func chipText(_ usage: GatewayUsage?) -> String {
        guard let usage else { return notReported }
        guard let left = usage.left, let percent = usage.percent else {
            return "\(compact(usage.used)) used"
        }
        return "\(percentText(percent)), \(compact(left)) left"
    }

    /// The fill of the home row's thin bar, from 0 to 1. Nil when the size is unknown, so no bar shows.
    static func barFraction(_ usage: GatewayUsage?) -> Double? {
        guard let percent = usage?.percent else { return nil }
        return min(1, max(0, percent))
    }

    /// "42%". Rounded to a whole percent.
    static func percentText(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// A token count in short form: "950", "1.2k", "84k", "1.2m", "12m".
    static func compact(_ count: Int) -> String {
        let n = max(0, count)
        if n < 1_000 { return "\(n)" }
        if n < 10_000 { return tenths(n, unit: 1_000, suffix: "k") }
        if n < 999_500 { return "\((n + 500) / 1_000)k" }
        if n < 10_000_000 { return tenths(n, unit: 1_000_000, suffix: "m") }
        return "\((n + 500_000) / 1_000_000)m"
    }

    /// A count with its unit, for the usage sheet: "116,000 tokens".
    static func tokens(_ count: Int) -> String {
        "\(max(0, count).formatted()) tokens"
    }

    /// The cost with its currency when Bob sent one: "1.25 USD". Without a currency, the amount alone.
    static func cost(amount: Double, currency: String?) -> String {
        let value = amount.formatted(.number.precision(.fractionLength(2)))
        guard let currency, !currency.isEmpty else { return value }
        return "\(value) \(currency)"
    }

    /// One decimal place, with the trailing ".0" dropped, for counts under ten units.
    private static func tenths(_ n: Int, unit: Int, suffix: String) -> String {
        let rounded = (n * 10 + unit / 2) / unit
        let whole = rounded / 10
        let fraction = rounded % 10
        return fraction == 0 ? "\(whole)\(suffix)" : "\(whole).\(fraction)\(suffix)"
    }
}
