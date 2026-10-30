import XCTest
@testable import TokenBarLib

final class MenuBarLayoutPolicyTests: XCTestCase {
    func testManyProvidersUseCompactIconOnLaptop() {
        XCTAssertTrue(MenuBarLayoutPolicy.shouldUseCompactIcon(
            contentWidth: 955,
            screenWidth: 1512,
            unobscuredRightWidth: 670
        ))
    }

    func testShortProviderStripKeepsUsageVisible() {
        XCTAssertFalse(MenuBarLayoutPolicy.shouldUseCompactIcon(
            contentWidth: 180,
            screenWidth: 1512,
            unobscuredRightWidth: 670
        ))
    }

    func testNarrowNotchSideReducesExpandedBudget() {
        XCTAssertTrue(MenuBarLayoutPolicy.shouldUseCompactIcon(
            contentWidth: 180,
            screenWidth: 1512,
            unobscuredRightWidth: 400
        ))
    }

    func testLargeUnnotchedDisplayStillReservesSpaceForOtherApps() {
        XCTAssertTrue(MenuBarLayoutPolicy.shouldUseCompactIcon(
            contentWidth: 955,
            screenWidth: 3840,
            unobscuredRightWidth: 0
        ))
        XCTAssertFalse(MenuBarLayoutPolicy.shouldUseCompactIcon(
            contentWidth: 240,
            screenWidth: 3840,
            unobscuredRightWidth: 0
        ))
    }
}
