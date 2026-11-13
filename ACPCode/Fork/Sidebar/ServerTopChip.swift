import SwiftUI

// The top bar's connection label. It names the connection the open session runs on and shows its colour
// (D-113). It is not a menu: choosing or adding a connection is done in Settings > Connections.

struct ServerTopChip: View {
    let name: String
    let colour: Color
    let isConnected: Bool
    let isConnecting: Bool

    private var stateText: String? {
        if isConnected { return nil }
        return isConnecting ? "Connecting" : "Offline"
    }

    var body: some View {
        let chip = HStack(spacing: 8) {
            Circle()
                .fill(colour)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
            Text(name)
                .font(.headline.weight(.semibold))
                .lineLimit(1)
            if let stateText {
                Text(stateText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)

        Group {
            if #available(iOS 26.0, macOS 26.0, *) {
                chip.glassEffect()
            } else {
                chip
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stateText.map { "\(name), \($0)" } ?? name)
        .accessibilityIdentifier("serverTopChip")
    }
}

// The top bar while a session is open: its title, with the colour and name of the connection it runs on (D-113).

struct SessionTopTitle: View {
    let title: String
    let serverName: String
    let colour: Color
    let isConnected: Bool

    private var serverLine: String {
        isConnected ? serverName : "\(serverName) · Offline"
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 6) {
                Circle()
                    .fill(colour)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(serverLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: 260)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(serverLine)")
        .accessibilityIdentifier("sessionTopTitle")
    }
}
