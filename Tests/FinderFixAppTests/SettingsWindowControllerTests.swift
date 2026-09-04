import SwiftUI
import XCTest
@testable import FinderFixApp

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    func testCloseCancelsPendingPresentationAndReturnsToMenuBar() async throws {
        let controller: SettingsWindowController = makeController()
        let window: NSWindow = try XCTUnwrap(controller.window)
        let previousPolicy: NSApplication.ActivationPolicy = NSApplication.shared.activationPolicy()
        defer { NSApplication.shared.setActivationPolicy(previousPolicy) }

        controller.present()
        window.close()
        await drainMainQueue()

        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(NSApplication.shared.activationPolicy(), .accessory)
        XCTAssertTrue(controller.window === window)
    }

    func testReopenBeforeCloseCallbackKeepsSettingsVisible() async throws {
        let controller: SettingsWindowController = makeController()
        let window: NSWindow = try XCTUnwrap(controller.window)
        let previousPolicy: NSApplication.ActivationPolicy = NSApplication.shared.activationPolicy()

        controller.present()
        window.close()
        controller.present()
        await drainMainQueue()

        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(NSApplication.shared.activationPolicy(), .regular)
        XCTAssertTrue(controller.window === window)

        window.close()
        await drainMainQueue()
        NSApplication.shared.setActivationPolicy(previousPolicy)
    }

    private func makeController() -> SettingsWindowController {
        SettingsWindowController(
            rootView: SettingsRootView(
                preferencesStore: PreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                appViewModel: AppViewModel(),
                fileTypesView: AnyView(EmptyView())
            )
        )
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

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
