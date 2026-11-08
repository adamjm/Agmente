import Foundation

/// Limits how often a changing value reaches the screen (D-093): at most one shown value per
/// `interval`. A value that arrives inside the window waits, and the last value to arrive is the one
/// shown when the window ends, so the screen never lags behind the latest figure by more than one
/// interval. Pure: the caller passes the time, so the rules are tested without timers.
struct UsageUpdateThrottle<Value: Equatable> {
    let interval: TimeInterval
    /// The value shown most recently, or nil after `reset`.
    private(set) var shown: Value?
    /// The value that waits for the window to end, or nil.
    private(set) var pending: Value?
    private var lastShownAt: Date?

    init(interval: TimeInterval = 1) {
        self.interval = interval
    }

    /// When the waiting value should be shown, or nil when nothing waits.
    var pendingDeadline: Date? {
        guard pending != nil, let lastShownAt else { return nil }
        return lastShownAt.addingTimeInterval(interval)
    }

    /// Offers a value at `now`. Returns it when it may be shown at once; nil when it waits for `flush`.
    mutating func offer(_ value: Value, at now: Date) -> Value? {
        guard let lastShownAt, now.timeIntervalSince(lastShownAt) < interval else {
            return show(value, at: now)
        }
        pending = value
        return nil
    }

    /// Shows the waiting value once the window has ended. Returns it, or nil when nothing waits or the
    /// window has not ended yet.
    mutating func flush(at now: Date) -> Value? {
        guard let value = pending, let lastShownAt,
              now.timeIntervalSince(lastShownAt) >= interval else { return nil }
        return show(value, at: now)
    }

    /// Forgets the window and any waiting value (no usage, or another session): the next value shows at once.
    mutating func reset() {
        pending = nil
        lastShownAt = nil
        shown = nil
    }

    private mutating func show(_ value: Value, at now: Date) -> Value {
        pending = nil
        lastShownAt = now
        shown = value
        return value
    }
}
