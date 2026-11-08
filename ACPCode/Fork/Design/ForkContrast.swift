import Foundation

// WCAG 2.x contrast math on sRGB values in 0...1. Pure Swift.
enum ForkContrast {
    struct RGB: Equatable {
        var r: Double
        var g: Double
        var b: Double

        init(r: Double, g: Double, b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }

        init(hex: UInt32) {
            r = Double((hex >> 16) & 0xFF) / 255
            g = Double((hex >> 8) & 0xFF) / 255
            b = Double(hex & 0xFF) / 255
        }

        /// Source-over blend of self (alpha a) on top of background.
        func over(_ background: RGB, alpha a: Double) -> RGB {
            RGB(r: r * a + background.r * (1 - a),
                g: g * a + background.g * (1 - a),
                b: b * a + background.b * (1 - a))
        }
    }

    static func luminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    /// Contrast ratio between two colours, 1...21.
    static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static let textMinimum = 4.5
    static let graphicMinimum = 3.0
}
