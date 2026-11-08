import UIKit
import XCTest
@testable import ACPCode

/// The chat's code theme (design pass): code is monospaced, smaller than body text, and its
/// background differs between light and dark so it reads as code in both.
final class ForkMarkdownThemeTests: XCTestCase {
    func testCodeFontsAreMonospaced() {
        let theme = ForkMarkdownTheme.make()
        XCTAssertTrue(theme.fonts.code.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        XCTAssertTrue(theme.fonts.codeInline.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
    }

    func testCodeIsSmallerThanBodyText() {
        let theme = ForkMarkdownTheme.make()
        let body = UIFont.preferredFont(forTextStyle: .body).pointSize
        XCTAssertLessThan(theme.fonts.code.pointSize, body)
        XCTAssertLessThan(theme.fonts.codeInline.pointSize, body)
    }

    func testCodeBackgroundDiffersBetweenLightAndDark() {
        let theme = ForkMarkdownTheme.make()
        let light = theme.colors.codeBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let dark = theme.colors.codeBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        XCTAssertNotEqual(light, dark)
    }
}
