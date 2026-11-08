import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// Surfaces for the chat. The page is what Bob's replies sit on; the bubble sits behind the
// person's prompt. Light values are sampled from the reference screenshot (page #F9F9F8,
// bubble #F2F1EF). Dark values are the ones the chat used before, so dark mode does not change.
enum ForkChatSurface {
    static let pageLightHex: UInt32 = 0xF9F9F8
    static let pageDarkHex: UInt32 = 0x1C1C1E
    static let bubbleLightHex: UInt32 = 0xF2F1EF
    static let bubbleDarkHex: UInt32 = 0x3A3A3C

    #if canImport(UIKit)
    static let pageUIColor = dynamicColor(light: pageLightHex, dark: pageDarkHex)
    static let bubbleUIColor = dynamicColor(light: bubbleLightHex, dark: bubbleDarkHex)

    static var page: Color { Color(uiColor: pageUIColor) }
    static var bubble: Color { Color(uiColor: bubbleUIColor) }

    private static func dynamicColor(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            uiColor(traits.userInterfaceStyle == .dark ? dark : light)
        }
    }

    private static func uiColor(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
    #else
    static var page: Color { Color(nsColor: dynamicColor(light: pageLightHex, dark: pageDarkHex)) }
    static var bubble: Color { Color(nsColor: dynamicColor(light: bubbleLightHex, dark: bubbleDarkHex)) }

    private static func dynamicColor(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return nsColor(isDark ? dark : light)
        }
    }

    private static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
    #endif
}
