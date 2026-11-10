import Testing
import CoreGraphics
@testable import ACPCode

// Slide-over drawer geometry and open/close thresholds (Fork/Drawer/DrawerLayout.swift). Pure logic, no view.

struct DrawerLayoutTests {
    @Test func drawerWidthIsEightySixPercentOfTheScreenOnPhones() {
        #expect(DrawerLayout.drawerWidth(screenWidth: 390) == 390 * 0.86)
    }

    @Test func drawerWidthIsCappedAtThreeHundredEightyPointsOnPads() {
        #expect(DrawerLayout.drawerWidth(screenWidth: 1024) == 380)
        #expect(DrawerLayout.drawerWidth(screenWidth: 600) == 380)
    }

    @Test func drawerWidthIsZeroForAnEmptyOrInvalidScreen() {
        #expect(DrawerLayout.drawerWidth(screenWidth: 0) == 0)
        #expect(DrawerLayout.drawerWidth(screenWidth: -10) == 0)
        #expect(DrawerLayout.drawerWidth(screenWidth: .nan) == 0)
    }

    @Test func dragOpensOnlyFromTheLeftEdgeZone() {
        #expect(DrawerLayout.isInOpenZone(startX: 0))
        #expect(DrawerLayout.isInOpenZone(startX: DrawerLayout.edgeZone))
        #expect(!DrawerLayout.isInOpenZone(startX: DrawerLayout.edgeZone + 1))
        #expect(!DrawerLayout.isInOpenZone(startX: -1))
    }

    @Test func shouldOpenNeedsRightwardTravelOfAboutAThirdOfTheWidth() {
        let width: CGFloat = 335
        #expect(!DrawerLayout.shouldOpen(translation: 0, velocity: 0, width: width))
        #expect(!DrawerLayout.shouldOpen(translation: 100, velocity: 0, width: width))
        #expect(DrawerLayout.shouldOpen(translation: 120, velocity: 0, width: width))
    }

    @Test func shouldOpenAcceptsAFlickEvenWithShortTravel() {
        let width: CGFloat = 335
        #expect(!DrawerLayout.shouldOpen(translation: 30, velocity: 50, width: width))
        #expect(DrawerLayout.shouldOpen(translation: 30, velocity: DrawerLayout.flickDistance, width: width))
    }

    @Test func shouldOpenIgnoresLeftwardDrags() {
        #expect(!DrawerLayout.shouldOpen(translation: -200, velocity: -900, width: 335))
    }

    @Test func shouldCloseNeedsLeftwardTravelOfAboutAThirdOfTheWidth() {
        let width: CGFloat = 335
        #expect(!DrawerLayout.shouldClose(translation: -50, velocity: 0, width: width))
        #expect(DrawerLayout.shouldClose(translation: -120, velocity: 0, width: width))
    }

    @Test func shouldCloseAcceptsALeftwardFlick() {
        let width: CGFloat = 335
        #expect(!DrawerLayout.shouldClose(translation: -20, velocity: -50, width: width))
        #expect(DrawerLayout.shouldClose(translation: -20, velocity: -DrawerLayout.flickDistance, width: width))
    }

    @Test func shouldCloseIgnoresRightwardDragsAndZeroWidth() {
        #expect(!DrawerLayout.shouldClose(translation: 200, velocity: 900, width: 335))
        #expect(!DrawerLayout.shouldClose(translation: -200, velocity: -900, width: 0))
        #expect(!DrawerLayout.shouldOpen(translation: 200, velocity: 900, width: 0))
    }

    @Test func offsetRestsAtZeroWhenOpenAndOffscreenWhenClosed() {
        #expect(DrawerLayout.offset(isOpen: true, drag: 0, width: 335) == 0)
        #expect(DrawerLayout.offset(isOpen: false, drag: 0, width: 335) == -335)
    }

    @Test func offsetFollowsTheFingerAndStaysBetweenTheRestingPositions() {
        #expect(DrawerLayout.offset(isOpen: false, drag: 50, width: 335) == -285)
        #expect(DrawerLayout.offset(isOpen: false, drag: 999, width: 335) == 0)
        #expect(DrawerLayout.offset(isOpen: true, drag: -50, width: 335) == -50)
        #expect(DrawerLayout.offset(isOpen: true, drag: -999, width: 335) == -335)
    }

    @Test func opennessIsOneWhenFullyOpenAndZeroWhenHidden() {
        #expect(DrawerLayout.openness(offset: 0, width: 335) == 1)
        #expect(DrawerLayout.openness(offset: -335, width: 335) == 0)
        #expect(DrawerLayout.openness(offset: -167.5, width: 335) == 0.5)
        #expect(DrawerLayout.openness(offset: 0, width: 0) == 0)
    }
}
