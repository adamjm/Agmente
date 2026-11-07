import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// Colour tokens (plan 4.1). Status colours come from ForkTokenTable. Surfaces and
// text use system semantic colours, so dark mode and Increase Contrast follow the OS.
enum ForkColor {
    #if canImport(UIKit)
    static let surfaceRow = Color(uiColor: .secondarySystemGroupedBackground)
    static let surfaceGrouped = Color(uiColor: .systemGroupedBackground)
    #else
    static let surfaceRow = Color(nsColor: .controlBackgroundColor)
    static let surfaceGrouped = Color(nsColor: .windowBackgroundColor)
    #endif
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary

    /// Status text and glyph colour for a tone.
    static func tone(_ tone: ForkTone) -> Color {
        Color(dynamic: uiColorOrNS(tone, fill: false))
    }

    /// Status fill (tint behind a pill): the tone at 12% light, 16% dark.
    static func toneFill(_ tone: ForkTone) -> Color {
        Color(dynamic: uiColorOrNS(tone, fill: true))
    }

    #if canImport(UIKit)
    /// UIKit colour for a tone, resolved per trait collection. Used by the tests.
    static func uiColor(_ tone: ForkTone, fill: Bool = false) -> UIColor {
        uiColorOrNS(tone, fill: fill)
    }

    static func appearance(for traits: UITraitCollection) -> ForkAppearance {
        let dark = traits.userInterfaceStyle == .dark
        let high = traits.accessibilityContrast == .high
        switch (dark, high) {
        case (false, false): return .light
        case (true, false): return .dark
        case (false, true): return .lightHighContrast
        case (true, true): return .darkHighContrast
        }
    }

    private static func uiColorOrNS(_ tone: ForkTone, fill: Bool) -> UIColor {
        UIColor { traits in
            let a = appearance(for: traits)
            return rgbColor(ForkTokenTable.hex(tone, a), alpha: fill ? ForkTokenTable.fillAlpha(a) : 1)
        }
    }

    private static func rgbColor(_ value: UInt32, alpha: Double) -> UIColor {
        UIColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: CGFloat(alpha))
    }

    #else
    private static func uiColorOrNS(_ tone: ForkTone, fill: Bool) -> NSColor {
        NSColor(name: nil) { appearance in
            let a: ForkAppearance = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
            let value = ForkTokenTable.hex(tone, a)
            let alpha = fill ? ForkTokenTable.fillAlpha(a) : 1
            return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                           green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255,
                           alpha: CGFloat(alpha))
        }
    }
    #endif
}

private extension Color {
    init(dynamic: ForkPlatformColor) {
        #if canImport(UIKit)
        self.init(uiColor: dynamic)
        #else
        self.init(nsColor: dynamic)
        #endif
    }
}

#if canImport(UIKit)
private typealias ForkPlatformColor = UIColor
#else
private typealias ForkPlatformColor = NSColor
#endif
