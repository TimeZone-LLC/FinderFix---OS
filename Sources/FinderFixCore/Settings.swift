import CoreGraphics
import Foundation

public struct WindowDimensions: Codable, Hashable, Sendable {
    public let width: CGFloat
    public let height: CGFloat

    public init?(width: CGFloat, height: CGFloat) {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            return nil
        }
        self.width = width
        self.height = height
    }

    public var cgSize: CGSize {
        CGSize(width: width, height: height)
    }

    public init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        let width: CGFloat = try container.decode(CGFloat.self, forKey: .width)
        let height: CGFloat = try container.decode(CGFloat.self, forKey: .height)

        guard let dimensions: WindowDimensions = WindowDimensions(width: width, height: height) else {
            throw DecodingError.dataCorruptedError(
                forKey: .width,
                in: container,
                debugDescription: "Window dimensions must be finite and greater than zero."
            )
        }
        self = dimensions
    }

    private enum CodingKeys: String, CodingKey {
        case width
        case height
    }
}

public enum WindowPlacement: Codable, Hashable, Sendable {
    case centered
    /// An offset in points from the target display's visible top-left corner.
    case topLeftOffset(x: CGFloat, y: CGFloat)
}

public struct WindowPlacementSettings: Codable, Hashable, Sendable {
    public var resizeTo: WindowDimensions?
    public var position: WindowPlacement?
    public var constrainToVisibleFrame: Bool
    public var applyToExistingWindows: Bool

    public init(
        resizeTo: WindowDimensions? = nil,
        position: WindowPlacement? = nil,
        constrainToVisibleFrame: Bool = true,
        applyToExistingWindows: Bool = false
    ) {
        self.resizeTo = resizeTo
        self.position = position
        self.constrainToVisibleFrame = constrainToVisibleFrame
        self.applyToExistingWindows = applyToExistingWindows
    }

    public static let defaults: WindowPlacementSettings = WindowPlacementSettings()
}

public enum FinderElementVisibility: String, Codable, CaseIterable, Hashable, Sendable {
    case unchanged
    case shown
    case hidden
}

public enum FinderViewMode: String, Codable, CaseIterable, Hashable, Sendable {
    case icon
    case list
    case column
    case gallery
}

public struct FinderChromeSettings: Codable, Hashable, Sendable {
    public var toolbar: FinderElementVisibility
    public var sidebar: FinderElementVisibility
    public var pathBar: FinderElementVisibility
    public var statusBar: FinderElementVisibility
    public var sidebarWidth: CGFloat?
    public var viewMode: FinderViewMode?

    public init(
        toolbar: FinderElementVisibility = .unchanged,
        sidebar: FinderElementVisibility = .unchanged,
        pathBar: FinderElementVisibility = .unchanged,
        statusBar: FinderElementVisibility = .unchanged,
        sidebarWidth: CGFloat? = nil,
        viewMode: FinderViewMode? = nil
    ) {
        self.toolbar = toolbar
        self.sidebar = sidebar
        self.pathBar = pathBar
        self.statusBar = statusBar
        self.sidebarWidth = sidebarWidth
        self.viewMode = viewMode
    }

    public static let defaults: FinderChromeSettings = FinderChromeSettings()
}

public struct FinderWindowSettings: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var placement: WindowPlacementSettings
    public var chrome: FinderChromeSettings

    public init(
        isEnabled: Bool = false,
        placement: WindowPlacementSettings = .defaults,
        chrome: FinderChromeSettings = .defaults
    ) {
        self.isEnabled = isEnabled
        self.placement = placement
        self.chrome = chrome
    }

    public static let defaults: FinderWindowSettings = FinderWindowSettings()
}

public enum DialogTargetDisplay: String, Codable, CaseIterable, Hashable, Sendable {
    case primary
}

public struct FinderDialogSettings: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var targetDisplay: DialogTargetDisplay
    public var raiseWhenFinderIsFrontmost: Bool

    public init(
        isEnabled: Bool = false,
        targetDisplay: DialogTargetDisplay = .primary,
        raiseWhenFinderIsFrontmost: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.targetDisplay = targetDisplay
        self.raiseWhenFinderIsFrontmost = raiseWhenFinderIsFrontmost
    }

    public static let defaults: FinderDialogSettings = FinderDialogSettings()
}

