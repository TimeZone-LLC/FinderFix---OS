import AppKit
import Carbon
import CoreGraphics
import Foundation

/// Serializes Finder Apple Events on the main actor because `NSAppleScript` is
/// main-thread-only. Sources contain only fixed terminology and validated
/// numeric/Boolean values; no user text is interpolated.
@MainActor
public final class FinderAppleEventController {
    private static let finderBundleIdentifier: String = "com.apple.finder"
    private static let scriptFailureCode: Int32 = -1
    private static let scriptTimeoutSeconds: Int = 5

    public init() {}

    public func authorizationStatus(
        promptIfNeeded: Bool = false
    ) -> FinderAppleEventAuthorizationStatus {
        guard let finder: NSRunningApplication = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.finderBundleIdentifier
        ).first(where: { !$0.isTerminated }) else {
            return .finderUnavailable
        }

        var target: AEAddressDesc = AEAddressDesc()
        var processIdentifier: pid_t = finder.processIdentifier
        let createStatus: OSStatus = OSStatus(AECreateDesc(
            DescType(typeKernelProcessID),
            &processIdentifier,
            MemoryLayout<pid_t>.size,
            &target
        ))
        guard createStatus == noErr else {
            return .failed(code: Int32(createStatus))
        }
        defer { AEDisposeDesc(&target) }

