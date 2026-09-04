import XCTest
@testable import FinderFixApp

@MainActor
final class StatusItemControllerTests: XCTestCase {
    func testPreferencePresentationMapsEveryBooleanSetting() {
        var preferences: FinderFixPreferences = FinderFixPreferences()
        preferences.launchAtLogin = true
        preferences.showMenuBarItem = false
        preferences.globalShortcutEnabled = true
        preferences.globalWindowPlacement.isEnabled = true
        preferences.windowRulesEnabled = false
        preferences.resizeWindows = true
        preferences.repositionWindows = false
        preferences.finderChromeEnabled = true
        preferences.finderChrome.showSidebar = false
        preferences.finderChrome.showToolbar = true
        preferences.finderChrome.showPathBar = false
        preferences.finderChrome.showStatusBar = true
        preferences.moveEligibleFinderDialogs = true
        preferences.bringFinderDialogsForward = false
        preferences.windowFocus.isEnabled = true
        preferences.windowFocus.requirePointerStop = false
        preferences.automaticDSStoreCleanupEnabled = true

        let presentation: StatusItemController.PreferencePresentation = .init(
            preferences: preferences
        )
        let expectedStates: [StatusItemController.PreferenceToggle: Bool] = [
            .launchAtLogin: true,
            .showMenuBarItem: false,
            .globalShortcutEnabled: true,
            .globalWindowPlacement: true,
            .finderWindowRules: false,
            .resizeFinderWindows: true,
            .repositionFinderWindows: false,
            .finderChrome: true,
            .finderSidebar: false,
            .finderToolbar: true,
            .finderPathBar: false,
            .finderStatusBar: true,
            .eligibleFinderDialogs: true,
            .bringFinderDialogsForward: false,
            .focusFollowsPointer: true,
            .requirePointerStop: false,
            .automaticDSStoreCleanup: true,
        ]

        XCTAssertEqual(expectedStates.count, StatusItemController.PreferenceToggle.allCases.count)
        for toggle: StatusItemController.PreferenceToggle in StatusItemController.PreferenceToggle.allCases {
            XCTAssertEqual(presentation.isOn(toggle), expectedStates[toggle])
        }
    }
}
