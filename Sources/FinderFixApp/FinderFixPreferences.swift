import Foundation
import FinderFixCore

enum FinderWindowPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case centered
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .centered: "Centered"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .custom: "Custom Offset"
        }
    }
}

enum FinderDisplayTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case primary
    case pointer
    case current

    var id: String { rawValue }

    var title: String {
        switch self {
        case .primary: "Primary Display"
        case .pointer: "Display Under Pointer"
        case .current: "Current Display"
        }
    }
}

enum FinderViewStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case unchanged
    case icons
    case list
    case columns
    case gallery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unchanged: "Leave Unchanged"
        case .icons: "Icons"
        case .list: "List"
        case .columns: "Columns"
        case .gallery: "Gallery"
        }
    }
}

enum FinderFolderOpeningBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case unchanged
    case tabs
    case windows

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unchanged: "Leave Unchanged"
        case .tabs: "Open in Tabs"
        case .windows: "Open in Windows"
        }
    }

    var openFoldersInNewTabs: Bool? {
        switch self {
        case .unchanged: nil
        case .tabs: true
        case .windows: false
        }
    }
}

struct FinderChromePreferences: Codable, Equatable, Sendable {
    var viewStyle: FinderViewStyle = .unchanged
    var showSidebar: Bool = true
    var showToolbar: Bool = true
    var showPathBar: Bool = true
    var showStatusBar: Bool = true
    var sidebarWidth: Double = 190
}

struct FinderFixPreferences: Codable, Equatable, Sendable {
    static let currentVersion: Int = 3

    var schemaVersion: Int = currentVersion
    var launchAtLogin: Bool = false
    var showMenuBarItem: Bool = true
    var globalShortcutEnabled: Bool = true

    var windowRulesEnabled: Bool = false
    var resizeWindows: Bool = true
    var windowWidth: Double = 1_100
    var windowHeight: Double = 720
    var repositionWindows: Bool = true
    var windowPosition: FinderWindowPosition = .centered
    var displayTarget: FinderDisplayTarget = .pointer
    var horizontalOffset: Double = 40
    var verticalOffset: Double = 40

    var finderChromeEnabled: Bool = false
    var finderChrome: FinderChromePreferences = FinderChromePreferences()
    var folderOpeningBehavior: FinderFolderOpeningBehavior = .unchanged

    var moveEligibleFinderDialogs: Bool = false
    var bringFinderDialogsForward: Bool = true

    var globalWindowPlacement: GlobalWindowPlacementSettings = .defaults
    var windowFocus: WindowFocusSettings = .defaults

    var automaticDSStoreCleanupEnabled: Bool = false
    var dsStoreCleanupScope: DSStoreCleanupScope = .selectedFolders
    var dsStoreCleanupFolderPaths: [String] = []

    func normalized() -> FinderFixPreferences {
        var value: FinderFixPreferences = self
        value.schemaVersion = Self.currentVersion
        value.windowWidth = Self.clampedFinite(
            windowWidth,
            range: 320...10_000,
            fallback: 1_100
        )
        value.windowHeight = Self.clampedFinite(
            windowHeight,
            range: 240...10_000,
            fallback: 720
        )
        value.horizontalOffset = Self.clampedFinite(
            horizontalOffset,
            range: -10_000...10_000,
            fallback: 40
        )
        value.verticalOffset = Self.clampedFinite(
            verticalOffset,
            range: -10_000...10_000,
            fallback: 40
        )
        value.finderChrome.sidebarWidth = Self.clampedFinite(
            finderChrome.sidebarWidth,
            range: 120...360,
            fallback: 190
        )
        value.globalWindowPlacement = globalWindowPlacement.normalized()
        value.windowFocus = windowFocus.normalized()
        value.dsStoreCleanupFolderPaths = Self.normalizedFolderPaths(
            dsStoreCleanupFolderPaths
        )
        if value.dsStoreCleanupScope == .selectedFolders,
           value.dsStoreCleanupFolderPaths.isEmpty {
            value.automaticDSStoreCleanupEnabled = false
        }
        return value
    }

    private static func clampedFinite(
        _ value: Double,
        range: ClosedRange<Double>,
        fallback: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func normalizedFolderPaths(_ paths: [String]) -> [String] {
        var seenPaths: Set<String> = []
        var normalizedPaths: [String] = []
        for path in paths.prefix(64) {
            let trimmedPath: String = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPath.isEmpty else { continue }
            let normalizedPath: String = URL(
                fileURLWithPath: trimmedPath,
                isDirectory: true
            ).standardizedFileURL.resolvingSymlinksInPath().path
            guard seenPaths.insert(normalizedPath).inserted else { continue }
            normalizedPaths.append(normalizedPath)
        }
        return normalizedPaths.sorted()
    }
}