        let status: OSStatus = AEDeterminePermissionToAutomateTarget(
            &target,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            promptIfNeeded
        )
        switch status {
        case noErr:
            return .authorized
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .consentRequired
        case OSStatus(errAEEventNotPermitted):
            return .denied
        case OSStatus(procNotFound):
            return .finderUnavailable
        default:
            return .failed(code: Int32(status))
        }
    }

    public func applyWindowAppearance(
        _ configuration: FinderWindowAppearanceConfiguration,
        expectedAXFrame: CGRect? = nil,
        promptForAuthorization: Bool = false
    ) -> FinderAutomationOperationResult {
        guard configuration.hasChanges else { return .noChanges }
        guard let authorizationResult: FinderAutomationOperationResult = operationResult(
            for: authorizationStatus(promptIfNeeded: promptForAuthorization)
        ) else {
            return execute(
                source: Self.windowAppearanceScript(
                    configuration: configuration,
                    expectedAXFrame: expectedAXFrame
                ),
                falseMeans: .windowChangedBeforeApplication
            )
        }
        return authorizationResult
    }

    public func applyWindowAppearanceToAllWindows(
        _ configuration: FinderWindowAppearanceConfiguration,
        promptForAuthorization: Bool = false
    ) -> FinderAutomationOperationResult {
        guard configuration.hasChanges else { return .noChanges }
        guard let authorizationResult: FinderAutomationOperationResult = operationResult(
            for: authorizationStatus(promptIfNeeded: promptForAuthorization)
        ) else {
            return execute(
                source: Self.allWindowsAppearanceScript(configuration: configuration),
                falseMeans: .notEligible
            )
        }
        return authorizationResult
    }

    public func applyGlobalPreferences(
        openFoldersInNewTabs: Bool?,
        promptForAuthorization: Bool = false
    ) -> FinderAutomationOperationResult {
        guard let openFoldersInNewTabs else { return .noChanges }
        guard let authorizationResult: FinderAutomationOperationResult = operationResult(
            for: authorizationStatus(promptIfNeeded: promptForAuthorization)
        ) else {
            let value: String = Self.booleanLiteral(openFoldersInNewTabs)
            let source: String = """
            with timeout of \(Self.scriptTimeoutSeconds) seconds
                tell application id "com.apple.finder"
                    set folders open in new tabs of preferences to \(value)
                    return true
                end tell
            end timeout
            """
            return execute(source: source, falseMeans: .notEligible)
        }
        return authorizationResult
    }

    private func operationResult(
        for status: FinderAppleEventAuthorizationStatus
    ) -> FinderAutomationOperationResult? {
        switch status {
        case .authorized:
            return nil
        case .consentRequired:
            return .skipped(.automationConsentRequired)
        case .denied:
            return .skipped(.automationDenied)
        case .finderUnavailable:
            return .skipped(.finderUnavailable)
        case let .failed(code):
            return .failed(.appleEventError(code: code))
        }
    }

    private func execute(
        source: String,
        falseMeans skipReason: FinderAutomationSkipReason
    ) -> FinderAutomationOperationResult {
        guard let script: NSAppleScript = NSAppleScript(source: source) else {
            return .failed(.appleEventError(code: Self.scriptFailureCode))
        }

        var errorInfo: NSDictionary?
        let result: NSAppleEventDescriptor = script.executeAndReturnError(&errorInfo)
        if errorInfo != nil {
            let code: Int32 = (errorInfo?["NSAppleScriptErrorNumber"] as? NSNumber)?.int32Value
                ?? Self.scriptFailureCode
            if code == Int32(errAEEventNotPermitted) {
                return .skipped(.automationDenied)
            }
            return .failed(.appleEventError(code: code))
        }
        return result.booleanValue ? .applied : .skipped(skipReason)
    }

    private static func windowAppearanceScript(
        configuration: FinderWindowAppearanceConfiguration,
        expectedAXFrame: CGRect?
    ) -> String {
        let mutations: [String] = appearanceMutations(configuration)
        let mutationSource: String = mutations.map { "        \($0)" }.joined(separator: "\n")

        guard let expectedBounds: [Int] = finderBounds(fromAXFrame: expectedAXFrame) else {
            return """
            with timeout of \(scriptTimeoutSeconds) seconds
                tell application id "com.apple.finder"
                    if (count of Finder windows) is 0 then return false
                    set targetWindow to front Finder window
                    tell targetWindow
            \(mutationSource)
                    end tell
                    return true
                end tell
            end timeout
            """
        }

        let boundsLiteral: String = "{\(expectedBounds.map(String.init).joined(separator: ", "))}"
        return """
        on boundsAreClose(actualBounds, expectedBounds, tolerance)
            repeat with itemIndex from 1 to 4
                set actualValue to item itemIndex of actualBounds
                set expectedValue to item itemIndex of expectedBounds
                if actualValue < (expectedValue - tolerance) or actualValue > (expectedValue + tolerance) then return false
            end repeat
            return true
        end boundsAreClose

        with timeout of \(scriptTimeoutSeconds) seconds
            tell application id "com.apple.finder"
                if (count of Finder windows) is 0 then return false
                set expectedBounds to \(boundsLiteral)
                set targetWindow to front Finder window
                if not (my boundsAreClose(bounds of targetWindow, expectedBounds, 3)) then return false
                tell targetWindow
        \(mutationSource)
                end tell
                return true
            end tell
        end timeout
        """
    }

    private static func allWindowsAppearanceScript(
        configuration: FinderWindowAppearanceConfiguration
    ) -> String {
        let mutations: [String] = appearanceMutations(configuration)
        let mutationSource: String = mutations.map { "            \($0)" }.joined(separator: "\n")

        return """
        with timeout of \(scriptTimeoutSeconds) seconds
            tell application id "com.apple.finder"
                set targetWindows to every Finder window
                if (count of targetWindows) is 0 then return false
                repeat with targetWindow in targetWindows
                    tell targetWindow
        \(mutationSource)
                    end tell
                end repeat
                return true
            end tell
        end timeout
        """
    }

    private static func appearanceMutations(
        _ configuration: FinderWindowAppearanceConfiguration
    ) -> [String] {
        var mutations: [String] = []
        if let value: Bool = configuration.toolbar.booleanValue {
            mutations.append("set toolbar visible to \(booleanLiteral(value))")
        }
        if let value: Bool = configuration.pathBar.booleanValue {
            mutations.append("set pathbar visible to \(booleanLiteral(value))")
        }
        if let value: Bool = configuration.statusBar.booleanValue {
            mutations.append("set statusbar visible to \(booleanLiteral(value))")
        }

        switch configuration.sidebar {
        case .unchanged:
            if let width: Int = sanitizedSidebarWidth(configuration.sidebarWidth) {
                mutations.append("set sidebar width to \(width)")
            }
        case .shown:
            let width: Int = sanitizedSidebarWidth(configuration.sidebarWidth) ?? 190
            mutations.append("set sidebar width to \(width)")
        case .hidden:
            // Finder's public scripting dictionary exposes sidebar width but not
            // sidebar visibility. Zero is therefore a best-effort public request.
            mutations.append("set sidebar width to 0")
        }

        if let viewLiteral: String = configuration.view.appleScriptLiteral {
            mutations.append("set current view to \(viewLiteral)")
        }
        return mutations
    }

    private static func sanitizedSidebarWidth(_ width: Int?) -> Int? {
        guard let width else { return nil }
        return min(max(width, 80), 1_000)
    }

    private static func finderBounds(fromAXFrame frame: CGRect?) -> [Int]? {
        guard let frame,
              frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 0,
              frame.height > 0 else {
            return nil
        }

        let values: [CGFloat] = [frame.minX, frame.minY, frame.maxX, frame.maxY]
        let maximumMagnitude: CGFloat = CGFloat(Int32.max)
        guard values.allSatisfy({ abs($0) < maximumMagnitude }) else { return nil }
        return values.map { Int($0.rounded()) }
    }

    private static func booleanLiteral(_ value: Bool) -> String {
        value ? "true" : "false"
    }
}

private extension FinderElementRule {
    var booleanValue: Bool? {
        switch self {
        case .unchanged: nil
        case .shown: true
        case .hidden: false
        }
    }
}

private extension FinderViewRule {
    var appleScriptLiteral: String? {
        switch self {
        case .unchanged: nil
        case .icon: "icon view"
        case .list: "list view"
        case .column: "column view"
        case .gallery: "flow view"
        }
    }
}
