import XCTest
import ACP
@testable import ACPClient

private final class UsageFakeGateway: GatewayCalling, @unchecked Sendable {
    var calls: [(method: String, params: ACP.Value?)] = []
    var results: [String: ACP.Value] = [:]

    func gatewayCall(method: String, params: ACP.Value?) async throws -> ACP.Value {
        calls.append((method, params))
        return results[method] ?? .null
    }
}

final class GatewayUsageDecodingTests: XCTestCase {
    private let stamp = "2026-11-06T08:08:11.638Z"

    private func row(_ id: String, usage: ACP.Value?) -> ACP.Value {
        var object: [String: ACP.Value] = [
            "sessionId": .string(id), "projectId": .string("a1"), "title": .string("Fix \(id)"),
            "status": .string("idle"), "lastActivity": .string(stamp), "headSeq": .number(12), "unread": .number(0),
        ]
        if let usage { object["usage"] = usage }
        return .object(object)
    }

    private func usageObject(extra: [String: ACP.Value] = [:]) -> ACP.Value {
        var object: [String: ACP.Value] = ["used": .number(116_000), "size": .number(200_000), "updatedAt": .string(stamp)]
        for (key, value) in extra { object[key] = value }
        return .object(object)
    }

    private func index(_ rows: [ACP.Value]) async throws -> GatewaySessionsWithUsage {
        let fake = UsageFakeGateway()
        fake.results["_agmente/sessions/index"] = .object(["sessions": .array(rows)])
        return try await GatewayClient(fake).sessionsWithUsage()
    }

    // MARK: - The sessions index

    func testRowsWithUsageDecodeAndRowsWithoutItAreAbsent() async throws {
        let result = try await index([row("s1", usage: usageObject()), row("s2", usage: nil)])
        XCTAssertEqual(result.sessions.map(\.sessionId), ["s1", "s2"])
        XCTAssertEqual(Set(result.usage.keys), ["s1"])
        let usage = try XCTUnwrap(result.usage["s1"])
        XCTAssertEqual(usage.used, 116_000)
        XCTAssertEqual(usage.size, 200_000)
        XCTAssertNil(usage.costAmount)
        XCTAssertNil(usage.costCurrency)
        XCTAssertEqual(usage.updatedAt, GatewayUsage(gatewayValue: usageObject())?.updatedAt)
    }

    func testCostIsKeptWhenBobSentItAndCurrencyWithIt() async throws {
        let withCost = usageObject(extra: ["costAmount": .number(1.25), "costCurrency": .string("USD")])
        let result = try await index([row("s1", usage: withCost)])
        XCTAssertEqual(result.usage["s1"]?.costAmount, 1.25)
        XCTAssertEqual(result.usage["s1"]?.costCurrency, "USD")
    }

    func testCostWithoutCurrencyKeepsTheAmountAndAnAmountlessCostDropsTheCurrency() {
        let amountOnly = GatewayUsage(gatewayValue: usageObject(extra: ["costAmount": .number(0.5)]))
        XCTAssertEqual(amountOnly?.costAmount, 0.5)
        XCTAssertNil(amountOnly?.costCurrency)
        let currencyOnly = GatewayUsage(gatewayValue: usageObject(extra: ["costCurrency": .string("USD")]))
        XCTAssertNil(currencyOnly?.costAmount)
        XCTAssertNil(currencyOnly?.costCurrency)
    }

    func testMalformedUsageIsIgnoredAndTheSessionStillDecodes() async throws {
        let malformed: [ACP.Value] = [
            .string("oops"),
            .array([.number(1)]),
            .object(["size": .number(200_000), "updatedAt": .string(stamp)]),
            .object(["used": .string("116000"), "size": .number(200_000), "updatedAt": .string(stamp)]),
            .object(["used": .number(-1), "size": .number(200_000), "updatedAt": .string(stamp)]),
            .object(["used": .number(1), "size": .number(-200_000), "updatedAt": .string(stamp)]),
            .object(["used": .number(1), "size": .number(200_000)]),
            .object(["used": .number(1), "size": .number(200_000), "updatedAt": .string("yesterday")]),
            .null,
        ]
        let rows = malformed.enumerated().map { row("s\($0.offset)", usage: $0.element) }
        let result = try await index(rows)
        XCTAssertEqual(result.sessions.count, malformed.count)
        XCTAssertTrue(result.usage.isEmpty, "\(result.usage)")
    }

