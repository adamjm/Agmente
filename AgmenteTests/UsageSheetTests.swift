import Foundation
import Testing
import ACPClient
@testable import Agmente

/// D-093: what the usage sheet shows for a reported session, a session with cost, a session with no
/// window size, and a session Bob has not reported on. The balance row is always the same.
struct UsageSheetTests {
    private let stamp = Date(timeIntervalSince1970: 1_000)

    private func labels(_ content: UsageSheetContent) -> [String] {
        content.rows.map(\.label)
    }

    @Test func reportedSessionShowsUsedSizeLeftAndPercent() {
        let content = UsageSheetContent(usage: GatewayUsage(used: 116_000, size: 200_000, updatedAt: stamp))
        #expect(content.reported)
        #expect(labels(content) == ["Used", "Size", "Left", "Percent used"])
        #expect(content.rows.map(\.value) == ["116,000 tokens", "200,000 tokens", "84,000 tokens", "58%"])
        #expect(content.note == nil)
    }

    @Test func costAppearsOnlyWhenBobSentIt() {
        let withCost = UsageSheetContent(usage: GatewayUsage(used: 1, size: 10, costAmount: 0.42, costCurrency: "USD", updatedAt: stamp))
        #expect(withCost.cost == UsageSheetContent.Row(label: "session cost (cumulative)", value: "0.42 USD"))
        let withoutCost = UsageSheetContent(usage: GatewayUsage(used: 1, size: 10, updatedAt: stamp))
        #expect(withoutCost.cost == nil)
    }

    @Test func costWithoutCurrencyShowsTheAmountOnly() {
        let content = UsageSheetContent(usage: GatewayUsage(used: 1, size: 10, costAmount: 0.42, updatedAt: stamp))
        #expect(content.cost?.value == "0.42")
    }

    @Test func zeroSizeHidesLeftAndPercentAndSaysWhy() {
        let content = UsageSheetContent(usage: GatewayUsage(used: 12, size: 0, updatedAt: stamp))
        #expect(content.reported)
        #expect(labels(content) == ["Used"])
        #expect(content.note != nil)
    }

    @Test func notReportedSessionShowsNoFiguresAndNoSource() {
        let content = UsageSheetContent(usage: nil)
        #expect(!content.reported)
        #expect(content.rows.isEmpty)
        #expect(content.cost == nil)
        #expect(content.lastUpdated == nil)
        #expect(content.note?.contains("not reported") == true)
    }

    @Test func lastUpdatedComesFromTheStoredTime() {
        let content = UsageSheetContent(usage: GatewayUsage(used: 1, size: 10, updatedAt: stamp))
        #expect(content.lastUpdated == stamp.formatted(date: .abbreviated, time: .shortened))
    }

    @Test func sourceLineNamesBobAndTheACPUpdate() {
        #expect(UsageSheetContent.sourceLine == "Reported by Bob (ACP usage_update)")
    }

    @Test func balanceIsAlwaysNotAvailableNeverANumber() {
        #expect(UsageSheetContent.balanceLabel == "Bob balance")
        #expect(UsageSheetContent.balanceValue == "not available from Bob")
        // The balance is never a figure: no row carries a currency or a number from Bob's balance.
        for usage in [GatewayUsage(used: 1, size: 10, updatedAt: stamp), nil] {
            let content = UsageSheetContent(usage: usage)
            #expect(!content.rows.contains { $0.label.localizedCaseInsensitiveContains("balance") })
        }
    }
}
