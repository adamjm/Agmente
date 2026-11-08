import SwiftUI
import ACPClient

/// What the usage sheet shows, as data, so its rules are tested without a view (D-093). It never
/// shows an estimate, and never a balance: Bob does not report one over ACP.
struct UsageSheetContent: Equatable {
    struct Row: Equatable, Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    static let costLabel = "session cost (cumulative)"
    static let sourceLine = "Reported by Bob (ACP usage_update)"
    static let balanceLabel = "Bob balance"
    static let balanceValue = "not available from Bob"
    static let balanceExplanation = "Bob does not send an account balance over ACP. ACP Code does not show one or estimate one."

    /// False when Bob has sent no figures for the session.
    let reported: Bool
    /// Used, Size, Left and Percent used. Left and percent need a known size. Empty when not reported.
    let rows: [Row]
    /// The cumulative session cost, only when Bob sent one.
    let cost: Row?
    /// When the figures were stored or received, or nil when not reported.
    let lastUpdated: String?
    /// A plain sentence for the person when some figure is missing.
    let note: String?

    init(usage: GatewayUsage?) {
        guard let usage else {
            reported = false
            rows = []
            cost = nil
            lastUpdated = nil
            note = "Bob has not reported context usage for this session yet. ACP Code shows only the figures Bob sends."
            return
        }
        reported = true
        var rows = [Row(label: "Used", value: ContextUsageFormat.tokens(usage.used))]
        if usage.size > 0 {
            rows.append(Row(label: "Size", value: ContextUsageFormat.tokens(usage.size)))
            if let left = usage.left {
                rows.append(Row(label: "Left", value: ContextUsageFormat.tokens(left)))
            }
            if let percent = usage.percent {
                rows.append(Row(label: "Percent used", value: ContextUsageFormat.percentText(percent)))
            }
            note = nil
        } else {
            note = "Bob did not send the window size, so the size, left and percent are not shown."
        }
        self.rows = rows
        if let amount = usage.costAmount {
            cost = Row(label: Self.costLabel, value: ContextUsageFormat.cost(amount: amount, currency: usage.costCurrency))
        } else {
            cost = nil
        }
        lastUpdated = usage.updatedAt.formatted(date: .abbreviated, time: .shortened)
    }
}

/// The sheet opened from the context chip (D-093).
struct GatewayUsageSheet: View {
    let usage: GatewayUsage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let content = UsageSheetContent(usage: usage)
        NavigationStack {
            List {
                Section {
                    ForEach(content.rows) { row in
                        LabeledContent(row.label, value: row.value)
                    }
                    if let note = content.note {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Context")
                }
                if let cost = content.cost {
                    Section {
                        LabeledContent(cost.label, value: cost.value)
                    } header: {
                        Text("Cost")
                    }
                }
                if let lastUpdated = content.lastUpdated {
                    Section {
                        LabeledContent("Last updated", value: lastUpdated)
                        if content.reported {
                            Text(UsageSheetContent.sourceLine)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("usageSheetSource")
                        }
                    } header: {
                        Text("Source")
                    }
                }
                Section {
                    LabeledContent(UsageSheetContent.balanceLabel, value: UsageSheetContent.balanceValue)
                        .accessibilityIdentifier("usageSheetBalance")
                } footer: {
                    Text(UsageSheetContent.balanceExplanation)
                }
            }
            .navigationTitle("Context usage")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .accessibilityIdentifier("usageSheet")
        }
    }
}
