import Testing
import ACPClient
@testable import ACPCode

// Phase 7.1 (plan 4.1, acceptance 1 and 2). Contrast uses the WCAG 2.x formula in ForkContrast.
// Text needs 4.5:1, graphics (glyphs) 3:1, against the surface and against the status fill composited on it.
// Expected ratios in these tests are hand-computed from the WCAG formula (sRGB threshold 0.03928), so a
// wrong token, a wrong formula or a wrong threshold changes the result and the test fails.

struct DesignContrastMathTests {
    @Test func blackOnWhiteIsTwentyOne() {
        let r = ForkContrast.ratio(.init(hex: 0x000000), .init(hex: 0xFFFFFF))
        #expect(abs(r - 21) < 0.001)
    }

    @Test func thresholdsMatchThePlan() {
        #expect(ForkContrast.textMinimum == 4.5)
        #expect(ForkContrast.graphicMinimum == 3.0)
    }

    @Test func passCaseMidGreyOnWhiteMeetsTextMinimum() {
        // #767676 on white: L = ((118/255 + 0.055) / 1.055)^2.4 = 0.18116, ratio 1.05 / 0.23116 = 4.5422.
        let r = ForkContrast.ratio(.init(hex: 0x767676), .init(hex: 0xFFFFFF))
        #expect(r >= ForkContrast.textMinimum)
        #expect(abs(r - 4.54) < 0.01)
    }

    @Test func failCaseSlightlyLighterGreyIsBelowTextMinimum() {
        // #777777 on white: L = 0.18447, ratio 1.05 / 0.23447 = 4.4781, just under the text minimum.
        let r = ForkContrast.ratio(.init(hex: 0x777777), .init(hex: 0xFFFFFF))
        #expect(r < ForkContrast.textMinimum)
        #expect(abs(r - 4.48) < 0.01)
    }

    /// A grey has the same luminance whatever the channel weights are, so only coloured samples catch a
    /// wrong weight. Hand values: (0.2126 + 0.05) / 0.05, (0.7152 + 0.05) / 0.05, (0.0722 + 0.05) / 0.05.
    @Test func pureRedGreenBlueUseTheWCAGWeights() {
        let black = ForkContrast.RGB(hex: 0x000000)
        #expect(abs(ForkContrast.ratio(.init(hex: 0xFF0000), black) - 5.252) < 0.001)
        #expect(abs(ForkContrast.ratio(.init(hex: 0x00FF00), black) - 15.304) < 0.001)
        #expect(abs(ForkContrast.ratio(.init(hex: 0x0000FF), black) - 2.444) < 0.001)
    }

    @Test func blendUsesSourceOverAlphaOnEveryChannel() {
        // 12% black over white leaves 88% white on each channel.
        let grey = ForkContrast.RGB(hex: 0x000000).over(.init(hex: 0xFFFFFF), alpha: 0.12)
        #expect(abs(grey.r - 0.88) < 0.0001)
        #expect(abs(grey.g - 0.88) < 0.0001)
        #expect(abs(grey.b - 0.88) < 0.0001)
        // 50% red over white is (1, 0.5, 0.5).
        let pink = ForkContrast.RGB(hex: 0xFF0000).over(.init(hex: 0xFFFFFF), alpha: 0.5)
        #expect(abs(pink.r - 1) < 0.0001)
        #expect(abs(pink.g - 0.5) < 0.0001)
        #expect(abs(pink.b - 0.5) < 0.0001)
    }
}

/// Pure table check. Light and light high contrast sit on the light surfaces (white, F2F2F7); dark and dark
/// high contrast sit on the dark surfaces (1C1C1E, black). The UIKit suite below checks the resolved system surfaces.
struct DesignTokenTableContrastTests {
    private static let lightSurfaces = [0xFFFFFF, 0xF2F2F7].map { ForkContrast.RGB(hex: UInt32($0)) }
    private static let darkSurfaces = [0x1C1C1E, 0x000000].map { ForkContrast.RGB(hex: UInt32($0)) }

