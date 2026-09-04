import FinderFixCore
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case overview
    case dialogsAndWindows
    case windowFocus
    case fileTypes
    case maintenance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .dialogsAndWindows: "Dialogs and Windows"
        case .windowFocus: "Window Focus"
        case .fileTypes: "File Types"
        case .maintenance: "Maintenance"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .dialogsAndWindows: "macwindow.on.rectangle"
        case .windowFocus: "cursorarrow"
        case .fileTypes: "doc.badge.gearshape"
        case .maintenance: "wrench.and.screwdriver"
        }
    }
}

struct SettingsRootView: View {
    @ObservedObject var preferencesStore: PreferencesStore
    @ObservedObject var appViewModel: AppViewModel
    let fileTypesView: AnyView

    @State private var selectedPage: SettingsPage? = .overview

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $selectedPage) { page in
                Label(page.title, systemImage: page.symbolName)
                    .tag(page)
            }
            .navigationSplitViewColumnWidth(min: 176, ideal: 196)
        } detail: {
            Group {
                switch selectedPage ?? .overview {
                case .overview:
                    OverviewSettingsView(
                        preferencesStore: preferencesStore,
                        appViewModel: appViewModel
                    )
                case .dialogsAndWindows:
                    DialogsAndWindowsSettingsView(preferencesStore: preferencesStore)
                case .windowFocus:
                    WindowFocusSettingsView(
                        preferencesStore: preferencesStore,
                        appViewModel: appViewModel
                    )
                case .fileTypes:
                    fileTypesView
                case .maintenance:
                    MaintenanceSettingsView(
                        preferencesStore: preferencesStore,
                        appViewModel: appViewModel
                    )
                }
            }
            .frame(minWidth: 600, minHeight: 540)
        }
        .tint(ArcaneTokens.accent)
    }
}

private struct OverviewSettingsView: View {
    @ObservedObject var preferencesStore: PreferencesStore
    @ObservedObject var appViewModel: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ArcaneTokens.sectionSpacing) {
                ArcaneSectionHeader(
                    title: "Finder, fixed.",
                    detail: "Keep Finder windows consistent, put eligible dialogs where you can see them, and optionally focus windows with the pointer."
                )

                ArcaneCard {
                    HStack(alignment: .center, spacing: 16) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 74, height: 74)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 7) {
                            Text("FinderFix")
                                .font(.title2.weight(.bold))
                            if appViewModel.accessibilityTrusted {
                                ArcaneStatusBadge(text: "Accessibility Ready", tone: .positive)
                            } else {
                                ArcaneStatusBadge(text: "Accessibility Needed", tone: .warning)
                            }
                            Text("Runs quietly from the menu bar. No beta timer, updater, analytics, or private network service.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }

                if !appViewModel.accessibilityTrusted {
                    ArcaneCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Allow Accessibility", systemImage: "hand.raised.fill")
                                .font(.headline)
                            Text("macOS requires this permission before FinderFix can observe, position, or focus windows. It inspects window structure and geometry only; pointer positions are processed locally and never stored.")
                                .foregroundStyle(.secondary)
                            Button("Open Accessibility Settings") {
                                appViewModel.requestAccessibility()
                            }
                            .buttonStyle(ArcanePrimaryButtonStyle())
                        }
                    }
                }

                if !hasEnabledFinderRules {
                    ArcaneCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Choose what FinderFix may change", systemImage: "slider.horizontal.3")
                                .font(.headline)
                            Text("FinderFix starts with every Finder-changing rule off. Enable the recommended window, chrome, and eligible-dialog rules, then adjust them in Dialogs & Windows.")
                                .foregroundStyle(.secondary)
                            Button("Enable Recommended Rules") {
                                preferencesStore.enableRecommendedRules()
                            }
                            .buttonStyle(ArcanePrimaryButtonStyle())
                        }
                    }
                }

                ArcaneCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Quick Actions")
                            .font(.headline)
                        HStack(spacing: 10) {
                            Button("Apply Rules Now") {
                                appViewModel.applyRulesNow()
                            }
                            .buttonStyle(ArcanePrimaryButtonStyle())
                            .disabled(appViewModel.isApplyingRules)
                            Button("Open Finder") {
                                appViewModel.openFinder()
                            }
                            Button("Check Permission") {
                                appViewModel.refreshAccessibilityStatus()
                            }
                        }
                        ActivityMessageView(activity: appViewModel.activity)
                    }
                }

                ArcaneCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Open FinderFix at login", isOn: preferenceBinding(\.launchAtLogin))
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Show FinderFix in the menu bar", isOn: preferenceBinding(\.showMenuBarItem))
                            Text("If you hide the menu-bar item, reopen FinderFix from Applications or Spotlight to show Settings and turn it back on.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Toggle("Use ⌥⌘F to open Finder", isOn: preferenceBinding(\.globalShortcutEnabled))
                    }
                }
            }
            .arcaneSettingsPage()
        }
    }

    private func preferenceBinding<Value>(_ keyPath: WritableKeyPath<FinderFixPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { preferencesStore.preferences[keyPath: keyPath] },
            set: { value in preferencesStore.preferences[keyPath: keyPath] = value }
        )
    }

    private var hasEnabledFinderRules: Bool {
        preferencesStore.preferences.windowRulesEnabled
            || preferencesStore.preferences.finderChromeEnabled
            || preferencesStore.preferences.moveEligibleFinderDialogs
    }
}

