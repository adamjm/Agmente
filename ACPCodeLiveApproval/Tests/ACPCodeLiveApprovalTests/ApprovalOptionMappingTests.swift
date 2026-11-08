import XCTest
@testable import ACPCodeLiveApproval

final class ApprovalOptionMappingTests: XCTestCase {
    func testAllowOnceMapsToOnce() {
        XCTAssertEqual(ApprovalOptionMapping.role(forKind: "allow_once"), .once)
    }

    func testRejectOnceMapsToDeny() {
        XCTAssertEqual(ApprovalOptionMapping.role(forKind: "reject_once"), .deny)
    }

    func testAllowAlwaysHasNoRoleOnTheIsland() {
        XCTAssertNil(ApprovalOptionMapping.role(forKind: "allow_always"))
    }

    func testRejectAlwaysHasNoRoleOnTheIsland() {
        XCTAssertNil(ApprovalOptionMapping.role(forKind: "reject_always"))
    }

    func testUnknownAndEmptyKindsHaveNoRole() {
        XCTAssertNil(ApprovalOptionMapping.role(forKind: "unknown"))
        XCTAssertNil(ApprovalOptionMapping.role(forKind: ""))
        XCTAssertNil(ApprovalOptionMapping.role(forKind: "Allow_Once"))
    }
}
