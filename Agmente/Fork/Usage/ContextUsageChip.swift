import SwiftUI
import ACPClient

/// The live usage a session shows, updated at most once a second (D-093). The last value received is
/// the one shown when the window ends. Only Bob's figures are kept: nothing is estimated.
@MainActor
final class ContextUsageFeed: ObservableObject {
    @Published private(set) var shown: GatewayUsage?
    private var throttle = UsageUpdateThrottle<GatewayUsage>(interval: 1)
    private var flushTask: Task<Void, Never>?
    private let now: () -> Date

    init(initial: ACPSessionUsage?, now: @escaping () -> Date = Date.init) {
        self.now = now
        receive(initial)
    }

    /// Takes Bob's latest figures for the session, or nil when Bob has sent none.
    func receive(_ live: ACPSessionUsage?) {
        let time = now()
        guard let live, let figures = GatewayUsage(live: live, updatedAt: time) else {
            flushTask?.cancel()
            flushTask = nil
            throttle.reset()
            shown = nil
            return
        }
        if let value = throttle.offer(figures, at: time) {
            shown = value
        } else {
            scheduleFlush()
        }
    }

    private func scheduleFlush() {
        guard flushTask == nil, let deadline = throttle.pendingDeadline else { return }
        let delay = max(0.05, deadline.timeIntervalSince(now()))
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            if let value = self.throttle.flush(at: self.now()) {
                self.shown = value
            } else {
                self.scheduleFlush()
            }
        }
    }
}

/// The context chip above a session's transcript: "42%, 84k left", or "Context: not reported by Bob".
/// Tapping it opens the usage sheet (D-093).
struct ContextUsageChip: View {
    let usage: ACPSessionUsage?
    @StateObject private var feed: ContextUsageFeed
    @State private var showingSheet = false

    init(usage: ACPSessionUsage?) {
        self.usage = usage
        _feed = StateObject(wrappedValue: ContextUsageFeed(initial: usage))
    }

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Button {
                showingSheet = true
            } label: {
                Text(ContextUsageFormat.chipText(feed.shown))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.quaternary))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sessionContextChip")
            .accessibilityHint("Shows the context and cost figures Bob reported")
        }
        .padding(.horizontal, 16)
        .onChange(of: usage) { _, newValue in
            feed.receive(newValue)
        }
        .sheet(isPresented: $showingSheet) {
            GatewayUsageSheet(usage: feed.shown)
                .presentationDetents([.medium, .large])
        }
    }
}
