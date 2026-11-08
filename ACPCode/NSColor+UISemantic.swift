import SwiftUI

#if os(macOS)
import AppKit

extension NSColor {
    // Match UIKit semantic colors more closely on macOS.
    static var systemGray2: NSColor { acpcodeDynamic(light: 0xAEAEB2, dark: 0x636366) }
    static var systemGray3: NSColor { acpcodeDynamic(light: 0xC7C7CC, dark: 0x48484A) }
    static var systemGray4: NSColor { acpcodeDynamic(light: 0xD1D1D6, dark: 0x3A3A3C) }
    static var systemGray5: NSColor { acpcodeDynamic(light: 0xE5E5EA, dark: 0x2C2C2E) }
    static var systemGray6: NSColor { acpcodeDynamic(light: 0xF2F2F7, dark: 0x1C1C1E) }

    static var systemBackground: NSColor { acpcodeDynamic(light: 0xFFFFFF, dark: 0x000000) }
    static var secondarySystemBackground: NSColor { acpcodeDynamic(light: 0xF2F2F7, dark: 0x1C1C1E) }
    static var tertiarySystemBackground: NSColor { acpcodeDynamic(light: 0xFFFFFF, dark: 0x2C2C2E) }
    static var systemGroupedBackground: NSColor { acpcodeDynamic(light: 0xF2F2F7, dark: 0x000000) }

    private static func acpcodeDynamic(light: Int, dark: Int, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return acpcodeColor(hex: isDark ? dark : light, alpha: alpha)
        }
    }

    private static func acpcodeColor(hex: Int, alpha: CGFloat = 1) -> NSColor {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
#endif
