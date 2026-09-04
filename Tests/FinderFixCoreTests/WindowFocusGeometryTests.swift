import CoreGraphics
import XCTest
@testable import FinderFixCore

final class WindowFocusGeometryTests: XCTestCase {
    private let screenFrame: CGRect = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)

    func testActiveFinderFixWithoutAVisibleWindowFailsClosed() {
        XCTAssertTrue(
            WindowFocusGeometry.shouldSuspendForOwnInterface(
                applicationIsActive: true,
                pointerPositionInAX: WindowFocusPointerPosition(x: 1_500, y: 900),
                primaryDisplayFrameInAppKit: screenFrame,
                visibleWindowFramesInAppKit: []
            )
        )
    }

    func testActiveFinderFixAllowsInspectionAwayFromItsVisibleWindows() {
        let ownWindowFrame: CGRect = CGRect(x: 100, y: 700, width: 500, height: 300)

        XCTAssertFalse(
            WindowFocusGeometry.shouldSuspendForOwnInterface(
                applicationIsActive: true,
                pointerPositionInAX: WindowFocusPointerPosition(x: 1_500, y: 900),
                primaryDisplayFrameInAppKit: screenFrame,
                visibleWindowFramesInAppKit: [ownWindowFrame]
            )
        )
    }

    func testSuspendsBeforeInspectingAVisibleFinderFixWindow() {
        let ownWindowFrame: CGRect = CGRect(x: 100, y: 700, width: 500, height: 300)

        XCTAssertTrue(
            WindowFocusGeometry.shouldSuspendForOwnInterface(
                applicationIsActive: true,
                pointerPositionInAX: WindowFocusPointerPosition(x: 300, y: 180),
                primaryDisplayFrameInAppKit: screenFrame,
                visibleWindowFramesInAppKit: [ownWindowFrame]
            )
        )
    }

    func testAllowsInspectionAwayFromFinderFixWindows() {
        let ownWindowFrame: CGRect = CGRect(x: 100, y: 700, width: 500, height: 300)

        XCTAssertFalse(
            WindowFocusGeometry.shouldSuspendForOwnInterface(
                applicationIsActive: false,
                pointerPositionInAX: WindowFocusPointerPosition(x: 1_500, y: 900),
                primaryDisplayFrameInAppKit: screenFrame,
                visibleWindowFramesInAppKit: [ownWindowFrame]
            )
        )
    }

    func testInvalidOwnInterfaceGeometryFailsClosed() {
        XCTAssertTrue(
            WindowFocusGeometry.shouldSuspendForOwnInterface(
                applicationIsActive: false,
                pointerPositionInAX: WindowFocusPointerPosition(x: .infinity, y: 200),
                primaryDisplayFrameInAppKit: screenFrame,
                visibleWindowFramesInAppKit: []
            )
        )
    }

    func testAcceptsWindowWithMinimumVisibleIntersection() {
        let windowFrame: CGRect = CGRect(x: 1_916, y: 1_076, width: 800, height: 600)

        XCTAssertTrue(
            WindowFocusGeometry.hasMinimumVisibleIntersection(
                windowFrame: windowFrame,
                screenFrame: screenFrame
            )
        )
    }

    func testRejectsWindowWithNarrowParkedSliver() {
        let windowFrame: CGRect = CGRect(x: 1_917, y: 100, width: 800, height: 600)

        XCTAssertFalse(
            WindowFocusGeometry.hasMinimumVisibleIntersection(
                windowFrame: windowFrame,
                screenFrame: screenFrame
            )
        )
    }

    func testRejectsWindowWithShortParkedSliver() {
        let windowFrame: CGRect = CGRect(x: 100, y: 1_077, width: 800, height: 600)

        XCTAssertFalse(
            WindowFocusGeometry.hasMinimumVisibleIntersection(
                windowFrame: windowFrame,
                screenFrame: screenFrame
            )
        )
    }

    func testRejectsWindowOnAnotherDisplay() {
        let windowFrame: CGRect = CGRect(x: -1_000, y: 100, width: 800, height: 600)

        XCTAssertFalse(
            WindowFocusGeometry.hasMinimumVisibleIntersection(
                windowFrame: windowFrame,
                screenFrame: screenFrame
            )
        )
    }

    func testRejectsInvalidGeometry() {
        let windowFrame: CGRect = CGRect(
            x: 100,
            y: 100,
            width: CGFloat.infinity,
            height: 600
        )

        XCTAssertFalse(
            WindowFocusGeometry.hasMinimumVisibleIntersection(
                windowFrame: windowFrame,
                screenFrame: screenFrame
            )
        )
    }
}
