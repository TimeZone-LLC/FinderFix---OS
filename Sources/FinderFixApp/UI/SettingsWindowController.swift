import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var presentationID: UUID?

    init(rootView: SettingsRootView) {
        let hostingController: NSHostingController<SettingsRootView> = NSHostingController(rootView: rootView)
        // The window owns its size constraints below. Automatic hosting sizing can
        // ask SwiftUI to resize NSWindow while an Accessibility query is in flight.
        hostingController.sizingOptions = []
        let window: NSWindow = NSWindow(contentViewController: hostingController)
        window.title = "FinderFix Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 800, height: 580)
        window.setContentSize(NSSize(width: 900, height: 650))
        window.center()
        window.setFrameAutosaveName("FinderFix.SettingsWindow")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func present() {
        guard let window: NSWindow else { return }
        let requestID: UUID = UUID()
        presentationID = requestID
        NSApplication.shared.setActivationPolicy(.regular)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self, weak window] in
            guard self?.presentationID == requestID,
                  let window: NSWindow,
                  window.isVisible else { return }
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        presentationID = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentationID == nil else { return }
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }
}
