import Foundation

/// Lets an alert through at most once per `minimumInterval`, so approvals that arrive together make one sound.
struct ApprovalAlertGate {
    let minimumInterval: TimeInterval
    private var lastAllowed: Date?

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    mutating func allow(now: Date) -> Bool {
        if let lastAllowed, now.timeIntervalSince(lastAllowed) < minimumInterval {
            return false
        }
        lastAllowed = now
        return true
    }
}
