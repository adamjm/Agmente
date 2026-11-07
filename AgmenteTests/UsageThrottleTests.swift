import Foundation
import Testing
import ACPClient
@testable import Agmente

/// D-093: at most one usage update shown per second per session, the last value wins, and the clock
/// is passed in, so no test waits for a timer.
struct UsageThrottleTests {
    private let start = Date(timeIntervalSince1970: 10_000)

    private func at(_ seconds: Double) -> Date {
        start.addingTimeInterval(seconds)
    }

    @Test func firstValueShowsAtOnce() {
        var throttle = UsageUpdateThrottle<Int>(interval: 1)
        #expect(throttle.offer(1, at: at(0)) == 1)
        #expect(throttle.shown == 1)
        #expect(throttle.pending == nil)
    }

    @Test func aValueInsideTheWindowWaitsAndIsNotShown() {
        var throttle = UsageUpdateThrottle<Int>(interval: 1)
        _ = throttle.offer(1, at: at(0))
        #expect(throttle.offer(2, at: at(0.3)) == nil)
        #expect(throttle.shown == 1)
        #expect(throttle.pending == 2)
        #expect(throttle.pendingDeadline == at(1))
    }

    @Test func theLastValueInTheWindowIsTheOneShownWhenItEnds() {
        var throttle = UsageUpdateThrottle<Int>(interval: 1)
        _ = throttle.offer(1, at: at(0))
        _ = throttle.offer(2, at: at(0.2))
        _ = throttle.offer(3, at: at(0.5))
        _ = throttle.offer(4, at: at(0.9))
        #expect(throttle.flush(at: at(0.99)) == nil, "the window has not ended")
        #expect(throttle.flush(at: at(1)) == 4, "the last value wins")
        #expect(throttle.shown == 4)
        #expect(throttle.pending == nil)
    }

    @Test func aValueAfterTheWindowShowsAtOnce() {
        var throttle = UsageUpdateThrottle<Int>(interval: 1)
        _ = throttle.offer(1, at: at(0))
        #expect(throttle.offer(2, at: at(1.5)) == 2)
        #expect(throttle.pending == nil)
    }

    @Test func atMostOneShownValuePerSecondOverABurst() {
        var throttle = UsageUpdateThrottle<Int>(interval: 1)
        var shownTimes: [Double] = []
        // A burst of 100 updates, one every 20 ms, over 2 seconds.
        for step in 0..<100 {
            let time = Double(step) * 0.02
            if throttle.flush(at: at(time)) != nil { shownTimes.append(time) }
            if throttle.offer(step, at: at(time)) != nil { shownTimes.append(time) }
        }
        if throttle.flush(at: at(2.5)) != nil { shownTimes.append(2.5) }
        #expect(shownTimes.count <= 4, "\(shownTimes)")
        for pair in zip(shownTimes, shownTimes.dropFirst()) {
            #expect(pair.1 - pair.0 >= 1, "\(pair)")
        }
        #expect(throttle.shown == 99, "the last value of the burst is shown")
    }

    @Test func resetShowsTheNextValueAtOnceAndDropsTheWaitingOne() {
        var throttle = UsageUpdateThrottle<Int>(interval: 1)
        _ = throttle.offer(1, at: at(0))
        _ = throttle.offer(2, at: at(0.1))
        throttle.reset()
        #expect(throttle.shown == nil)
        #expect(throttle.pending == nil)
        #expect(throttle.flush(at: at(5)) == nil)
        #expect(throttle.offer(3, at: at(0.2)) == 3)
    }
}

/// The chip's feed uses the same rules, with the clock passed in.
@MainActor
struct ContextUsageFeedTests {
    private let start = Date(timeIntervalSince1970: 20_000)

    private func figures(_ used: Int) -> ACPSessionUsage {
        ACPSessionUsage(usedTokens: used, contextSize: 200_000)
    }

    @Test func theFeedShowsTheFirstFigureAtOnceAndHoldsAFastSecondOne() {
        var now = start
        let feed = ContextUsageFeed(initial: nil, now: { now })
        #expect(feed.shown == nil)

        feed.receive(figures(10_000))
        #expect(feed.shown?.used == 10_000)

        now = start.addingTimeInterval(0.2)
        feed.receive(figures(20_000))
        #expect(feed.shown?.used == 10_000, "a second update inside the window waits")

        feed.receive(nil)
        #expect(feed.shown == nil, "no usage clears the chip at once")
    }

    @Test func theFeedStartsFromTheInitialFigures() {
        let feed = ContextUsageFeed(initial: figures(116_000), now: { self.start })
        #expect(ContextUsageFormat.chipText(feed.shown) == "58%, 84k left")
    }
}
