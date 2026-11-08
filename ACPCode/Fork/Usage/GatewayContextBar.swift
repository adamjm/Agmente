import SwiftUI
import ACPClient

/// A thin bar along the foot of a gateway home row: how much of the context window Bob reports in use
/// (D-093). It shows only when the size is known, so an unknown session has no bar.
struct GatewayContextBar: View {
    let usage: GatewayUsage?

    var body: some View {
        if let fraction = ContextUsageFormat.barFraction(usage) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 3)
            .padding(.horizontal, 16)
            .padding(.bottom, 3)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Context \(ContextUsageFormat.percentText(fraction)) used")
            .accessibilityIdentifier("gatewayContextBar")
        }
    }
}
