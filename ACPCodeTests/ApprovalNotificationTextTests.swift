import XCTest
@testable import ACPCode

/// D-111: the same cases as the gateway's Go tests in gateway/internal/push/approval_test.go.
final class ApprovalNotificationTextTests: XCTestCase {
    func testVerbsFollowTheKind() {
        let cases: [(title: String, kind: String?, want: String)] = [
            ("npm test", "execute", "Run: npm test"),
            ("src/app.ts", "edit", "Edit: src/app.ts"),
            ("old.txt", "delete", "Delete: old.txt"),
            ("README.md", "read", "Read: README.md"),
            ("https://example.test", "fetch", "Fetch: https://example.test"),
            ("a.txt to b.txt", "move", "Move: a.txt to b.txt"),
            ("Plan the work", "think", "Plan the work"),
            ("Something", "", "Something"),
            ("Something", nil, "Something"),
            ("EXEC", "EXECUTE", "EXEC"),
            ("", "execute", ""),
            ("   ", "edit", ""),
        ]
        for c in cases {
            XCTAssertEqual(ApprovalNotificationText.summary(kind: c.kind, title: c.title), c.want, "\(c.title) \(c.kind ?? "nil")")
        }
    }

    func testADuplicatedVerbIsNotAddedAgain() {
        XCTAssertEqual(ApprovalNotificationText.summary(kind: "execute", title: "Run echo"), "Run echo")
        XCTAssertEqual(ApprovalNotificationText.summary(kind: "read", title: "read"), "read")
    }

    func testBodyHoldsTheSummary() {
        XCTAssertEqual(ApprovalNotificationText.body(kind: "execute", title: "npm test"), "Approval needed: Run: npm test")
    }

    func testAnEmptySummaryKeepsTheOldBody() {
        for title in ["", "   ", "\n\t"] {
            XCTAssertEqual(ApprovalNotificationText.body(kind: "execute", title: title), "Approval needed", title)
        }
    }

    func testControlsAndNewlinesAreLostAndSpacesCollapse() {
        XCTAssertEqual(
            ApprovalNotificationText.body(kind: nil, title: "Run:\nnpm\u{0}  test\t\u{202E}   x"),
            "Approval needed: Run: npm test x"
        )
    }

    func testALongSummaryIsCutToEightyCharactersOnACharacterBoundary() {
        let body = ApprovalNotificationText.body(kind: nil, title: String(repeating: "日", count: 200))
        let prefix = "Approval needed: "
        XCTAssertTrue(body.hasPrefix(prefix))
        let summary = String(body.dropFirst(prefix.count))
        XCTAssertEqual(summary.unicodeScalars.count, 80)
        XCTAssertTrue(summary.hasSuffix("…"))
        XCTAssertEqual(String(summary.dropLast()), String(repeating: "日", count: 79))
    }

    func testACutThatWouldEndInASpaceDropsIt() {
        let title = String(repeating: "a", count: 78) + " bcd"
        let summary = ApprovalNotificationText.cut(title)
        XCTAssertEqual(summary, String(repeating: "a", count: 78) + "…")
    }

    func testAShortSummaryIsKept() {
        XCTAssertEqual(ApprovalNotificationText.cut("Run: npm test"), "Run: npm test")
    }
}
