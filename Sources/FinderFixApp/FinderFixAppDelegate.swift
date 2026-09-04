import AppKit
import Combine
import FinderFixCore
import SwiftUI

@MainActor
final class FinderFixAppDelegate: NSObject, NSApplicationDelegate {
    private enum PreferenceApplicationSource {
        case startup
        case userChange
    }

    private static let didCompleteFirstLaunchKey: String = "FinderFix.didCompleteFirstLaunch.v1"

    private let preferencesStore: PreferencesStore
    private let appViewModel: AppViewModel
    private let loginItemService: LoginItemService
    private let hotKeyManager: GlobalHotKeyManager
    private let automationService: FinderAutomationService
    private let dsStoreMaintenanceService: DSStoreMaintenanceService
    private let globalWindowPlacementService: GlobalWindowPlacementService
    private let windowFocusService: WindowFocusService
    private var preferencesSubscription: AnyCancellable?
    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?
    private var lastAppliedPreferences: FinderFixPreferences?
    private var accessibilityRefreshTask: Task<Void, Never>?
    private var observedAccessibilityStatus: AccessibilityAuthorizationStatus?

    override init() {
        let dsStoreCleaner: DSStoreCleaner = DSStoreCleaner()
        self.preferencesStore = PreferencesStore()
        self.appViewModel = AppViewModel(cleaner: dsStoreCleaner)
        self.loginItemService = LoginItemService()
        self.hotKeyManager = GlobalHotKeyManager()
        self.automationService = FinderAutomationService()
        self.dsStoreMaintenanceService = DSStoreMaintenanceService(cleaner: dsStoreCleaner)
        self.globalWindowPlacementService = GlobalWindowPlacementService()
        self.windowFocusService = WindowFocusService()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureViewModel()
        installInterface()
        observePreferences()
        apply(preferences: preferencesStore.preferences, source: .startup)
        automationService.start()
        globalWindowPlacementService.start()
        windowFocusService.start()
        refreshAccessibilityState(force: true)
        startAccessibilityRefreshMonitoring()

        let defaults: UserDefaults = .standard
        if !defaults.bool(forKey: Self.didCompleteFirstLaunchKey) {
            defaults.set(true, forKey: Self.didCompleteFirstLaunchKey)
            showSettings()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshAccessibilityState(force: false)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        accessibilityRefreshTask?.cancel()
        accessibilityRefreshTask = nil
        _ = hotKeyManager.unregister()
        automationService.stop()
        dsStoreMaintenanceService.stop()
        globalWindowPlacementService.stop()
        windowFocusService.stop()
    }

    private func configureViewModel() {
        appViewModel.configure(
            accessibilityStatus: { [weak self] in
                guard let self else { return false }
                _ = self.windowFocusService.refreshAccessibilityAuthorization()
                self.globalWindowPlacementService.refreshAccessibilityAuthorization()
                return self.automationService.refreshAccessibilityAuthorization() == .authorized
            },
            requestAccessibility: { [weak self] in
                self?.automationService.requestAccessibilityAuthorization()
                self?.globalWindowPlacementService.refreshAccessibilityAuthorization()
                self?.windowFocusService.refreshAccessibilityAuthorization()
                AccessibilityPermissionController.openSystemSettings()
            },
            applyRules: { [weak self] in
                guard let self else {
                    return .failure("FinderFix is not running.")
                }
                let configuration: FinderAutomationConfiguration = self.automationService.configuration
                let report: FinderWindowApplicationReport = await self.automationService
                    .applyRulesToExistingFinderWindows(promptForAutomationAuthorization: true)
                let globalPreferenceResult: FinderAutomationOperationResult = await self
                    .automationService.applyGlobalFinderPreferences(
                    promptForAuthorization: true
                )
                return Self.ruleApplicationFeedback(
                    report: report,
                    globalPreferenceResult: globalPreferenceResult,
                    configuration: configuration
                )
            },
            openFinder: {
                Self.openFinder()
            }
        )
        appViewModel.configureDSStoreMaintenance(
            folderPaths: { [weak self] in
                self?.preferencesStore.preferences.dsStoreCleanupFolderPaths ?? []
            },
            updateFolderPaths: { [weak self] paths in
                guard let self else { return }
                self.preferencesStore.preferences.dsStoreCleanupFolderPaths = paths
                if paths.isEmpty,
                   self.preferencesStore.preferences.dsStoreCleanupScope == .selectedFolders {
                    self.preferencesStore.preferences.automaticDSStoreCleanupEnabled = false
                }
            }
        )

        dsStoreMaintenanceService.eventHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case let .failure(message):
                self.appViewModel.reportFailure(message)
            case let .warning(message):
                self.appViewModel.reportWarning(message)
            case let .success(message):
                self.appViewModel.reportSuccess(message)
            case .ready, .working:
                break
            }
        }

