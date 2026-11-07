import Foundation
import Testing
import ACPClient
@testable import Agmente

/// D-093: the header chip's text, the home row's bar, and the number words the usage UI uses.
struct UsageChipTests {
    private let stamp = Date(timeIntervalSince1970: 1_000)

    private func usage(used: Int, size: Int, cost: Double? = nil, currency: String? = nil) -> GatewayUsage {
        GatewayUsage(used: used, size: size, costAmount: cost, costCurrency: currency, updatedAt: stamp)
    }

    // MARK: - Chip text

    @Test func chipShowsPercentAndTokensLeftWhenTheSizeIsKnown() {
        // 116k of 200k used: 42% used, 84k left.
        #expect(ContextUsageFormat.chipText(usage(used: 116_000, size: 200_000)) == "58%, 84k left")
        #expect(ContextUsageFormat.chipText(usage(used: 84_000, size: 200_000)) == "42%, 116k left")
    }

    @Test func chipSaysNotReportedWhenBobSentNoFigures() {
        #expect(ContextUsageFormat.chipText(nil) == "Context: not reported by Bob")
    }

    @Test func chipShowsOnlyTheUsedTokensWhenTheSizeIsZero() {
        #expect(ContextUsageFormat.chipText(usage(used: 12_000, size: 0)) == "12k used")
    }

    @Test func chipNeverShowsNegativeLeft() {
        #expect(ContextUsageFormat.chipText(usage(used: 250_000, size: 200_000)) == "125%, 0 left")
    }

    @Test func liveUsageFromTheSessionMakesTheChipText() throws {
        let live = ACPSessionUsage(usedTokens: 116_000, contextSize: 200_000)
        let figures = try #require(GatewayUsage(live: live, updatedAt: stamp))
        #expect(ContextUsageFormat.chipText(figures) == "58%, 84k left")
        #expect(ContextUsageFormat.chipText(GatewayUsage(live: ACPSessionUsage(costAmount: 1), updatedAt: stamp)) == "Context: not reported by Bob")
    }

    // MARK: - Home row bar

    @Test func barShowsOnlyWhenTheSizeIsKnown() {
        #expect(ContextUsageFormat.barFraction(usage(used: 50, size: 200)) == 0.25)
        #expect(ContextUsageFormat.barFraction(usage(used: 50, size: 0)) == nil)
        #expect(ContextUsageFormat.barFraction(nil) == nil)
    }

    @Test func barIsCappedBetweenEmptyAndFull() {
        #expect(ContextUsageFormat.barFraction(usage(used: 300, size: 200)) == 1)
    }

    // MARK: - Number words

    @Test func compactCountsUseAShortUnit() {
        #expect(ContextUsageFormat.compact(0) == "0")
        #expect(ContextUsageFormat.compact(950) == "950")
        #expect(ContextUsageFormat.compact(1_000) == "1k")
        #expect(ContextUsageFormat.compact(1_234) == "1.2k")
        #expect(ContextUsageFormat.compact(9_999) == "10k")
        #expect(ContextUsageFormat.compact(84_000) == "84k")
        #expect(ContextUsageFormat.compact(999_400) == "999k")
        #expect(ContextUsageFormat.compact(999_600) == "1m")
        #expect(ContextUsageFormat.compact(1_234_567) == "1.2m")
        #expect(ContextUsageFormat.compact(12_000_000) == "12m")
        #expect(ContextUsageFormat.compact(-5) == "0")
    }

    @Test func percentRoundsToAWholeNumber() {
        #expect(ContextUsageFormat.percentText(0.4249) == "42%")
        #expect(ContextUsageFormat.percentText(0.4251) == "43%")
    }

    @Test func costShowsItsCurrencyOnlyWhenBobSentOne() {
        #expect(ContextUsageFormat.cost(amount: 1.25, currency: "USD") == "1.25 USD")
        #expect(ContextUsageFormat.cost(amount: 1.25, currency: nil) == "1.25")
        #expect(ContextUsageFormat.cost(amount: 1.25, currency: "") == "1.25")
    }
}