    @Test func everyAppearanceMeetsContrastOnItsSurfaces() {
        let pairs: [(ForkAppearance, [ForkContrast.RGB])] = [
            (.light, Self.lightSurfaces),
            (.lightHighContrast, Self.lightSurfaces),
            (.dark, Self.darkSurfaces),
            (.darkHighContrast, Self.darkSurfaces),
        ]
        for (appearance, surfaces) in pairs {
            for tone in ForkTone.allCases {
                let text = ForkContrast.RGB(hex: ForkTokenTable.hex(tone, appearance))
                for surface in surfaces {
                    let fill = text.over(surface, alpha: ForkTokenTable.fillAlpha(appearance))
                    #expect(ForkContrast.ratio(text, surface) >= ForkContrast.textMinimum,
                            Comment(rawValue: "\(tone) \(appearance) on surface"))
                    #expect(ForkContrast.ratio(text, fill) >= ForkContrast.textMinimum,
                            Comment(rawValue: "\(tone) \(appearance) on fill"))
                }
            }
        }
    }

    @Test func fillAlphaMatchesThePlan() {
        #expect(ForkTokenTable.fillAlpha(.light) == 0.12)
        #expect(ForkTokenTable.fillAlpha(.lightHighContrast) == 0.12)
        #expect(ForkTokenTable.fillAlpha(.dark) == 0.16)
        #expect(ForkTokenTable.fillAlpha(.darkHighContrast) == 0.16)
    }

    /// One hand-computed ratio per token family (light, dark, light high contrast, dark high contrast),
    /// plus the tightest light pair. Fill rows are the tone at fill alpha composited on the surface.
    /// Values were checked by hand: 0057B8 on white L = 0.10277, 1.05 / 0.15277 = 6.873.
    @Test func pinnedRatiosForOneTokenPerFamily() {
        let white = ForkContrast.RGB(hex: 0xFFFFFF)
        let grouped = ForkContrast.RGB(hex: 0xF2F2F7)
        let row = ForkContrast.RGB(hex: 0x1C1C1E)

        // Light: running text on white, and its fill on the grouped surface.
        let runningLight = ForkContrast.RGB(hex: ForkTokenTable.hex(.running, .light))
        Self.expectRatio(runningLight, white, 6.87, "light running text on row")
        let runningLightFill = runningLight.over(grouped, alpha: ForkTokenTable.fillAlpha(.light))
        Self.expectRatio(runningLight, runningLightFill, 5.13, "light running fill on grouped")

        // Light: neutral text on grouped, the tightest plain light pair.
        let neutralLight = ForkContrast.RGB(hex: ForkTokenTable.hex(.neutral, .light))
        Self.expectRatio(neutralLight, grouped, 5.95, "light neutral text on grouped")

        // Dark: running text on the dark row surface.
        let runningDark = ForkContrast.RGB(hex: ForkTokenTable.hex(.running, .dark))
        Self.expectRatio(runningDark, row, 7.30, "dark running text on row")

        // Dark: error fill on the dark row surface, the tightest dark pair.
        let errorDark = ForkContrast.RGB(hex: ForkTokenTable.hex(.error, .dark))
        let errorDarkFill = errorDark.over(row, alpha: ForkTokenTable.fillAlpha(.dark))
        Self.expectRatio(errorDark, errorDarkFill, 5.24, "dark error fill on row")

        // Light high contrast: running text on white.
        let runningHC = ForkContrast.RGB(hex: ForkTokenTable.hex(.running, .lightHighContrast))
        Self.expectRatio(runningHC, white, 10.11, "light high contrast running text on white")

        // Dark high contrast: approval text on the dark row surface.
        let approvalDarkHC = ForkContrast.RGB(hex: ForkTokenTable.hex(.approval, .darkHighContrast))
        Self.expectRatio(approvalDarkHC, row, 12.59, "dark high contrast approval text on row")
    }

    private static func expectRatio(_ text: ForkContrast.RGB, _ background: ForkContrast.RGB,
                                    _ expected: Double, _ label: String) {
        let actual = ForkContrast.ratio(text, background)
        #expect(abs(actual - expected) < 0.01, Comment(rawValue: "\(label): got \(actual), expected \(expected)"))
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

    private static func close(_ a: ForkContrast.RGB, _ b: ForkContrast.RGB) -> Bool {
        abs(a.r - b.r) < 0.001 && abs(a.g - b.g) < 0.001 && abs(a.b - b.b) < 0.001
    }

    @Test func traitCollectionsMapToTheExpectedAppearance() {
        for (expected, traits) in Self.appearances {
            #expect(ForkColor.appearance(for: traits) == expected)
        }
    }

    @Test func resolvedColourTokensMatchTheTable() {
        for (appearance, traits) in Self.appearances {
            for tone in ForkTone.allCases {
                let expected = ForkContrast.RGB(hex: ForkTokenTable.hex(tone, appearance))
                let (text, textAlpha) = Self.rgb(ForkColor.uiColor(tone).resolvedColor(with: traits))
                let label = "\(tone) \(appearance)"
                #expect(Self.close(text, expected), Comment(rawValue: "\(label) text token"))
                #expect(abs(Double(textAlpha) - 1) < 0.0001, Comment(rawValue: "\(label) text alpha"))

                let (fill, fillAlpha) = Self.rgb(ForkColor.uiColor(tone, fill: true).resolvedColor(with: traits))
                #expect(Self.close(fill, expected), Comment(rawValue: "\(label) fill colour"))
                #expect(abs(Double(fillAlpha) - ForkTokenTable.fillAlpha(appearance)) < 0.0001,
                        Comment(rawValue: "\(label) fill alpha"))
            }
        }
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
                    // Glyphs sit on the composed fill. The 4.5:1 text check implies 3:1, so this is kept as the spec record.
                    #expect(ForkContrast.ratio(textRGB, composed) >= ForkContrast.graphicMinimum, Comment(rawValue: label + " (glyph)"))
                }
            }
        }
    }

    @Test func textTokensMeetTextContrastOnBothSurfaces() {
        for (appearance, traits) in Self.appearances {
            for surfaceColor in [UIColor.secondarySystemGroupedBackground, UIColor.systemGroupedBackground] {
                let surface = Self.rgb(surfaceColor.resolvedColor(with: traits)).0
                for text in [UIColor(ForkColor.textPrimary), UIColor(ForkColor.textSecondary)] {
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
        #expect(ForkStatusKind(.unknown(" archived ")).label == "Archived")
    }

    @Test func eachStateMapsToItsToneAndGlyph() {
        #expect(ForkStatusKind.running.tone == .running)
        #expect(ForkStatusKind.awaitingApproval.tone == .approval)
        #expect(ForkStatusKind.error.tone == .error)
        #expect(ForkStatusKind.idle.tone == .neutral)
        #expect(ForkStatusKind.unknown("archived").tone == .neutral)

        #expect(ForkStatusKind.running.glyphName == "circle.dotted")
        #expect(ForkStatusKind.awaitingApproval.glyphName == "hand.raised.fill")
        #expect(ForkStatusKind.error.glyphName == "exclamationmark.triangle.fill")
    }

    @Test func pillStatesDoNotRelyOnColourAlone() {
        let kinds: [ForkStatusKind] = [.running, .awaitingApproval, .error]
        let labels = kinds.map { $0.label ?? "" }
        let glyphs = kinds.map { $0.glyphName }
        #expect(labels.allSatisfy { !$0.isEmpty })
        // Each state has its own word and its own glyph, so the state can be read without colour.
        #expect(Set(labels).count == kinds.count)
        #expect(Set(glyphs).count == kinds.count)
    }

    @Test func sessionRowLabelCarriesStatusAndCwd() {
        let label = ForkSessionRowAccessibility.label(title: "Fix tests", status: .running,
                                                      preview: "Working", cwd: "~/api")
        #expect(label == "Fix tests. Running. Working. ~/api")
        let idle = ForkSessionRowAccessibility.label(title: "Old", status: .idle, preview: nil, cwd: nil)
        #expect(idle == "Old")
    }
}
