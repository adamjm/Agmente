import Foundation

// Pure token values for status colours. No UIKit here, so the contrast
// harness (scratchpad) and the unit tests read the same table.
// Plan: design-ipad-ux-plan.md section 4.1 (Phase 7.1). Values were chosen
// so every tone passes 4.5:1 on both surface.row and surface.grouped, with the
// status fill composited on top (see DesignTokensTests).

enum ForkTone: String, CaseIterable {
    case running
    case approval
    case error
    case ok
    case neutral
}

enum ForkAppearance: CaseIterable {
    case light
    case dark
    case lightHighContrast
    case darkHighContrast
}

enum ForkTokenTable {
    /// Text and glyph colour for a status tone, as 0xRRGGBB.
    static func hex(_ tone: ForkTone, _ appearance: ForkAppearance) -> UInt32 {
        switch (tone, appearance) {
        case (.running, .light): return 0x0057B8
        case (.approval, .light): return 0x7A4300
        case (.error, .light): return 0xA31A12
        case (.ok, .light): return 0x176433
        case (.neutral, .light): return 0x5C5C62

        case (.running, .dark): return 0x6EACFF
        case (.approval, .dark): return 0xFFBD46
        case (.error, .dark): return 0xFF7D73
        case (.ok, .dark): return 0x5AD67D
        case (.neutral, .dark): return 0xAEAEB2

        case (.running, .lightHighContrast): return 0x003F8A
        case (.approval, .lightHighContrast): return 0x5E3900
        case (.error, .lightHighContrast): return 0x8A1208
        case (.ok, .lightHighContrast): return 0x0C4D22
        case (.neutral, .lightHighContrast): return 0x3A3A3C

        case (.running, .darkHighContrast): return 0xA6CCFF
        case (.approval, .darkHighContrast): return 0xFFD98A
        case (.error, .darkHighContrast): return 0xFFB3AC
        case (.ok, .darkHighContrast): return 0x9DF0B5
        case (.neutral, .darkHighContrast): return 0xC7C7CC
        }
    }

    /// Opacity of the status fill (tint behind the pill). 12% light, 16% dark, per the plan.
    static func fillAlpha(_ appearance: ForkAppearance) -> Double {
        switch appearance {
        case .light, .lightHighContrast: return 0.12
        case .dark, .darkHighContrast: return 0.16
        }
    }
}
