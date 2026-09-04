import CoreGraphics
import Foundation

public enum AccessibilityAuthorizationStatus: Sendable, Equatable {
    case authorized
    case notAuthorized
}

public enum FinderWindowDisplayTarget: Sendable, Equatable {
    /// The display that owns the menu bar and the global coordinate-space origin.
    case primary
    /// The display containing the pointer when the rule is applied.
    case pointer
    /// The display containing the largest portion of the Finder window.
    case currentWindow
}

public enum FinderWindowPositionRule: Sendable, Equatable {
    case unchanged
    case centered
    case topLeft(inset: CGFloat)
    case topRight(inset: CGFloat)
    case bottomLeft(inset: CGFloat)
    case bottomRight(inset: CGFloat)
    /// Offsets are measured from the visible frame's top-left corner.
    case topLeftOffset(x: CGFloat, y: CGFloat)
}

public struct FinderWindowRuleConfiguration: Sendable, Equatable {
    public var isEnabled: Bool
    public var size: CGSize?
    public var position: FinderWindowPositionRule
    public var display: FinderWindowDisplayTarget
    public var constrainToVisibleFrame: Bool

    public init(
        isEnabled: Bool = false,
        size: CGSize? = nil,
        position: FinderWindowPositionRule = .unchanged,
        display: FinderWindowDisplayTarget = .primary,
        constrainToVisibleFrame: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.size = size
        self.position = position
        self.display = display
        self.constrainToVisibleFrame = constrainToVisibleFrame
    }

    public static let disabled: FinderWindowRuleConfiguration = FinderWindowRuleConfiguration()
}

public enum FinderElementRule: Sendable, Equatable {
    case unchanged
    case shown
    case hidden
}

public enum FinderViewRule: Sendable, Equatable {
    case unchanged
    case icon
    case list
    case column
    case gallery
}

public struct FinderWindowAppearanceConfiguration: Sendable, Equatable {
    public var toolbar: FinderElementRule
    public var sidebar: FinderElementRule
    public var pathBar: FinderElementRule
    public var statusBar: FinderElementRule
    public var sidebarWidth: Int?
    public var view: FinderViewRule

    public init(
        toolbar: FinderElementRule = .unchanged,
        sidebar: FinderElementRule = .unchanged,
        pathBar: FinderElementRule = .unchanged,
        statusBar: FinderElementRule = .unchanged,
        sidebarWidth: Int? = nil,
        view: FinderViewRule = .unchanged
    ) {
        self.toolbar = toolbar
        self.sidebar = sidebar
        self.pathBar = pathBar
        self.statusBar = statusBar
        self.sidebarWidth = sidebarWidth
        self.view = view
    }

    public var hasChanges: Bool {
        toolbar != .unchanged
            || sidebar != .unchanged
            || pathBar != .unchanged
            || statusBar != .unchanged
            || sidebarWidth != nil
            || view != .unchanged
    }

    public static let unchanged: FinderWindowAppearanceConfiguration = FinderWindowAppearanceConfiguration()
}

public struct FinderDialogPlacementConfiguration: Sendable, Equatable {
    public var isEnabled: Bool
    /// Raising is attempted only when Finder was already frontmost when the dialog appeared.
    public var raiseWhenFinderIsFrontmost: Bool

    public init(
        isEnabled: Bool = false,
        raiseWhenFinderIsFrontmost: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.raiseWhenFinderIsFrontmost = raiseWhenFinderIsFrontmost
    }

    public static let disabled: FinderDialogPlacementConfiguration = FinderDialogPlacementConfiguration()
}

public struct FinderAutomationConfiguration: Sendable, Equatable {
    public var isEnabled: Bool
    public var windows: FinderWindowRuleConfiguration
    public var appearance: FinderWindowAppearanceConfiguration
    public var dialogs: FinderDialogPlacementConfiguration
    /// Finder's global "Open folders in tabs instead of new windows" preference.
    public var openFoldersInNewTabs: Bool?

    public init(
        isEnabled: Bool = true,
        windows: FinderWindowRuleConfiguration = .disabled,
        appearance: FinderWindowAppearanceConfiguration = .unchanged,
        dialogs: FinderDialogPlacementConfiguration = .disabled,
        openFoldersInNewTabs: Bool? = nil
    ) {
        self.isEnabled = isEnabled
        self.windows = windows
        self.appearance = appearance
        self.dialogs = dialogs
        self.openFoldersInNewTabs = openFoldersInNewTabs
    }

    public static let disabled: FinderAutomationConfiguration = FinderAutomationConfiguration(isEnabled: false)
}

public enum FinderAutomationSkipReason: Sendable, Equatable {
    case disabled
    case accessibilityNotAuthorized
    case finderUnavailable
    case notEligible
    case existingWindow
    case protectedOrSecureUI
    case unsupportedAttribute
    case invalidGeometry
    case windowChangedBeforeApplication
    case automationConsentRequired
    case automationDenied
}

public enum FinderAutomationFailure: Sendable, Equatable {
    case accessibilityError(code: Int32)
    case observerError(code: Int32)
    case appleEventError(code: Int32)
}

public enum FinderAutomationOperationResult: Sendable, Equatable {
    case applied
    case noChanges
    case skipped(FinderAutomationSkipReason)
    case failed(FinderAutomationFailure)
}

public enum FinderAutomationEvent: Sendable, Equatable {
    case accessibilityChanged(AccessibilityAuthorizationStatus)
    case finderAttached
    case finderDetached
    case finderWindowRule(FinderAutomationOperationResult)
    case finderWindowAppearance(FinderAutomationOperationResult)
    case finderDialogPlacement(FinderAutomationOperationResult)
}

public struct FinderWindowApplicationReport: Sendable, Equatable {
    public let examined: Int
    public let applied: Int
    public let skipped: Int
    public let failed: Int
    public let operationResults: [FinderAutomationOperationResult]

    public init(
        examined: Int,
        applied: Int,
        skipped: Int,
        failed: Int,
        operationResults: [FinderAutomationOperationResult]
    ) {
        self.examined = examined
        self.applied = applied
        self.skipped = skipped
        self.failed = failed
        self.operationResults = operationResults
    }
}

public enum FinderAppleEventAuthorizationStatus: Sendable, Equatable {
    case authorized
    case consentRequired
    case denied
    case finderUnavailable
    case failed(code: Int32)
}