private struct DialogsAndWindowsSettingsView: View {
    @ObservedObject var preferencesStore: PreferencesStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ArcaneTokens.sectionSpacing) {
                ArcaneSectionHeader(
                    title: "Dialogs and Windows",
                    detail: "Place new windows where you expect them, keep Finder consistent, and move eligible Finder dialogs to the main display."
                )

                ArcaneCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(
                            "Place new app windows on the main display",
                            isOn: globalWindowBinding(\.isEnabled)
                        )
                        .font(.headline)
                        Divider()
                        Group {
                            LabeledContent("Aspect ratio") {
                                HStack(spacing: 7) {
                                    TextField(
                                        "Width",
                                        value: globalWindowBinding(\.aspectRatioWidth),
                                        format: .number
                                    )
                                    .frame(width: 64)
                                    Text(":")
                                        .foregroundStyle(.secondary)
                                    TextField(
                                        "Height",
                                        value: globalWindowBinding(\.aspectRatioHeight),
                                        format: .number
                                    )
                                    .frame(width: 64)
                                }
                            }
                            LabeledContent("Display coverage") {
                                HStack(spacing: 10) {
                                    Slider(
                                        value: globalWindowBinding(\.screenCoverage),
                                        in: GlobalWindowPlacementSettings.supportedCoverageRange,
                                        step: 0.05
                                    )
                                    .frame(width: 190)
                                    Text(globalWindowCoverageLabel)
                                        .monospacedDigit()
                                        .frame(width: 42, alignment: .trailing)
                                }
                            }
                        }
                        .disabled(!preferencesStore.preferences.globalWindowPlacement.isEnabled)
                        Text("FinderFix handles each eligible window once when it opens. Move it anywhere afterward and FinderFix leaves it there.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                ArcaneCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Apply rules to new Finder windows", isOn: preferenceBinding(\.windowRulesEnabled))
                            .font(.headline)
                        Divider()
                        Toggle("Resize windows", isOn: preferenceBinding(\.resizeWindows))
                        HStack {
                            LabeledContent("Width") {
                                TextField("Width", value: preferenceBinding(\.windowWidth), format: .number)
                                    .frame(width: 88)
                            }
                            LabeledContent("Height") {
                                TextField("Height", value: preferenceBinding(\.windowHeight), format: .number)
                                    .frame(width: 88)
                            }
                        }
                        .disabled(!preferencesStore.preferences.resizeWindows)
                        Toggle("Reposition windows", isOn: preferenceBinding(\.repositionWindows))
                        Picker("Target display", selection: preferenceBinding(\.displayTarget)) {
                            ForEach(FinderDisplayTarget.allCases) { target in
                                Text(target.title).tag(target)
                            }
                        }
                        .disabled(!preferencesStore.preferences.repositionWindows)
                        Picker("Position", selection: preferenceBinding(\.windowPosition)) {
                            ForEach(FinderWindowPosition.allCases) { position in
                                Text(position.title).tag(position)
                            }
                        }
                        .disabled(!preferencesStore.preferences.repositionWindows)
                        if preferencesStore.preferences.windowPosition == .custom {
                            HStack {
                                LabeledContent("Horizontal") {
                                    TextField("X", value: preferenceBinding(\.horizontalOffset), format: .number)
                                        .frame(width: 88)
                                }
                                LabeledContent("Vertical") {
                                    TextField("Y", value: preferenceBinding(\.verticalOffset), format: .number)
                                        .frame(width: 88)
                                }
                            }
                        }
                    }
                }

                ArcaneCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Apply Finder view and chrome", isOn: preferenceBinding(\.finderChromeEnabled))
                            .font(.headline)
                        Divider()
                        Group {
                            Picker("Default view", selection: chromeBinding(\.viewStyle)) {
                                ForEach(FinderViewStyle.allCases) { style in
                                    Text(style.title).tag(style)
                                }
                            }
                            Toggle("Show sidebar", isOn: chromeBinding(\.showSidebar))
                            Toggle("Show toolbar", isOn: chromeBinding(\.showToolbar))
                            Toggle("Show path bar", isOn: chromeBinding(\.showPathBar))
                            Toggle("Show status bar", isOn: chromeBinding(\.showStatusBar))
                            LabeledContent("Sidebar width") {
                                HStack {
                                    Slider(value: chromeBinding(\.sidebarWidth), in: 120...360, step: 5)
                                        .frame(width: 190)
                                    Text("\(safeSidebarWidth) pt")
                                        .monospacedDigit()
                                        .frame(width: 52, alignment: .trailing)
                                }
                            }
                        }
                        .disabled(!preferencesStore.preferences.finderChromeEnabled)
                    }
                }

                ArcaneCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("When opening folders", selection: preferenceBinding(\.folderOpeningBehavior)) {
                            ForEach(FinderFolderOpeningBehavior.allCases) { behavior in
                                Text(behavior.title).tag(behavior)
                            }
                        }
                        Text("Leave Unchanged preserves Finder’s current global setting. Choosing Tabs or Windows asks macOS for Automation permission when the setting is applied.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                ArcaneCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(
                            "Move eligible Finder dialogs to the main display",
                            isOn: preferenceBinding(\.moveEligibleFinderDialogs)
                        )
                        .font(.headline)
                        Toggle(
                            "Bring moved dialogs forward",
                            isOn: preferenceBinding(\.bringFinderDialogsForward)
                        )
                        .disabled(!preferencesStore.preferences.moveEligibleFinderDialogs)
                    }
                }

                ArcaneCard {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("Deliberately limited", systemImage: "lock.shield")
                            .font(.headline)
                        Text("FinderFix moves only standalone, writable Finder dialogs identified through Accessibility. It skips attached sheets, authentication, privacy, login, lock-screen, and system-wide security interfaces. Bringing a dialog forward is best effort because macOS keeps final control of focus.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .arcaneSettingsPage()
        }
    }

    private func globalWindowBinding<Value>(
        _ keyPath: WritableKeyPath<GlobalWindowPlacementSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { preferencesStore.preferences.globalWindowPlacement[keyPath: keyPath] },
            set: { value in
                preferencesStore.preferences.globalWindowPlacement[keyPath: keyPath] = value
            }
        )
    }

    private func preferenceBinding<Value>(_ keyPath: WritableKeyPath<FinderFixPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { preferencesStore.preferences[keyPath: keyPath] },
            set: { value in preferencesStore.preferences[keyPath: keyPath] = value }
        )
    }

    private func chromeBinding<Value>(_ keyPath: WritableKeyPath<FinderChromePreferences, Value>) -> Binding<Value> {
        Binding(
            get: { preferencesStore.preferences.finderChrome[keyPath: keyPath] },
            set: { value in preferencesStore.preferences.finderChrome[keyPath: keyPath] = value }
        )
    }

    private var safeSidebarWidth: Int {
        Int(preferencesStore.preferences.normalized().finderChrome.sidebarWidth.rounded())
    }

    private var globalWindowCoverageLabel: String {
        let coverage: Double = preferencesStore.preferences.globalWindowPlacement.screenCoverage
        return "\(Int((coverage * 100).rounded()))%"
    }
}

