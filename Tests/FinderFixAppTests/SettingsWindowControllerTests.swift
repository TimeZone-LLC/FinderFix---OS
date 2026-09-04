import SwiftUI
import XCTest
@testable import FinderFixApp

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    func testClosingSettingsKeepsWindowAvailableForReopen() throws {
        let suiteName: String = "FinderFix.SettingsWindowControllerTests.\(UUID().uuidString)"
        let defaults: UserDefaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let controller: SettingsWindowController = SettingsWindowController(
            rootView: SettingsRootView(
                preferencesStore: PreferencesStore(defaults: defaults),
                appViewModel: AppViewModel(),
                fileTypesView: AnyView(EmptyView())
            )
        )
        let originalWindow: NSWindow = try XCTUnwrap(controller.window)

        XCTAssertFalse(originalWindow.isReleasedWhenClosed)
        originalWindow.close()
        XCTAssertTrue(controller.window === originalWindow)
    }
}
