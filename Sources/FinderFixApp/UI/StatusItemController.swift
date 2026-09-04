import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    enum PreferenceToggle: Int, CaseIterable, Hashable, Sendable {
        case launchAtLogin
        case showMenuBarItem
        case globalShortcutEnabled
        case globalWindowPlacement
        case finderWindowRules
        case resizeFinderWindows
        case repositionFinderWindows
        case finderChrome
        case finderSidebar
        case finderToolbar
        case finderPathBar
        case finderStatusBar
        case eligibleFinderDialogs
        case bringFinderDialogsForward
        case focusFollowsPointer
        case requirePointerStop
        case automaticDSStoreCleanup

        var title: String {
            switch self {
            case .launchAtLogin:
                "Open FinderFix at Login"
            case .showMenuBarItem:
                "Show FinderFix in Menu Bar"
            case .globalShortcutEnabled:
                "Use ⌥⌘F to Open Finder"
            case .globalWindowPlacement:
                "Place New App Windows on Main Display"
            case .finderWindowRules:
                "Apply Rules to New Finder Windows"
            case .resizeFinderWindows:
                "Resize Finder Windows"
            case .repositionFinderWindows:
                "Reposition Finder Windows"
            case .finderChrome:
                "Apply Finder View and Chrome"
            case .finderSidebar:
                "Show Finder Sidebar"
            case .finderToolbar:
                "Show Finder Toolbar"
            case .finderPathBar:
                "Show Finder Path Bar"
            case .finderStatusBar:
                "Show Finder Status Bar"
            case .eligibleFinderDialogs:
                "Move Eligible Finder Dialogs to Main Display"
            case .bringFinderDialogsForward:
                "Bring Moved Finder Dialogs Forward"
            case .focusFollowsPointer:
                "Focus Follows Pointer"
            case .requirePointerStop:
                "Wait Until Pointer Stops"
            case .automaticDSStoreCleanup:
                "Move .DS_Store Files to Trash Automatically"
            }
        }
    }

    struct PreferencePresentation: Equatable {
        let enabledToggles: Set<PreferenceToggle>

        init(preferences: FinderFixPreferences) {
            var enabledToggles: Set<PreferenceToggle> = []
            if preferences.launchAtLogin {
                enabledToggles.insert(.launchAtLogin)
            }
            if preferences.showMenuBarItem {
                enabledToggles.insert(.showMenuBarItem)
            }
            if preferences.globalShortcutEnabled {
                enabledToggles.insert(.globalShortcutEnabled)
            }
            if preferences.globalWindowPlacement.isEnabled {
                enabledToggles.insert(.globalWindowPlacement)
            }
            if preferences.windowRulesEnabled {
                enabledToggles.insert(.finderWindowRules)
            }
            if preferences.resizeWindows {
                enabledToggles.insert(.resizeFinderWindows)
            }
            if preferences.repositionWindows {
                enabledToggles.insert(.repositionFinderWindows)
            }
            if preferences.finderChromeEnabled {
                enabledToggles.insert(.finderChrome)
            }
            if preferences.finderChrome.showSidebar {
                enabledToggles.insert(.finderSidebar)
            }
            if preferences.finderChrome.showToolbar {
                enabledToggles.insert(.finderToolbar)
            }
            if preferences.finderChrome.showPathBar {
                enabledToggles.insert(.finderPathBar)
            }
            if preferences.finderChrome.showStatusBar {
                enabledToggles.insert(.finderStatusBar)
            }
            if preferences.moveEligibleFinderDialogs {
                enabledToggles.insert(.eligibleFinderDialogs)
            }
            if preferences.bringFinderDialogsForward {
                enabledToggles.insert(.bringFinderDialogsForward)
            }
            if preferences.windowFocus.isEnabled {
                enabledToggles.insert(.focusFollowsPointer)
            }
            if preferences.windowFocus.requirePointerStop {
                enabledToggles.insert(.requirePointerStop)
            }
            if preferences.automaticDSStoreCleanupEnabled {
                enabledToggles.insert(.automaticDSStoreCleanup)
            }
            self.enabledToggles = enabledToggles
        }

        func isOn(_ toggle: PreferenceToggle) -> Bool {
            enabledToggles.contains(toggle)
        }
    }

    struct Actions {
        let togglePreference: (PreferenceToggle) -> Void
        let requestAccessibility: () -> Void
        let setWindowFocusSuspended: (Bool) -> Void
        let openFinder: () -> Void
        let applyRules: () -> Void
        let showSettings: () -> Void
        let quit: () -> Void
    }

    private let actions: Actions
    private var statusItem: NSStatusItem?
    private var preferenceItems: [PreferenceToggle: NSMenuItem] = [:]
    private var windowFocusStatusItem: NSMenuItem?
    private var accessibilityItem: NSMenuItem?
    private var preferencePresentation: PreferencePresentation = .init(
        preferences: FinderFixPreferences()
    )
    private var windowFocusEnabled: Bool = false
    private var windowFocusRuntimeState: WindowFocusRuntimeState = .disabled

    init(actions: Actions) {
        self.actions = actions
        super.init()
    }

    func setVisible(_ visible: Bool) {
        if visible {
            installIfNeeded()
        } else if let statusItem: NSStatusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
            preferenceItems.removeAll()
            windowFocusStatusItem = nil
            accessibilityItem = nil
        }
    }

    func setPreferences(_ preferences: FinderFixPreferences) {
        preferencePresentation = PreferencePresentation(preferences: preferences)
        windowFocusEnabled = preferences.windowFocus.isEnabled
        updatePreferencePresentation()
        updateWindowFocusPresentation()
    }

    func setWindowFocus(
        enabled: Bool,
        runtimeState: WindowFocusRuntimeState
    ) {
        windowFocusEnabled = enabled
        windowFocusRuntimeState = runtimeState
        preferenceItems[.focusFollowsPointer]?.state = enabled ? .on : .off
        updateWindowFocusPresentation()
    }

    private func installIfNeeded() {
        guard statusItem == nil else { return }
        let newItem: NSStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button: NSStatusBarButton = newItem.button {
            let image: NSImage? = NSImage(
                systemSymbolName: "macwindow.on.rectangle",
                accessibilityDescription: "FinderFix"
            )
            image?.isTemplate = true
            button.image = image
            button.toolTip = "FinderFix"
        }

        let menu: NSMenu = NSMenu()
        menu.delegate = self
        menu.addItem(menuItem("About FinderFix", action: #selector(showAbout)))
        menu.addItem(.separator())
        addPreferenceSubmenu(
            title: "General",
            toggles: [
                .launchAtLogin,
                .showMenuBarItem,
                .globalShortcutEnabled,
            ],
            to: menu
        )
        addDialogsAndWindowsSubmenu(to: menu)
        addWindowFocusSubmenu(to: menu)
        addPreferenceSubmenu(
            title: "Maintenance",
            toggles: [.automaticDSStoreCleanup],
            to: menu
        )
        menu.addItem(.separator())

        let openFinderItem: NSMenuItem = menuItem(
            "Open Finder",
            action: #selector(openFinder),
            keyEquivalent: "f"
        )
        openFinderItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(openFinderItem)
        menu.addItem(menuItem("Apply Rules Now", action: #selector(applyRules)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Settings…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit FinderFix", action: #selector(quit), keyEquivalent: "q"))
        newItem.menu = menu
        statusItem = newItem
        updatePreferencePresentation()
        updateWindowFocusPresentation()
    }

    private func addDialogsAndWindowsSubmenu(to parentMenu: NSMenu) {
        let submenu: NSMenu = NSMenu(title: "Dialogs and Windows")
        addPreferenceItems([.globalWindowPlacement], to: submenu)
        submenu.addItem(.separator())
        addPreferenceItems(
            [.finderWindowRules, .resizeFinderWindows, .repositionFinderWindows],
            to: submenu
        )
        submenu.addItem(.separator())
        addPreferenceItems(
            [.finderChrome, .finderSidebar, .finderToolbar, .finderPathBar, .finderStatusBar],
            to: submenu
        )
        submenu.addItem(.separator())
        addPreferenceItems(
            [.eligibleFinderDialogs, .bringFinderDialogsForward],
            to: submenu
        )

        let parentItem: NSMenuItem = NSMenuItem(title: "Dialogs and Windows", action: nil, keyEquivalent: "")
        parentItem.submenu = submenu
        parentMenu.addItem(parentItem)
    }

    private func addWindowFocusSubmenu(to parentMenu: NSMenu) {
        let submenu: NSMenu = NSMenu(title: "Window Focus")
        addPreferenceItems([.focusFollowsPointer, .requirePointerStop], to: submenu)
        submenu.addItem(.separator())

        let newWindowFocusStatusItem: NSMenuItem = NSMenuItem(
            title: "Waiting for Accessibility Permission",
            action: nil,
            keyEquivalent: ""
        )
        newWindowFocusStatusItem.isEnabled = false
        submenu.addItem(newWindowFocusStatusItem)
        windowFocusStatusItem = newWindowFocusStatusItem

        let newAccessibilityItem: NSMenuItem = menuItem(
            "Open Accessibility Settings…",
            action: #selector(requestAccessibility)
        )
        submenu.addItem(newAccessibilityItem)
        accessibilityItem = newAccessibilityItem

        let parentItem: NSMenuItem = NSMenuItem(title: "Window Focus", action: nil, keyEquivalent: "")
        parentItem.submenu = submenu
        parentMenu.addItem(parentItem)
    }

    private func addPreferenceSubmenu(
        title: String,
        toggles: [PreferenceToggle],
        to parentMenu: NSMenu
    ) {
        let submenu: NSMenu = NSMenu(title: title)
        addPreferenceItems(toggles, to: submenu)
        let parentItem: NSMenuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parentItem.submenu = submenu
        parentMenu.addItem(parentItem)
    }

    private func addPreferenceItems(_ toggles: [PreferenceToggle], to menu: NSMenu) {
        for toggle: PreferenceToggle in toggles {
            let item: NSMenuItem = menuItem(
                toggle.title,
                action: #selector(togglePreference(_:))
            )
            item.tag = toggle.rawValue
            menu.addItem(item)
            preferenceItems[toggle] = item
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        actions.setWindowFocusSuspended(true)
    }

    func menuDidClose(_ menu: NSMenu) {
        actions.setWindowFocusSuspended(false)
    }

    @objc private func togglePreference(_ sender: NSMenuItem) {
        guard let toggle: PreferenceToggle = PreferenceToggle(rawValue: sender.tag) else { return }
        actions.togglePreference(toggle)
    }

    @objc private func requestAccessibility() {
        actions.requestAccessibility()
    }

    @objc private func showAbout() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let version: String = Bundle.main.object(forInfoDictionaryKey: "FinderFixVersion") as? String ?? "Unpackaged"
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.applicationVersion: version])
    }

    private func menuItem(
        _ title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item: NSMenuItem = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func openFinder() {
        actions.openFinder()
    }

    @objc private func applyRules() {
        actions.applyRules()
    }

    @objc private func showSettings() {
        actions.showSettings()
    }

    @objc private func quit() {
        actions.quit()
    }

    private func updatePreferencePresentation() {
        for toggle: PreferenceToggle in PreferenceToggle.allCases {
            preferenceItems[toggle]?.state = preferencePresentation.isOn(toggle) ? .on : .off
        }
        preferenceItems[.finderSidebar]?.isEnabled = preferencePresentation.isOn(.finderChrome)
        preferenceItems[.finderToolbar]?.isEnabled = preferencePresentation.isOn(.finderChrome)
        preferenceItems[.finderPathBar]?.isEnabled = preferencePresentation.isOn(.finderChrome)
        preferenceItems[.finderStatusBar]?.isEnabled = preferencePresentation.isOn(.finderChrome)
        preferenceItems[.bringFinderDialogsForward]?.isEnabled = preferencePresentation.isOn(
            .eligibleFinderDialogs
        )
        preferenceItems[.requirePointerStop]?.isEnabled = preferencePresentation.isOn(
            .focusFollowsPointer
        )
    }

    private func updateWindowFocusPresentation() {
        let needsAccessibility: Bool = windowFocusEnabled
            && windowFocusRuntimeState == .needsAccessibility
        let isUnavailable: Bool
        if case .unavailable = windowFocusRuntimeState {
            isUnavailable = windowFocusEnabled
        } else {
            isUnavailable = false
        }
        windowFocusStatusItem?.title = needsAccessibility
            ? "Waiting for Accessibility Permission"
            : "Window Focus Unavailable"
        windowFocusStatusItem?.isHidden = !needsAccessibility && !isUnavailable
        accessibilityItem?.isHidden = !needsAccessibility

        let stateDescription: String
        if needsAccessibility {
            stateDescription = "Needs Permission"
        } else if isUnavailable {
            stateDescription = "Needs Attention"
        } else {
            stateDescription = windowFocusEnabled ? "On" : "Off"
        }
        statusItem?.button?.toolTip = "FinderFix: Pointer focus \(stateDescription)"
    }
}
