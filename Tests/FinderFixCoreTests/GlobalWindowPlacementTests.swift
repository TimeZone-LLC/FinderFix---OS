import CoreGraphics
import XCTest
@testable import FinderFixCore

final class GlobalWindowPlacementTests: XCTestCase {
    private let primaryFrame: CGRect = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
    private let visibleFrame: CGRect = CGRect(x: 0, y: 40, width: 1_920, height: 1_000)

    func testDefaultsAreDisabledAndNormalized() {
        let settings: GlobalWindowPlacementSettings = .defaults

        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.aspectRatioWidth, 16)
        XCTAssertEqual(settings.aspectRatioHeight, 10)
        XCTAssertEqual(settings.screenCoverage, 0.80)
    }

    func testPlanFitsAspectRatioInsideCoveredVisibleFrameAndCentersIt() throws {
        let settings: GlobalWindowPlacementSettings = GlobalWindowPlacementSettings(
            isEnabled: true,
            aspectRatioWidth: 16,
            aspectRatioHeight: 10,
            screenCoverage: 0.80
        )

        let plan: GlobalWindowPlacementPlan = try XCTUnwrap(
            GlobalWindowPlacementGeometry.plan(
                settings: settings,
                primaryDisplayFrameInAppKit: primaryFrame,
                primaryVisibleFrameInAppKit: visibleFrame
            )
        )

        XCTAssertEqual(plan.targetFrameInAppKit.width, 1_280, accuracy: 0.001)
        XCTAssertEqual(plan.targetFrameInAppKit.height, 800, accuracy: 0.001)
        XCTAssertEqual(plan.targetFrameInAppKit.midX, visibleFrame.midX, accuracy: 0.001)
        XCTAssertEqual(plan.targetFrameInAppKit.midY, visibleFrame.midY, accuracy: 0.001)
        XCTAssertEqual(plan.targetTopLeftInAX.x, 320, accuracy: 0.001)
        XCTAssertEqual(plan.targetTopLeftInAX.y, 140, accuracy: 0.001)
    }

    func testPlanUsesWidthAsLimitingDimensionForWideAspectRatio() throws {
        let settings: GlobalWindowPlacementSettings = GlobalWindowPlacementSettings(
            isEnabled: true,
            aspectRatioWidth: 21,
            aspectRatioHeight: 9,
            screenCoverage: 0.50
        )

        let plan: GlobalWindowPlacementPlan = try XCTUnwrap(
            GlobalWindowPlacementGeometry.plan(
                settings: settings,
                primaryDisplayFrameInAppKit: primaryFrame,
                primaryVisibleFrameInAppKit: visibleFrame
            )
        )

        XCTAssertEqual(plan.targetFrameInAppKit.width, 960, accuracy: 0.001)
        XCTAssertEqual(
            plan.targetFrameInAppKit.width / plan.targetFrameInAppKit.height,
            21.0 / 9.0,
            accuracy: 0.001
        )
        XCTAssertLessThanOrEqual(plan.targetFrameInAppKit.height, visibleFrame.height * 0.50)
    }

    func testNormalizationClampsValuesAndDeduplicatesExclusions() {
        let settings: GlobalWindowPlacementSettings = GlobalWindowPlacementSettings(
            aspectRatioWidth: .infinity,
            aspectRatioHeight: -5,
            screenCoverage: 2,
            excludedApplicationBundleIdentifiers: [
                " com.example.Editor ",
                "COM.EXAMPLE.EDITOR",
                "",
                "org.example.Viewer",
            ]
        ).normalized()

        XCTAssertEqual(settings.aspectRatioWidth, 16)
        XCTAssertEqual(settings.aspectRatioHeight, 1)
        XCTAssertEqual(settings.screenCoverage, 0.95)
        XCTAssertEqual(
            settings.excludedApplicationBundleIdentifiers,
            ["com.example.Editor", "org.example.Viewer"]
        )
    }

    func testInvalidDisplayGeometryReturnsNoPlan() {
        XCTAssertNil(
            GlobalWindowPlacementGeometry.plan(
                settings: .defaults,
                primaryDisplayFrameInAppKit: .zero,
                primaryVisibleFrameInAppKit: visibleFrame
            )
        )
    }
}
