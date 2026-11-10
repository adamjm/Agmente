import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// D-113: which agent builder a connection runs, and the pastel badge that shows it. The detection and the
// colours are pure values, so they are unit tested without a view. `AgentBadge` is the only view here.

/// The agent builders the app can tell apart. `unknown` is any other agent.
enum AgentBuilder: String, CaseIterable, Equatable {
    case bob
    case claude
    case codex
    case gemini
    case opencode
    case ohMyPi
    case copilot
    case qwen
    case goose
    case unknown

    /// Works out the builder. The agent's own name wins. Then a Codex app-server is Codex. Then the
    /// connection's name is tried, because a user may have named the server after its agent.
    static func detect(agentName: String?, serverName: String?, isCodex: Bool) -> AgentBuilder {
        if let match = matchName(agentName) { return match }
        if isCodex { return .codex }
        if let match = matchName(serverName) { return match }
        return .unknown
    }

    /// A builder named in free text. Long names match anywhere in the text. The short tokens "pi" and "omp"
    /// match only as whole words, so "pipeline" is not oh-my-pi.
    private static func matchName(_ text: String?) -> AgentBuilder? {
        guard let text else { return nil }
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return nil }

        let substrings: [(String, AgentBuilder)] = [
            ("bob", .bob),
            ("claude", .claude),
            ("codex", .codex),
            ("gemini", .gemini),
            ("opencode", .opencode),
            ("copilot", .copilot),
            ("qwen", .qwen),
            ("goose", .goose),
            ("oh-my-pi", .ohMyPi),
            ("ohmypi", .ohMyPi)
        ]
        for (needle, builder) in substrings where lower.contains(needle) {
            return builder
        }

        let words = Set(lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        if words.contains("pi") || words.contains("omp") { return .ohMyPi }
        return nil
    }

    var displayName: String {
        switch self {
        case .bob: return "IBM Bob"
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .opencode: return "opencode"
        case .ohMyPi: return "oh-my-pi"
        case .copilot: return "Copilot"
        case .qwen: return "Qwen"
        case .goose: return "Goose"
        case .unknown: return "Agent"
        }
    }

    /// An SF Symbol that exists on iOS 17.
    var symbolName: String {
        switch self {
        case .bob: return "wrench.and.screwdriver"
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .gemini: return "diamond"
        case .opencode: return "terminal"
        case .ohMyPi: return "circle.hexagongrid"
        case .copilot: return "airplane"
        case .qwen: return "cloud"
        case .goose: return "bird"
        case .unknown: return "cpu"
        }
    }
}

/// A colour as plain numbers in 0...1 (sRGB). It has no UIKit in it, so tests can check it.
struct AgentRGB: Equatable, Hashable {
    let red: Double
    let green: Double
    let blue: Double

