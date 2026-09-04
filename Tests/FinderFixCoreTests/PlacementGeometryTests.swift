import CoreGraphics
import XCTest
@testable import FinderFixCore

final class PlacementGeometryTests: XCTestCase {
    private let primaryFrame: CGRect = CGRect(x: 0, y: 0, width: 1_200, height: 900)
    private let primaryVisibleFrame: CGRect = CGRect(x: 0, y: 50, width: 1_200, height: 750)

    func testCenteredAXTopLeftUsesVisibleFrame() throws {
        let point: CGPoint = try XCTUnwrap(
            PlacementGeometry.centeredAXTopLeft(
                windowSize: CGSize(width: 200, height: 100),
                targetVisibleFrameInAppKit: primaryVisibleFrame,
                primaryDisplayFrameInAppKit: primaryFrame
            )
        )

        XCTAssertEqual(point.x, 500, accuracy: 0.001)
        XCTAssertEqual(point.y, 425, accuracy: 0.001)
    }

    func testTopLeftOffsetWorksOnDisplayWithNegativeCoordinates() throws {
        let secondaryVisibleFrame: CGRect = CGRect(x: -1_200, y: -100, width: 1_200, height: 800)
        let point: CGPoint = try XCTUnwrap(
            PlacementGeometry.axTopLeft(
                windowSize: CGSize(width: 400, height: 200),
                placement: .topLeftOffset(x: 20, y: 30),
                targetVisibleFrameInAppKit: secondaryVisibleFrame,
                primaryDisplayFrameInAppKit: primaryFrame,
                constrainToVisibleFrame: true
            )
        )

        XCTAssertEqual(point.x, -1_180, accuracy: 0.001)
        XCTAssertEqual(point.y, 230, accuracy: 0.001)
    }

    func testPlacementClampsToVisibleFrame() throws {
        let point: CGPoint = try XCTUnwrap(
            PlacementGeometry.axTopLeft(
                windowSize: CGSize(width: 300, height: 200),
                placement: .topLeftOffset(x: 1_500, y: 1_500),
                targetVisibleFrameInAppKit: primaryVisibleFrame,
                primaryDisplayFrameInAppKit: primaryFrame,
                constrainToVisibleFrame: true
            )
        )

        XCTAssertEqual(point.x, 900, accuracy: 0.001)
        XCTAssertEqual(point.y, 650, accuracy: 0.001)
    }

    func testOversizedWindowKeepsTopLeadingCornerAccessible() throws {
        let frame: CGRect = try XCTUnwrap(
            PlacementGeometry.clampedAppKitFrame(
                CGRect(x: 400, y: 400, width: 1_400, height: 1_000),
                toVisibleFrame: primaryVisibleFrame
            )
        )

        XCTAssertEqual(frame.minX, primaryVisibleFrame.minX, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, primaryVisibleFrame.maxY, accuracy: 0.001)
    }

    func testCoordinateConversionRoundTrips() throws {
        let appKitFrame: CGRect = CGRect(x: -900, y: 125, width: 700, height: 400)
        let topLeft: CGPoint = try XCTUnwrap(
            PlacementGeometry.axTopLeft(
                forAppKitFrame: appKitFrame,
                primaryDisplayFrameInAppKit: primaryFrame
            )
        )
        let convertedFrame: CGRect = try XCTUnwrap(
            PlacementGeometry.appKitFrame(
                fromAXTopLeft: topLeft,
                windowSize: appKitFrame.size,
                primaryDisplayFrameInAppKit: primaryFrame
            )
        )

        XCTAssertEqual(topLeft.x, -900, accuracy: 0.001)
        XCTAssertEqual(topLeft.y, 375, accuracy: 0.001)
        XCTAssertEqual(convertedFrame, appKitFrame)
    }

    func testInvalidGeometryReturnsNil() {
        XCTAssertNil(
            PlacementGeometry.centeredAXTopLeft(
                windowSize: .zero,
                targetVisibleFrameInAppKit: primaryVisibleFrame,
                primaryDisplayFrameInAppKit: primaryFrame
            )
        )
        XCTAssertNil(
            PlacementGeometry.axTopLeft(
                windowSize: CGSize(width: 100, height: 100),
                placement: .topLeftOffset(x: .infinity, y: 0),
                targetVisibleFrameInAppKit: primaryVisibleFrame,
                primaryDisplayFrameInAppKit: primaryFrame,
                constrainToVisibleFrame: true
            )
        )
    }

    func testDisplayGeometryReportsUsability() {
        let usable: DisplayGeometry = DisplayGeometry(
            identifier: 1,
            frameInAppKit: primaryFrame,
            visibleFrameInAppKit: primaryVisibleFrame,
            isPrimary: true
        )
        let unusable: DisplayGeometry = DisplayGeometry(
            identifier: 2,
            frameInAppKit: .zero,
            visibleFrameInAppKit: .zero,
            isPrimary: false
        )

        XCTAssertTrue(usable.isUsable)
        XCTAssertFalse(unusable.isUsable)
    }
}
