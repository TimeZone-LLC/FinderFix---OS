import CoreGraphics
import XCTest
@testable import FinderFixApp

final class FinderAutomationConfigurationPreferencesTests: XCTestCase {
    func testDefaultsLeaveFinderBehaviorUnchanged() {
        let configuration: FinderAutomationConfiguration = FinderAutomationConfiguration(
            preferences: FinderFixPreferences()
        )

        XCTAssertFalse(configuration.isEnabled)
        XCTAssertFalse(configuration.windows.isEnabled)
        XCTAssertEqual(configuration.windows.size, CGSize(width: 1_100, height: 720))
        XCTAssertEqual(configuration.windows.position, .centered)
        XCTAssertEqual(configuration.windows.display, .pointer)
        XCTAssertEqual(configuration.appearance, .unchanged)
        XCTAssertEqual(configuration.dialogs, FinderDialogPlacementConfiguration(
            isEnabled: false,
            raiseWhenFinderIsFrontmost: true
        ))
        XCTAssertNil(configuration.openFoldersInNewTabs)
    }

    func testExplicitFalseTabPreferenceKeepsServiceEnabledWhenOtherRulesAreOff() {
        var preferences: FinderFixPreferences = FinderFixPreferences()
        preferences.windowRulesEnabled = false
        preferences.finderChromeEnabled = false
        preferences.moveEligibleFinderDialogs = false
        preferences.folderOpeningBehavior = .windows

        let configuration: FinderAutomationConfiguration = FinderAutomationConfiguration(
            preferences: preferences
        )

        XCTAssertTrue(configuration.isEnabled)
        XCTAssertFalse(configuration.windows.isEnabled)
        XCTAssertEqual(configuration.appearance, .unchanged)
        XCTAssertFalse(configuration.dialogs.isEnabled)
        XCTAssertEqual(configuration.openFoldersInNewTabs, false)
    }

    func testCustomPositionAndChromeMapWithoutLosingValues() {
        var preferences: FinderFixPreferences = FinderFixPreferences()
        preferences.windowRulesEnabled = true
        preferences.finderChromeEnabled = true
        preferences.windowPosition = .custom
        preferences.horizontalOffset = -40
        preferences.verticalOffset = 75
        preferences.displayTarget = .current
        preferences.finderChrome.viewStyle = .columns
        preferences.finderChrome.showSidebar = false
        preferences.finderChrome.sidebarWidth = 244.6

        let configuration: FinderAutomationConfiguration = FinderAutomationConfiguration(
            preferences: preferences
        )

        XCTAssertEqual(configuration.windows.position, .topLeftOffset(x: -40, y: 75))
        XCTAssertEqual(configuration.windows.display, .currentWindow)
        XCTAssertEqual(configuration.appearance.view, .column)
        XCTAssertEqual(configuration.appearance.sidebar, .hidden)
        XCTAssertEqual(configuration.appearance.sidebarWidth, 245)
    }

    func testWindowSizeIsClampedBeforeAutomation() {
        var preferences: FinderFixPreferences = FinderFixPreferences()
        preferences.windowRulesEnabled = true
        preferences.windowWidth = 12
        preferences.windowHeight = 50_000

        let configuration: FinderAutomationConfiguration = FinderAutomationConfiguration(
            preferences: preferences
        )

        XCTAssertEqual(configuration.windows.size, CGSize(width: 320, height: 10_000))
    }

    func testNonFiniteAndHugeValuesNormalizeBeforeIntegerConversion() {
        var preferences: FinderFixPreferences = FinderFixPreferences()
        preferences.windowWidth = .infinity
        preferences.windowHeight = .nan
        preferences.finderChrome.sidebarWidth = 1e300

        let normalized: FinderFixPreferences = preferences.normalized()
        let configuration: FinderAutomationConfiguration = FinderAutomationConfiguration(
            preferences: preferences
        )

        XCTAssertEqual(normalized.windowWidth, 1_100)
        XCTAssertEqual(normalized.windowHeight, 720)
        XCTAssertEqual(normalized.finderChrome.sidebarWidth, 360)
        XCTAssertEqual(configuration.appearance.sidebarWidth, nil)
    }
}