private struct MaintenanceSettingsView: View {
    @ObservedObject var preferencesStore: PreferencesStore
    @ObservedObject var appViewModel: AppViewModel
    @State private var showingSystemWideConfirmation: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ArcaneTokens.sectionSpacing) {
                ArcaneSectionHeader(
                    title: "Maintenance",
                    detail: "Clean Finder metadata safely and reset this version’s settings."
                )
                ArcaneCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(
                            "Move .DS_Store files to Trash automatically",
                            isOn: automaticCleanupBinding
                        )
                        .font(.headline)
                        .disabled(
                            preferencesStore.preferences.dsStoreCleanupScope == .selectedFolders
                                && preferencesStore.preferences.dsStoreCleanupFolderPaths.isEmpty
                                && !preferencesStore.preferences.automaticDSStoreCleanupEnabled
                        )
                        Divider()
                        Picker("Scope", selection: cleanupScopeBinding) {
                            ForEach(DSStoreCleanupScope.allCases) { scope in
                                Text(scope.title).tag(scope)
                            }
                        }
                        .pickerStyle(.segmented)

                        if preferencesStore.preferences.dsStoreCleanupScope == .selectedFolders {
                            selectedFoldersSection
                        } else {
                            Label {
                                Text("System-wide cleanup covers your Home folder and /Applications. Package contents, symbolic links, and inaccessible items are skipped.")
                            } icon: {
                                Image(systemName: "externaldrive.badge.checkmark")
                                    .foregroundStyle(ArcaneTokens.warning)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        Text("Automatic cleanup runs when Finder creates or updates this metadata. Moving it can reset per-folder view and icon-position settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .confirmationDialog(
                    "Enable System-Wide .DS_Store Cleanup?",
                    isPresented: $showingSystemWideConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Enable for Home and Applications", role: .destructive) {
                        preferencesStore.preferences.dsStoreCleanupScope = .systemWide
                        preferencesStore.preferences.automaticDSStoreCleanupEnabled = true
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("FinderFix will move .DS_Store files from your Home folder and /Applications to the Trash as they are created or updated. This can reset Finder view settings in those folders.")
                }

                ArcaneCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Clean once", systemImage: "trash")
                            .font(.headline)
                        Text(oneShotCleanupDetail)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button(oneShotCleanupButtonTitle) {
                                appViewModel.cleanDSStoreFilesNow(
                                    scope: preferencesStore.preferences.dsStoreCleanupScope
                                )
                            }
                            .disabled(
                                oneShotCleanupIsDisabled || appViewModel.isCleaningDSStoreFiles
                            )
                            Button("Choose Another Folder…") {
                                appViewModel.chooseFolderAndCleanDSStoreFiles()
                            }
                            .disabled(appViewModel.isCleaningDSStoreFiles)
                            if appViewModel.isCleaningDSStoreFiles {
                                Button("Stop Cleanup", role: .cancel) {
                                    appViewModel.cancelDSStoreCleanup()
                                }
                            }
                        }
                    }
                }
                ArcaneCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Reset FinderFix")
                            .font(.headline)
                        Text("Restore FinderFix preferences to their defaults. File-type associations are managed separately on the File Types page.")
                            .foregroundStyle(.secondary)
                        Button("Reset Preferences", role: .destructive) {
                            preferencesStore.resetToDefaults()
                        }
                    }
                }
                ActivityMessageView(activity: appViewModel.activity)
            }
            .arcaneSettingsPage()
        }
    }

    @ViewBuilder
    private var selectedFoldersSection: some View {
        if preferencesStore.preferences.dsStoreCleanupFolderPaths.isEmpty {
            Text("No folders chosen. Add at least one folder before automatic cleanup can run.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(preferencesStore.preferences.dsStoreCleanupFolderPaths, id: \.self) { path in
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)
                        Spacer(minLength: 8)
                        Button {
                            appViewModel.removeDSStoreCleanupFolder(path: path)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Remove this folder")
                        .accessibilityLabel("Remove \(path)")
                    }
                }
            }
        }

        Button("Add Folders…") {
            appViewModel.addDSStoreCleanupFolders()
        }
    }

    private var automaticCleanupBinding: Binding<Bool> {
        Binding(
            get: { preferencesStore.preferences.automaticDSStoreCleanupEnabled },
            set: { enabled in
                if enabled, preferencesStore.preferences.dsStoreCleanupScope == .systemWide {
                    showingSystemWideConfirmation = true
                } else {
                    preferencesStore.preferences.automaticDSStoreCleanupEnabled = enabled
                }
            }
        )
    }

    private var cleanupScopeBinding: Binding<DSStoreCleanupScope> {
        Binding(
            get: { preferencesStore.preferences.dsStoreCleanupScope },
            set: { scope in
                if scope == .systemWide,
                   preferencesStore.preferences.automaticDSStoreCleanupEnabled {
                    showingSystemWideConfirmation = true
                } else {
                    preferencesStore.preferences.dsStoreCleanupScope = scope
                }
            }
        )
    }

    private var oneShotCleanupButtonTitle: String {
        switch preferencesStore.preferences.dsStoreCleanupScope {
        case .selectedFolders:
            "Clean Chosen Folders"
        case .systemWide:
            "Clean Home and Applications"
        }
    }

    private var oneShotCleanupDetail: String {
        switch preferencesStore.preferences.dsStoreCleanupScope {
        case .selectedFolders:
            "Scan the chosen folders, review the number found, then move only their .DS_Store files to the Trash."
        case .systemWide:
            "Scan your Home folder and /Applications, review the number found, then move only .DS_Store files to the Trash."
        }
    }

    private var oneShotCleanupIsDisabled: Bool {
        preferencesStore.preferences.dsStoreCleanupScope == .selectedFolders
            && preferencesStore.preferences.dsStoreCleanupFolderPaths.isEmpty
    }
}

private struct ActivityMessageView: View {
    let activity: AppViewModel.ActivityState

    var body: some View {
        switch activity {
        case .ready:
            EmptyView()
        case let .working(message):
            Label(message, systemImage: "progress.indicator")
                .foregroundStyle(.secondary)
        case let .success(message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(ArcaneTokens.positive)
        case let .warning(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(ArcaneTokens.warning)
        case let .failure(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(ArcaneTokens.destructive)
        }
    }
}