    func testAMalformedCostIsDroppedAndTheRestIsKept() {
        let usage = GatewayUsage(gatewayValue: usageObject(extra: ["costAmount": .string("1.25"), "costCurrency": .string("USD")]))
        XCTAssertEqual(usage?.used, 116_000)
        XCTAssertNil(usage?.costAmount)
        XCTAssertNil(usage?.costCurrency)
        let longCurrency = GatewayUsage(gatewayValue: usageObject(extra: ["costAmount": .number(2), "costCurrency": .string("NOT-A-CURRENCY")]))
        XCTAssertEqual(longCurrency?.costAmount, 2)
        XCTAssertNil(longCurrency?.costCurrency)
    }

    func testTimestampsWithAndWithoutMilliseconds() {
        let plain = GatewayUsage(gatewayValue: .object(["used": .number(1), "size": .number(10), "updatedAt": .string("2026-11-06T08:08:11Z")]))
        XCTAssertNotNil(plain)
        let withMillis = GatewayUsage(gatewayValue: .object(["used": .number(1), "size": .number(10), "updatedAt": .string("2026-11-06T08:08:11.638Z")]))
        XCTAssertNotNil(withMillis)
        XCTAssertEqual(withMillis!.updatedAt.timeIntervalSince(plain!.updatedAt), 0.638, accuracy: 0.001)
    }

    func testSessionsIndexStillSendsTheProjectFilter() async throws {
        let fake = UsageFakeGateway()
        fake.results["_agmente/sessions/index"] = .object(["sessions": .array([])])
        _ = try await GatewayClient(fake).sessionsWithUsage(projectId: "a1")
        XCTAssertEqual(fake.calls.map(\.method), ["_agmente/sessions/index"])
        XCTAssertEqual(fake.calls.first?.params, .object(["projectId": .string("a1")]))
    }

    // MARK: - Derived values

    func testLeftAndPercentAreShownOnlyWhenTheSizeIsKnown() {
        let known = GatewayUsage(used: 116_000, size: 200_000, updatedAt: Date())
        XCTAssertEqual(known.left, 84_000)
        XCTAssertEqual(try XCTUnwrap(known.percent), 0.58, accuracy: 0.0001)
        let unknown = GatewayUsage(used: 5, size: 0, updatedAt: Date())
        XCTAssertNil(unknown.left)
        XCTAssertNil(unknown.percent)
    }

    func testLeftNeverGoesBelowZeroWhenBobReportsMoreThanTheWindow() {
        let over = GatewayUsage(used: 250, size: 200, updatedAt: Date())
        XCTAssertEqual(over.left, 0)
        XCTAssertEqual(over.percent, 1.25)
    }

    // MARK: - Live updates

    func testLiveUsageNeedsBothUsedAndSize() {
        let stamp = Date(timeIntervalSince1970: 1_000)
        let full = GatewayUsage(live: ACPSessionUsage(usedTokens: 10, contextSize: 100, costAmount: 0.1, costCurrency: "USD"), updatedAt: stamp)
        XCTAssertEqual(full, GatewayUsage(used: 10, size: 100, costAmount: 0.1, costCurrency: "USD", updatedAt: stamp))
        XCTAssertNil(GatewayUsage(live: ACPSessionUsage(usedTokens: 10), updatedAt: stamp))
        XCTAssertNil(GatewayUsage(live: ACPSessionUsage(contextSize: 100), updatedAt: stamp))
        XCTAssertNil(GatewayUsage(live: ACPSessionUsage(costAmount: 0.1, costCurrency: "USD"), updatedAt: stamp))
    }

    func testLiveCurrencyIsDroppedWithoutAnAmount() {
        let stamp = Date(timeIntervalSince1970: 1_000)
        let usage = GatewayUsage(live: ACPSessionUsage(usedTokens: 10, contextSize: 100, costCurrency: "USD"), updatedAt: stamp)
        XCTAssertNil(usage?.costCurrency)
    }
}
