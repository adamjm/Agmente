import Testing
import ACPClient
@testable import Agmente

// Phase 7.1 (plan 4.1, acceptance 1 and 2). Contrast uses the WCAG 2.x formula in ForkContrast.
// Text needs 4.5:1, graphics (glyphs) 3:1, against the surface and against the status fill composited on it.

struct DesignContrastMathTests {
    @Test func blackOnWhiteIsTwentyOne() {
        let r = ForkContrast.ratio(.init(hex: 0x000000), .init(hex: 0xFFFFFF))
        #expect(abs(r - 21) < 0.001)
    }

    @Test func passCaseMidGreyOnWhiteMeetsTextMinimum() {
        // #767676 on white is the classic 4.54:1 boundary case.
        let r = ForkContrast.ratio(.init(hex: 0x767676), .init(hex: 0xFFFFFF))
        #expect(r >= ForkContrast.textMinimum)
        #expect(abs(r - 4.54) < 0.01)
    }

    @Test func failCaseSlightlyLighterGreyIsBelowTextMinimum() {
        // #777777 on white is 4.48:1, just under the text minimum.
        let r = ForkContrast.ratio(.init(hex: 0x777777), .init(hex: 0xFFFFFF))
        #expect(r < ForkContrast.textMinimum)
        #expect(abs(r - 4.48) < 0.01)
    }

    @Test func blendUsesSourceOverAlpha() {
        let blended = ForkContrast.RGB(hex: 0x000000).over(.init(hex: 0xFFFFFF), alpha: 0.12)
        #expect(abs(blended.r - (1 - 0.12)) < 0.0001)
    }
}

/// Pure table check on the two plain surfaces (light white and dark 1C1C1E; grouped F2F2F7 and black).
struct DesignTokenTableContrastTests {
    private static let lightSurfaces = [0xFFFFFF, 0xF2F2F7].map { ForkContrast.RGB(hex: UInt32($0)) }
    private static let darkSurfaces = [0x1C1C1E, 0x000000].map { ForkContrast.RGB(hex: UInt32($0)) }

    @Test func lightAndDarkTonesMeetContrastOnBothSurfaces() {
        let pairs: [(ForkAppearance, [ForkContrast.RGB])] = [
            (.light, Self.lightSurfaces),
            (.dark, Self.darkSurfaces),
        ]
        for (appearance, surfaces) in pairs {
            for tone in ForkTone.allCases {
                let text = ForkContrast.RGB(hex: ForkTokenTable.hex(tone, appearance))
                for surface in surfaces {
                    let fill = text.over(surface, alpha: ForkTokenTable.fillAlpha(appearance))
                    #expect(ForkContrast.ratio(text, surface) >= ForkContrast.textMinimum,
                            "\(tone) \(appearance) on surface")
                    #expect(ForkContrast.ratio(text, fill) >= ForkContrast.textMinimum,
                            "\(tone) \(appearance) on fill")
                }
            }
        }
    }
}

#if canImport(UIKit)
import UIKit

/// Resolved UIKit values per trait collection (light, dark, and both with Increase Contrast).
@MainActor
struct DesignTokensUIKitContrastTests {
    private static let appearances: [ForkAppearance: UITraitCollection] = [
        .light: traits(dark: false, high: false),
        .dark: traits(dark: true, high: false),
        .lightHighContrast: traits(dark: false, high: true),
        .darkHighContrast: traits(dark: true, high: true),
    ]

    private static func traits(dark: Bool, high: Bool) -> UITraitCollection {
        UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: dark ? .dark : .light),
            UITraitCollection(accessibilityContrast: high ? .high : .normal),
        ])
    }

    private static func rgb(_ color: UIColor) -> (ForkContrast.RGB, CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (ForkContrast.RGB(r: Double(r), g: Double(g), b: Double(b)), a)
    }

    @Test func everyToneMeetsTextAndGlyphContrastOnRowAndGroupedSurfaces() {
        for (appearance, traits) in Self.appearances {
            let surfaces: [(String, UIColor)] = [
                ("row", UIColor.secondarySystemGroupedBackground.resolvedColor(with: traits)),
                ("grouped", UIColor.systemGroupedBackground.resolvedColor(with: traits)),
            ]
            for tone in ForkTone.allCases {
                let text = ForkColor.uiColor(tone).resolvedColor(with: traits)
                let fillColor = ForkColor.uiColor(tone, fill: true).resolvedColor(with: traits)
                let (textRGB, _) = Self.rgb(text)
                let (fillRGB, fillAlpha) = Self.rgb(fillColor)
                for (name, surface) in surfaces {
                    let (surfaceRGB, _) = Self.rgb(surface)
                    let composed = fillRGB.over(surfaceRGB, alpha: Double(fillAlpha))
                    let label = "\(tone) \(appearance) on \(name)"
                    #expect(ForkContrast.ratio(textRGB, surfaceRGB) >= ForkContrast.textMinimum, Comment(rawValue: label))
                    #expect(ForkContrast.ratio(textRGB, composed) >= ForkContrast.textMinimum, Comment(rawValue: label + " (fill)"))
                    #expect(ForkContrast.ratio(textRGB, composed) >= ForkContrast.graphicMinimum, Comment(rawValue: label + " (glyph)"))
                }
            }
        }
    }

    @Test func systemTextTokensMeetTextContrastOnBothSurfaces() {
        for (appearance, traits) in Self.appearances {
            for surfaceColor in [UIColor.secondarySystemGroupedBackground, UIColor.systemGroupedBackground] {
                let surface = Self.rgb(surfaceColor.resolvedColor(with: traits)).0
                for text in [UIColor.label, UIColor.secondaryLabel] {
                    let (textRGB, _) = Self.rgb(text.resolvedColor(with: traits))
                    #expect(ForkContrast.ratio(textRGB, surface) >= ForkContrast.textMinimum,
                            Comment(rawValue: "\(appearance) text token on surface"))
                }
            }
        }
    }
}
#endif

struct DesignStatusPillTests {
    @Test func everyGatewayStatusMapsToAPillWithAWordExceptIdle() {
        let cases: [(GatewaySessionStatus, String?)] = [
            (.idle, nil),
            (.running, "Running"),
            (.awaitingApproval, "Needs approval"),
            (.error, "Failed"),
            (.unknown("archived"), "Archived"),
        ]
        for (status, expected) in cases {
            let kind = ForkStatusKind(status)
            #expect(kind.label == expected, "label for \(status.rawValue)")
            if expected != nil {
                #expect(!(kind.label ?? "").isEmpty)
                #expect(!kind.glyphName.isEmpty)
            }
        }
    }

    @Test func unknownStatusWithEmptyValueStillHasAWord() {
        #expect(ForkStatusKind(.unknown("  ")).label == "Unknown")
    }

    @Test func pillStatesDoNotRelyOnColourAlone() {
        for kind in [ForkStatusKind.running, .awaitingApproval, .error] {
            #expect(kind.label != nil)
            #expect(!kind.glyphName.isEmpty)
        }
    }

    @Test func sessionRowLabelCarriesStatusAndCwd() {
        let label = ForkSessionRowAccessibility.label(title: "Fix tests", status: .running,
                                                      preview: "Working", cwd: "~/api")
        #expect(label == "Fix tests. Running. Working. ~/api")
        let idle = ForkSessionRowAccessibility.label(title: "Old", status: .idle, preview: nil, cwd: nil)
        #expect(idle == "Old")
    }
}
