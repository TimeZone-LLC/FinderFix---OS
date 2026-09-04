import CoreGraphics
import Foundation
import XCTest
@testable import FinderFixCore

final class SettingsTests: XCTestCase {
    func testDefaultsDoNotChangeFinderBehavior() {
        let settings: FinderFixSettings = .defaults

        XCTAssertTrue(settings.isEnabled)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertTrue(settings.showMenuBarItem)
        XCTAssertFalse(settings.finderWindows.isEnabled)
        XCTAssertNil(settings.finderWindows.placement.resizeTo)
        XCTAssertNil(settings.finderWindows.placement.position)
        XCTAssertEqual(settings.finderWindows.chrome, .defaults)
        XCTAssertFalse(settings.finderDialogs.isEnabled)
        XCTAssertEqual(settings.finderDialogs.targetDisplay, .primary)
        XCTAssertTrue(settings.finderDialogs.raiseWhenFinderIsFrontmost)
        XCTAssertEqual(settings.globalWindowPlacement, .defaults)
        XCTAssertFalse(settings.globalWindowPlacement.isEnabled)
        XCTAssertEqual(settings.windowFocus, .defaults)
        XCTAssertFalse(settings.windowFocus.isEnabled)
        XCTAssertEqual(settings.windowFocus.activationDelayMilliseconds, 250)
        XCTAssertTrue(settings.windowFocus.requirePointerStop)
        XCTAssertEqual(settings.windowFocus.pauseModifier, .control)
        XCTAssertTrue(settings.windowFocus.excludedApplicationBundleIdentifiers.isEmpty)
        XCTAssertTrue(settings.fileAssociations.confirmBulkChanges)
        XCTAssertTrue(settings.fileAssociations.stopAfterConsentDenial)
    }

    func testSettingsRoundTripThroughCodable() throws {
        let dimensions: WindowDimensions = try XCTUnwrap(WindowDimensions(width: 960, height: 640))
        let settings: FinderFixSettings = FinderFixSettings(
            isEnabled: true,
            launchAtLogin: true,
            showMenuBarItem: false,
            finderWindows: FinderWindowSettings(
                isEnabled: true,
                placement: WindowPlacementSettings(
                    resizeTo: dimensions,
                    position: .topLeftOffset(x: 24, y: 36),
                    constrainToVisibleFrame: true,
                    applyToExistingWindows: false
                ),
                chrome: FinderChromeSettings(
                    toolbar: .shown,
                    sidebar: .hidden,
                    pathBar: .shown,
                    statusBar: .hidden,
                    sidebarWidth: 220,
                    viewMode: .column
                )
            ),
            finderDialogs: FinderDialogSettings(isEnabled: true),
            globalWindowPlacement: GlobalWindowPlacementSettings(
                isEnabled: true,
                aspectRatioWidth: 3,
                aspectRatioHeight: 2,
                screenCoverage: 0.75,
                excludedApplicationBundleIdentifiers: ["com.example.VirtualMachine"]
            ),
            windowFocus: WindowFocusSettings(
                isEnabled: true,
                activationDelayMilliseconds: 425,
                requirePointerStop: false,
                pauseModifier: .option,
                excludedApplicationBundleIdentifiers: [
                    "com.example.Editor",
                    "org.example.Viewer",
                ]
            ),
            fileAssociations: FileAssociationSettings(
                confirmBulkChanges: false,
                stopAfterConsentDenial: true
            )
        )

        let data: Data = try JSONEncoder().encode(settings)
        let decoded: FinderFixSettings = try JSONDecoder().decode(FinderFixSettings.self, from: data)

        XCTAssertEqual(decoded, settings)
    }

    func testWindowDimensionsRejectInvalidValuesAndInvalidDecoding() throws {
        XCTAssertNil(WindowDimensions(width: 0, height: 100))
        XCTAssertNil(WindowDimensions(width: 100, height: -1))
        XCTAssertNil(WindowDimensions(width: .infinity, height: 100))

        let invalidJSON: Data = Data(#"{"width":0,"height":100}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(WindowDimensions.self, from: invalidJSON))
    }
}
