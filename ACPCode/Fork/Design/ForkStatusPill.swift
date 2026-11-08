import SwiftUI
import ACPClient

// Status pill (plan 3.5). Every state has a glyph and a word, so colour is never the only signal.

/// The states a session row can show. Maps from the gateway status and from the local "running" flag.
enum ForkStatusKind: Equatable {
    case idle
    case running
    case awaitingApproval
    case error
    case unknown(String)

    init(_ status: GatewaySessionStatus) {
        switch status {
        case .idle: self = .idle
        case .running: self = .running
        case .awaitingApproval: self = .awaitingApproval
        case .error: self = .error
        case .unknown(let value): self = .unknown(value)
        }
    }

    /// Text shown in the pill. nil for idle, which shows no pill (plan 3.5).
    var label: String? {
        switch self {
        case .idle: return nil
        case .running: return "Running"
        case .awaitingApproval: return "Needs approval"
        case .error: return "Failed"
        case .unknown(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Unknown" : trimmed.prefix(1).uppercased() + trimmed.dropFirst()
        }
    }

    var tone: ForkTone {
        switch self {
        case .idle, .unknown: return .neutral
        case .running: return .running
        case .awaitingApproval: return .approval
        case .error: return .error
        }
    }

    /// SF Symbol for the glyph. Running uses a spinner unless Reduce Motion is on.
    var glyphName: String {
        switch self {
        case .idle: return "circle"
        case .running: return "circle.dotted"
        case .awaitingApproval: return "hand.raised.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}

struct ForkStatusPill: View {
    let kind: ForkStatusKind
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let label = kind.label {
            HStack(spacing: 4) {
                if kind == .running && !reduceMotion {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(ForkColor.tone(kind.tone))
                } else {
                    Image(systemName: kind.glyphName)
                        .font(ForkType.pill)
                }
                Text(label)
                    .font(ForkType.pill)
            }
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(ForkColor.toneFill(kind.tone)))
            .foregroundStyle(ForkColor.tone(kind.tone))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
        }
    }
}

/// VoiceOver text for a session row, built in one place so it can be unit tested (plan 2.7).
enum ForkSessionRowAccessibility {
    static func label(title: String, status: ForkStatusKind, preview: String?, cwd: String?) -> String {
        var parts = [title]
        if let statusLabel = status.label { parts.append(statusLabel) }
        if let preview, !preview.isEmpty { parts.append(preview) }
        if let cwd, !cwd.isEmpty { parts.append(cwd) }
        return parts.joined(separator: ". ")
    }
}