public enum WindowFocusPauseModifier: String, Codable, CaseIterable, Hashable, Sendable {
    case control
    case option
    case off

    public var title: String {
        switch self {
        case .control: "Control"
        case .option: "Option"
        case .off: "None"
        }
    }
}

public struct WindowFocusSettings: Codable, Hashable, Sendable {
    public static let maximumExcludedApplications: Int = 128

    public var isEnabled: Bool
    public var activationDelayMilliseconds: Int
    public var requirePointerStop: Bool
    public var pauseModifier: WindowFocusPauseModifier
    public var excludedApplicationBundleIdentifiers: [String]

    public init(
        isEnabled: Bool = false,
        activationDelayMilliseconds: Int = 250,
        requirePointerStop: Bool = true,
        pauseModifier: WindowFocusPauseModifier = .control,
        excludedApplicationBundleIdentifiers: [String] = []
    ) {
        self.isEnabled = isEnabled
        self.activationDelayMilliseconds = activationDelayMilliseconds
        self.requirePointerStop = requirePointerStop
        self.pauseModifier = pauseModifier
        self.excludedApplicationBundleIdentifiers = excludedApplicationBundleIdentifiers
    }

    public static let defaults: WindowFocusSettings = WindowFocusSettings()

    public func normalized() -> WindowFocusSettings {
        var value: WindowFocusSettings = self
        value.activationDelayMilliseconds = min(max(activationDelayMilliseconds, 0), 1_000)

        var seenIdentifiers: Set<String> = []
        var identifiers: [String] = []
        for identifier in excludedApplicationBundleIdentifiers.prefix(
            Self.maximumExcludedApplications
        ) {
            let trimmedIdentifier: String = String(
                identifier.trimmingCharacters(in: .whitespacesAndNewlines).prefix(255)
            )
            guard !trimmedIdentifier.isEmpty else { continue }
            let comparisonIdentifier: String = trimmedIdentifier.lowercased()
            guard seenIdentifiers.insert(comparisonIdentifier).inserted else { continue }
            identifiers.append(trimmedIdentifier)
        }
        value.excludedApplicationBundleIdentifiers = identifiers
        return value
    }
}

public struct FileAssociationSettings: Codable, Hashable, Sendable {
    public var confirmBulkChanges: Bool
    public var stopAfterConsentDenial: Bool

    public init(
        confirmBulkChanges: Bool = true,
        stopAfterConsentDenial: Bool = true
    ) {
        self.confirmBulkChanges = confirmBulkChanges
        self.stopAfterConsentDenial = stopAfterConsentDenial
    }

    public static let defaults: FileAssociationSettings = FileAssociationSettings()
}

public struct FinderFixSettings: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var launchAtLogin: Bool
    public var showMenuBarItem: Bool
    public var finderWindows: FinderWindowSettings
    public var finderDialogs: FinderDialogSettings
    public var globalWindowPlacement: GlobalWindowPlacementSettings
    public var windowFocus: WindowFocusSettings
    public var fileAssociations: FileAssociationSettings

    public init(
        isEnabled: Bool = true,
        launchAtLogin: Bool = false,
        showMenuBarItem: Bool = true,
        finderWindows: FinderWindowSettings = .defaults,
        finderDialogs: FinderDialogSettings = .defaults,
        globalWindowPlacement: GlobalWindowPlacementSettings = .defaults,
        windowFocus: WindowFocusSettings = .defaults,
        fileAssociations: FileAssociationSettings = .defaults
    ) {
        self.isEnabled = isEnabled
        self.launchAtLogin = launchAtLogin
        self.showMenuBarItem = showMenuBarItem
        self.finderWindows = finderWindows
        self.finderDialogs = finderDialogs
        self.globalWindowPlacement = globalWindowPlacement
        self.windowFocus = windowFocus
        self.fileAssociations = fileAssociations
    }

    /// Conservative defaults leave Finder behavior unchanged until the user
    /// explicitly enables a rule.
    public static let defaults: FinderFixSettings = FinderFixSettings()
}