        automationService.eventHandler = { [weak self] event in
            guard let self else { return }
            switch event {
            case let .accessibilityChanged(status):
                self.observedAccessibilityStatus = status
                self.appViewModel.setAccessibilityTrusted(status == .authorized)
                self.globalWindowPlacementService.refreshAccessibilityAuthorization()
                _ = self.windowFocusService.refreshAccessibilityAuthorization()
            case .finderDialogPlacement(.applied):
                self.windowFocusService.suppressUntilPointerMoves()
            case let .finderWindowRule(.failed(failure)),
                 let .finderWindowAppearance(.failed(failure)),
                 let .finderDialogPlacement(.failed(failure)):
                self.appViewModel.reportFailure(Self.message(for: failure))
            default:
                break
            }
        }

        windowFocusService.stateDidChange = { [weak self] state in
            guard let self else { return }
            self.appViewModel.setWindowFocusRuntimeState(state)
            self.statusItemController?.setWindowFocus(
                enabled: self.preferencesStore.preferences.windowFocus.isEnabled,
                runtimeState: state
            )
        }
    }

    private func installInterface() {
        let fileTypesView: AnyView = AnyView(AssociationManagerView())
        let settingsView: SettingsRootView = SettingsRootView(
            preferencesStore: preferencesStore,
            appViewModel: appViewModel,
            fileTypesView: fileTypesView
        )
        settingsWindowController = SettingsWindowController(rootView: settingsView)

        statusItemController = StatusItemController(
            actions: StatusItemController.Actions(
                togglePreference: { [weak self] toggle in
                    self?.togglePreference(toggle)
                },
                requestAccessibility: { [weak self] in self?.appViewModel.requestAccessibility() },
                setWindowFocusSuspended: { [weak self] suspended in
                    self?.windowFocusService.setTemporarilySuspended(suspended)
                },
                openFinder: { [weak self] in self?.appViewModel.openFinder() },
                applyRules: { [weak self] in self?.appViewModel.applyRulesNow() },
                showSettings: { [weak self] in self?.showSettings() },
                quit: { NSApplication.shared.terminate(nil) }
            )
        )
    }

    private func observePreferences() {
        preferencesSubscription = preferencesStore.$preferences
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] preferences in
                self?.apply(preferences: preferences, source: .userChange)
            }
    }

    private func apply(
        preferences: FinderFixPreferences,
        source: PreferenceApplicationSource
    ) {
        let previousPreferences: FinderFixPreferences? = lastAppliedPreferences
        let previousConfiguration: FinderAutomationConfiguration = automationService.configuration
        let configuration: FinderAutomationConfiguration = FinderAutomationConfiguration(
            preferences: preferences
        )
        automationService.updateConfiguration(configuration)
        let dsStoreRoots: [URL] = DSStoreMaintenanceService.roots(
            for: preferences.dsStoreCleanupScope,
            selectedFolderPaths: preferences.dsStoreCleanupFolderPaths
        )
        dsStoreMaintenanceService.update(
            configuration: DSStoreMaintenanceConfiguration(
                isEnabled: preferences.automaticDSStoreCleanupEnabled,
                roots: dsStoreRoots
            )
        )
        globalWindowPlacementService.updateConfiguration(
            Self.globalWindowPlacementConfiguration(preferences: preferences)
        )
        statusItemController?.setPreferences(preferences)
        statusItemController?.setVisible(preferences.showMenuBarItem)
        windowFocusService.updateConfiguration(preferences.windowFocus)
        statusItemController?.setWindowFocus(
            enabled: preferences.windowFocus.isEnabled,
            runtimeState: windowFocusService.runtimeState
        )

        let newlyEnabledAccessibilityFeature: Bool = (
            previousPreferences?.windowFocus.isEnabled != true
                && preferences.windowFocus.isEnabled
        ) || (
            previousPreferences?.globalWindowPlacement.isEnabled != true
                && preferences.globalWindowPlacement.isEnabled
        )
        if source == .userChange,
           newlyEnabledAccessibilityFeature,
           AccessibilityPermissionController.status != .authorized {
            appViewModel.requestAccessibility()
        }

        if previousPreferences?.globalShortcutEnabled != preferences.globalShortcutEnabled {
            let result: Result<Void, GlobalHotKeyError>
            if preferences.globalShortcutEnabled {
                result = hotKeyManager.register { [weak self] in
                    self?.appViewModel.openFinder()
                }
            } else {
                result = hotKeyManager.unregister()
            }
            if case let .failure(error) = result {
                appViewModel.reportFailure(error.localizedDescription)
            }
        }

        if previousPreferences?.launchAtLogin != preferences.launchAtLogin {
            do {
                let result: LoginItemUpdateResult
                if loginItemService.isEnabled == preferences.launchAtLogin {
                    result = .unchanged(loginItemService.status)
                } else {
                    result = try loginItemService.setEnabled(preferences.launchAtLogin)
                }

                if preferences.launchAtLogin
                    && (result == .requiresApproval || loginItemService.status == .requiresApproval) {
                    appViewModel.reportFailure(
                        "Launch at login needs approval in System Settings → General → Login Items."
                    )
                    if source == .userChange {
                        loginItemService.openSystemSettingsLoginItems()
                    }
                }
            } catch {
                appViewModel.reportFailure(error.localizedDescription)
            }
        }

        lastAppliedPreferences = preferences

        if previousConfiguration.openFoldersInNewTabs != configuration.openFoldersInNewTabs,
           automationService.isStarted {
            Task { [weak self] in
                guard let self else { return }
                let result: FinderAutomationOperationResult = await self.automationService
                    .applyGlobalFinderPreferences(promptForAuthorization: true)
                if case let .failed(failure) = result {
                    self.appViewModel.reportFailure(Self.message(for: failure))
                }
            }
        }
    }

    private func showSettings() {
        settingsWindowController?.present()
    }

    private func togglePreference(_ toggle: StatusItemController.PreferenceToggle) {
        if toggle == .showMenuBarItem,
           preferencesStore.preferences.showMenuBarItem {
            DispatchQueue.main.async { [weak self] in
                self?.commitPreferenceToggle(toggle)
            }
            return
        }

        if toggle == .automaticDSStoreCleanup {
            toggleAutomaticDSStoreCleanup()
            return
        }

        commitPreferenceToggle(toggle)
    }

    private func commitPreferenceToggle(_ toggle: StatusItemController.PreferenceToggle) {
        var preferences: FinderFixPreferences = preferencesStore.preferences
        switch toggle {
        case .launchAtLogin:
            preferences.launchAtLogin.toggle()
        case .showMenuBarItem:
            preferences.showMenuBarItem.toggle()
        case .globalShortcutEnabled:
            preferences.globalShortcutEnabled.toggle()
        case .globalWindowPlacement:
            preferences.globalWindowPlacement.isEnabled.toggle()
        case .finderWindowRules:
            preferences.windowRulesEnabled.toggle()
        case .resizeFinderWindows:
            preferences.resizeWindows.toggle()
        case .repositionFinderWindows:
            preferences.repositionWindows.toggle()
        case .finderChrome:
            preferences.finderChromeEnabled.toggle()
        case .finderSidebar:
            preferences.finderChrome.showSidebar.toggle()
        case .finderToolbar:
            preferences.finderChrome.showToolbar.toggle()
        case .finderPathBar:
            preferences.finderChrome.showPathBar.toggle()
        case .finderStatusBar:
            preferences.finderChrome.showStatusBar.toggle()
        case .eligibleFinderDialogs:
            preferences.moveEligibleFinderDialogs.toggle()
        case .bringFinderDialogsForward:
            preferences.bringFinderDialogsForward.toggle()
        case .focusFollowsPointer:
            preferences.windowFocus.isEnabled.toggle()
        case .requirePointerStop:
            preferences.windowFocus.requirePointerStop.toggle()
        case .automaticDSStoreCleanup:
            preferences.automaticDSStoreCleanupEnabled.toggle()
        }
        preferencesStore.preferences = preferences
    }

    private func toggleAutomaticDSStoreCleanup() {
        let preferences: FinderFixPreferences = preferencesStore.preferences
        if preferences.automaticDSStoreCleanupEnabled {
            commitPreferenceToggle(.automaticDSStoreCleanup)
            return
        }

        switch preferences.dsStoreCleanupScope {
        case .selectedFolders:
            guard !preferences.dsStoreCleanupFolderPaths.isEmpty else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.appViewModel.reportWarning(
                        "Choose at least one folder in Maintenance before enabling automatic .DS_Store cleanup."
                    )
                    self.showSettings()
                }
                return
            }
            commitPreferenceToggle(.automaticDSStoreCleanup)
        case .systemWide:
            DispatchQueue.main.async { [weak self] in
                self?.confirmSystemWideDSStoreCleanup()
            }
        }
    }

    private func confirmSystemWideDSStoreCleanup() {
        let currentPreferences: FinderFixPreferences = preferencesStore.preferences
        guard currentPreferences.dsStoreCleanupScope == .systemWide,
              !currentPreferences.automaticDSStoreCleanupEnabled else {
            return
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert: NSAlert = NSAlert()
        alert.messageText = "Enable Automatic .DS_Store Cleanup?"
        alert.informativeText = "FinderFix will move .DS_Store files in your Home folder and /Applications to the Trash as they are created or updated. This can reset Finder view settings in those folders."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Enable for Home and Applications")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var updatedPreferences: FinderFixPreferences = preferencesStore.preferences
        guard updatedPreferences.dsStoreCleanupScope == .systemWide else { return }
        updatedPreferences.automaticDSStoreCleanupEnabled = true
        preferencesStore.preferences = updatedPreferences
    }

    private func startAccessibilityRefreshMonitoring() {
        guard accessibilityRefreshTask == nil else { return }
        accessibilityRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.refreshAccessibilityState(force: false)
            }
        }
    }

    private func refreshAccessibilityState(force: Bool) {
        let currentStatus: AccessibilityAuthorizationStatus = AccessibilityPermissionController.status
        globalWindowPlacementService.refreshAccessibilityAuthorization()
        guard force || observedAccessibilityStatus != currentStatus else {
            appViewModel.setAccessibilityTrusted(currentStatus == .authorized)
            return
        }
        observedAccessibilityStatus = currentStatus
        let status: AccessibilityAuthorizationStatus = automationService
            .refreshAccessibilityAuthorization()
        globalWindowPlacementService.refreshAccessibilityAuthorization()
        _ = windowFocusService.refreshAccessibilityAuthorization()
        appViewModel.setAccessibilityTrusted(status == .authorized)
    }

    private static func openFinder() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser)
    }

    private static func globalWindowPlacementConfiguration(
        preferences: FinderFixPreferences
    ) -> GlobalWindowPlacementSettings {
        var configuration: GlobalWindowPlacementSettings = preferences.globalWindowPlacement
            .normalized()
        if preferences.windowRulesEnabled,
           !configuration.excludedApplicationBundleIdentifiers.contains(where: { identifier in
               identifier.caseInsensitiveCompare(FinderAutomationService.finderBundleIdentifier)
                   == .orderedSame
           }) {
            // Finder's more specific geometry rule wins when both features are enabled.
            configuration.excludedApplicationBundleIdentifiers.append(
                FinderAutomationService.finderBundleIdentifier
            )
        }
        return configuration.normalized()
    }

    private static func message(for failure: FinderAutomationFailure) -> String {
        switch failure {
        case let .accessibilityError(code):
            "Accessibility could not apply a Finder rule (error \(code))."
        case let .observerError(code):
            "FinderFix could not observe Finder windows (error \(code))."
        case let .appleEventError(code):
            "Finder did not accept an appearance setting (error \(code))."
        }
    }

    static func ruleApplicationFeedback(
        report: FinderWindowApplicationReport,
        globalPreferenceResult: FinderAutomationOperationResult,
        configuration: FinderAutomationConfiguration
    ) -> AppViewModel.ActivityState {
        var results: [FinderAutomationOperationResult] = report.operationResults
        if configuration.openFoldersInNewTabs != nil {
            results.append(globalPreferenceResult)
        }

        if results.isEmpty {
            if configuration.dialogs.isEnabled {
                return .warning(
                    "Finder dialog placement is active for new eligible dialogs; there is nothing to apply now."
                )
            }
            return .warning("No Finder rules are enabled.")
        }

        let appliedCount: Int = results.reduce(into: 0) { count, result in
            if result == .applied {
                count += 1
            }
        }
        let blockingMessages: [String] = results.compactMap(blockingMessage(for:))
        if let firstBlockingMessage: String = blockingMessages.first {
            if appliedCount > 0 {
                return .warning("Some Finder rules were applied. \(firstBlockingMessage)")
            }
            let hasFailure: Bool = results.contains { result in
                if case .failed = result { return true }
                return false
            }
            return hasFailure
                ? .failure(firstBlockingMessage)
                : .warning(firstBlockingMessage)
        }

        if appliedCount > 0 {
            if report.examined > 0 {
                return .success(
                    "Applied Finder rules; \(report.applied) of \(report.examined) existing windows changed."
                )
            }
            return .success("Applied the enabled Finder appearance and preference rules.")
        }

        return .warning("No immediate changes were needed. New eligible Finder windows and dialogs remain covered.")
    }

    private static func blockingMessage(
        for result: FinderAutomationOperationResult
    ) -> String? {
        switch result {
        case let .failed(failure):
            return message(for: failure)
        case let .skipped(reason):
            switch reason {
            case .disabled:
                return "No Finder rules are enabled."
            case .accessibilityNotAuthorized:
                return "Window placement needs Accessibility permission."
            case .finderUnavailable:
                return "Finder is not available."
            case .automationConsentRequired:
                return "Allow FinderFix to control Finder when macOS asks, then try again."
            case .automationDenied:
                return "Finder Automation is denied in System Settings → Privacy & Security → Automation."
            case .windowChangedBeforeApplication:
                return "A Finder window changed before its rules could be applied."
            case .protectedOrSecureUI,
                 .unsupportedAttribute,
                 .invalidGeometry,
                 .notEligible,
                 .existingWindow:
                return nil
            }
        case .applied, .noChanges:
            return nil
        }
    }
}