    /// WCAG relative luminance.
    var relativeLuminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio between two colours (1 to 21).
    func contrastRatio(with other: AgentRGB) -> Double {
        let a = relativeLuminance
        let b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// A pastel badge: a soft background and a darker foreground of the same hue, in light and dark mode.
struct AgentPastel: Equatable, Hashable {
    let background: AgentRGB
    let foreground: AgentRGB
    let darkBackground: AgentRGB
    let darkForeground: AgentRGB
}

enum AgentBadgeStyle {
    /// Hues for an agent the app does not know. The hue is picked by `stableIndex`, so a name keeps its colour.
    static let unknownPalette: [AgentPastel] = [
        pastel(light: (0.90, 0.98, 0.94), lightFg: (0.14, 0.44, 0.30), dark: (0.14, 0.30, 0.22), darkFg: (0.76, 0.96, 0.86)),
        pastel(light: (0.95, 0.90, 0.98), lightFg: (0.45, 0.24, 0.56), dark: (0.30, 0.20, 0.36), darkFg: (0.92, 0.82, 1.00)),
        pastel(light: (0.98, 0.94, 0.88), lightFg: (0.50, 0.35, 0.14), dark: (0.33, 0.26, 0.18), darkFg: (1.00, 0.90, 0.76)),
        pastel(light: (0.88, 0.94, 0.99), lightFg: (0.15, 0.36, 0.56), dark: (0.17, 0.24, 0.34), darkFg: (0.78, 0.90, 1.00)),
        pastel(light: (0.99, 0.90, 0.91), lightFg: (0.58, 0.20, 0.27), dark: (0.36, 0.20, 0.23), darkFg: (1.00, 0.82, 0.85)),
        pastel(light: (0.93, 0.97, 0.87), lightFg: (0.33, 0.46, 0.14), dark: (0.25, 0.31, 0.16), darkFg: (0.92, 0.98, 0.78))
    ]

    /// The colour for a builder. An unknown agent with a name gets a palette hue chosen by that name.
    /// An unknown agent without a name gets the neutral grey.
    static func pastel(for builder: AgentBuilder, agentName: String?) -> AgentPastel {
        if builder == .unknown {
            let key = (agentName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { return neutral }
            return unknownPalette[stableIndex(for: key, count: unknownPalette.count)]
        }
        return fixed(for: builder)
    }

    /// FNV-1a over the UTF-8 bytes. Unlike `hashValue`, it gives the same number on every launch.
    static func stableIndex(for text: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Int(hash % UInt32(count))
    }

    private static let neutral = pastel(
        light: (0.93, 0.93, 0.94), lightFg: (0.36, 0.37, 0.40),
        dark: (0.26, 0.27, 0.30), darkFg: (0.86, 0.87, 0.89)
    )

    private static func fixed(for builder: AgentBuilder) -> AgentPastel {
        switch builder {
        case .bob:
            return pastel(light: (0.87, 0.91, 1.00), lightFg: (0.12, 0.28, 0.66), dark: (0.16, 0.22, 0.38), darkFg: (0.74, 0.84, 1.00))
        case .claude:
            return pastel(light: (0.99, 0.90, 0.84), lightFg: (0.58, 0.27, 0.10), dark: (0.36, 0.22, 0.14), darkFg: (1.00, 0.83, 0.70))
        case .codex:
            return pastel(light: (0.86, 0.96, 0.88), lightFg: (0.10, 0.42, 0.19), dark: (0.14, 0.30, 0.18), darkFg: (0.74, 0.95, 0.80))
        case .gemini:
            return pastel(light: (0.92, 0.89, 1.00), lightFg: (0.37, 0.22, 0.72), dark: (0.27, 0.20, 0.42), darkFg: (0.86, 0.81, 1.00))
        case .opencode:
            return pastel(light: (0.82, 0.96, 0.95), lightFg: (0.04, 0.40, 0.38), dark: (0.12, 0.30, 0.29), darkFg: (0.70, 0.96, 0.93))
        case .ohMyPi:
            return pastel(light: (1.00, 0.89, 0.94), lightFg: (0.64, 0.17, 0.42), dark: (0.38, 0.18, 0.27), darkFg: (1.00, 0.81, 0.90))
        case .copilot:
            return pastel(light: (1.00, 0.95, 0.80), lightFg: (0.55, 0.40, 0.02), dark: (0.36, 0.29, 0.12), darkFg: (1.00, 0.92, 0.68))
        case .qwen:
            return pastel(light: (0.84, 0.96, 1.00), lightFg: (0.02, 0.37, 0.52), dark: (0.12, 0.28, 0.36), darkFg: (0.72, 0.92, 1.00))
        case .goose:
            return pastel(light: (0.92, 0.92, 0.91), lightFg: (0.30, 0.32, 0.34), dark: (0.25, 0.26, 0.27), darkFg: (0.88, 0.89, 0.90))
        case .unknown:
            return neutral
        }
    }

    private static func pastel(
        light: (Double, Double, Double),
        lightFg: (Double, Double, Double),
        dark: (Double, Double, Double),
        darkFg: (Double, Double, Double)
    ) -> AgentPastel {
        AgentPastel(
            background: AgentRGB(red: light.0, green: light.1, blue: light.2),
            foreground: AgentRGB(red: lightFg.0, green: lightFg.1, blue: lightFg.2),
            darkBackground: AgentRGB(red: dark.0, green: dark.1, blue: dark.2),
            darkForeground: AgentRGB(red: darkFg.0, green: darkFg.1, blue: darkFg.2)
        )
    }
}

extension AgentPastel {
    /// Background and foreground that switch with light and dark mode.
    fileprivate var backgroundColor: Color { Self.dynamic(light: background, dark: darkBackground) }
    fileprivate var foregroundColor: Color { Self.dynamic(light: foreground, dark: darkForeground) }

    private static func dynamic(light: AgentRGB, dark: AgentRGB) -> Color {
#if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
#else
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
#endif
    }
}

/// A rounded pastel tile with the builder's symbol. It is one accessibility element with the builder's name.
struct AgentBadge: View {
    let builder: AgentBuilder
    /// The agent's own name, used for an unknown agent's colour and as its spoken name.
    var agentName: String? = nil
    var size: CGFloat = 28

    var body: some View {
        let pastel = AgentBadgeStyle.pastel(for: builder, agentName: agentName)
        let spokenName: String = {
            guard builder == .unknown, let name = agentName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return builder.displayName
            }
            return name
        }()

        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(pastel.backgroundColor)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: builder.symbolName)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(pastel.foregroundColor)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenName)
    }
}
