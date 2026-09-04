import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
public final class FinderAutomationService {
    public static let finderBundleIdentifier: String = "com.apple.finder"

    public private(set) var configuration: FinderAutomationConfiguration
    public private(set) var accessibilityStatus: AccessibilityAuthorizationStatus
    public private(set) var isStarted: Bool = false
    public var eventHandler: (@MainActor @Sendable (FinderAutomationEvent) -> Void)?

    private let appleEvents: FinderAppleEventController
    private var observerState: FinderObserverState?
    private var workspaceObservationTokens: [NSObjectProtocol] = []
    private var applicationObservationTokens: [NSObjectProtocol] = []
    private var knownWindows: [AXUIElement] = []
    private var handledDialogs: [AXUIElement] = []
    private var handledBrowserWindows: [AXUIElement] = []
    private var lifecycleGeneration: UInt = 0

    public init(
        configuration: FinderAutomationConfiguration = .disabled,
        appleEvents: FinderAppleEventController = FinderAppleEventController()
    ) {
        self.configuration = configuration
        self.appleEvents = appleEvents
        self.accessibilityStatus = AccessibilityPermissionController.status
    }

    public func start(promptForAccessibility: Bool = false) {
        guard !isStarted else {
            if promptForAccessibility {
                requestAccessibilityAuthorization()
            } else {
                refreshAccessibilityAuthorization()
            }
            return
        }

        isStarted = true
        lifecycleGeneration &+= 1
        installLifecycleObservers()

        if promptForAccessibility {
            requestAccessibilityAuthorization()
        } else {
            refreshAccessibilityAuthorization()
        }
    }

    public func stop() {
        guard isStarted else { return }
        isStarted = false
        lifecycleGeneration &+= 1
        detachFinderObserver(emitEvent: true)
        removeLifecycleObservers()
    }

    public func updateConfiguration(_ configuration: FinderAutomationConfiguration) {
        self.configuration = configuration
        if configuration.isEnabled {
            attachToRunningFinderIfPossible()
        } else {
            detachFinderObserver(emitEvent: true)
        }
    }

    @discardableResult
    public func requestAccessibilityAuthorization() -> AccessibilityAuthorizationStatus {
        _ = AccessibilityPermissionController.requestIfNeeded()
        return refreshAccessibilityAuthorization()
    }

    @discardableResult
    public func refreshAccessibilityAuthorization() -> AccessibilityAuthorizationStatus {
        let refreshedStatus: AccessibilityAuthorizationStatus = AccessibilityPermissionController.status
        if refreshedStatus != accessibilityStatus {
            accessibilityStatus = refreshedStatus
            emit(.accessibilityChanged(refreshedStatus))
        }

        if refreshedStatus == .authorized {
            attachToRunningFinderIfPossible()
        } else {
            detachFinderObserver(emitEvent: true)
        }
        return refreshedStatus
    }

    public func appleEventAuthorizationStatus(
        promptIfNeeded: Bool = false
    ) async -> FinderAppleEventAuthorizationStatus {
        appleEvents.authorizationStatus(promptIfNeeded: promptIfNeeded)
    }

    public func applyGlobalFinderPreferences(
        promptForAuthorization: Bool = false
    ) async -> FinderAutomationOperationResult {
        guard configuration.isEnabled else { return .skipped(.disabled) }
        return appleEvents.applyGlobalPreferences(
            openFoldersInNewTabs: configuration.openFoldersInNewTabs,
            promptForAuthorization: promptForAuthorization
        )
    }

    public func applyAppearanceToFrontFinderWindow(
        promptForAuthorization: Bool = false
    ) async -> FinderAutomationOperationResult {
        guard configuration.isEnabled else { return .skipped(.disabled) }
        return appleEvents.applyWindowAppearance(
            configuration.appearance,
            promptForAuthorization: promptForAuthorization
        )
    }

    public func applyRulesToExistingFinderWindows(
        promptForAutomationAuthorization: Bool = false
    ) async -> FinderWindowApplicationReport {
        guard configuration.isEnabled else {
            return FinderWindowApplicationReport(
                examined: 0,
                applied: 0,
                skipped: 1,
                failed: 0,
                operationResults: [.skipped(.disabled)]
            )
        }

        var existingWindows: [ExistingBrowserWindow] = []
        var geometryResults: [FinderAutomationOperationResult] = []
        if configuration.windows.isEnabled {
            if refreshAccessibilityAuthorization() != .authorized {
                geometryResults.append(.skipped(.accessibilityNotAuthorized))
            } else if let observerState {
                existingWindows = existingBrowserWindows(
                    applicationElement: observerState.applicationElement
                )
                let generation: UInt = lifecycleGeneration
                geometryResults.reserveCapacity(existingWindows.count)
                for existingWindow in existingWindows {
                    let geometry: WindowMutationResult = await applyWindowRulesWithRetries(
                        to: existingWindow.element,
                        initialFrame: existingWindow.frame,
                        generation: generation
                    )
                    geometryResults.append(geometry.result)
                }
                if existingWindows.isEmpty {
                    geometryResults.append(.noChanges)
                }
            } else {
                geometryResults.append(.skipped(.finderUnavailable))
            }
        }

        var operationResults: [FinderAutomationOperationResult] = geometryResults
        if configuration.appearance.hasChanges {
            // Apply once to Finder's browser-window collection. Repeating a
            // bounds-based lookup can select the same window when frames match.
            operationResults.append(
                appleEvents.applyWindowAppearanceToAllWindows(
                    configuration.appearance,
                    promptForAuthorization: promptForAutomationAuthorization
                )
            )
        }

        var applied: Int = 0
        var skipped: Int = 0
        var failed: Int = 0

        for geometryResult in geometryResults {
            switch geometryResult {
            case .applied:
                applied += 1
            case .failed:
                failed += 1
            case .noChanges, .skipped:
                skipped += 1
            }
        }

        return FinderWindowApplicationReport(
            examined: existingWindows.count,
            applied: applied,
            skipped: skipped,
            failed: failed,
            operationResults: operationResults
        )
    }

    private func installLifecycleObservers() {
        let workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
        let launchToken: NSObjectProtocol = workspaceCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application: NSRunningApplication? = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication
            let bundleIdentifier: String? = application?.bundleIdentifier
            let processIdentifier: pid_t? = application?.processIdentifier
            MainActor.assumeIsolated {
                guard bundleIdentifier == Self.finderBundleIdentifier,
                      let processIdentifier else {
                    return
                }
                self?.workspaceFinderDidLaunch(processIdentifier: processIdentifier)
            }
        }
        let terminateToken: NSObjectProtocol = workspaceCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application: NSRunningApplication? = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication
            let bundleIdentifier: String? = application?.bundleIdentifier
            let processIdentifier: pid_t? = application?.processIdentifier
            MainActor.assumeIsolated {
                guard bundleIdentifier == Self.finderBundleIdentifier,
                      let processIdentifier else {
                    return
                }
                self?.workspaceFinderDidTerminate(processIdentifier: processIdentifier)
            }
        }
        workspaceObservationTokens = [launchToken, terminateToken]

        let activationToken: NSObjectProtocol = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.refreshAccessibilityAuthorization()
            }
        }
        applicationObservationTokens = [activationToken]
    }

    private func removeLifecycleObservers() {
        let workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
        for token in workspaceObservationTokens {
            workspaceCenter.removeObserver(token)
        }
        workspaceObservationTokens.removeAll()

        for token in applicationObservationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        applicationObservationTokens.removeAll()
    }

    private func workspaceFinderDidLaunch(processIdentifier: pid_t) {
        guard let application: NSRunningApplication = NSRunningApplication(
            processIdentifier: processIdentifier
        ), application.bundleIdentifier == Self.finderBundleIdentifier else { return }
        attachFinderObserver(to: application)
    }

    private func workspaceFinderDidTerminate(processIdentifier: pid_t) {
        if observerState?.processIdentifier == processIdentifier {
            detachFinderObserver(emitEvent: true)
        }
    }

    private func attachToRunningFinderIfPossible() {
        guard isStarted,
              configuration.isEnabled,
              accessibilityStatus == .authorized,
              let finder: NSRunningApplication = NSRunningApplication.runningApplications(
                  withBundleIdentifier: Self.finderBundleIdentifier
              ).first(where: { !$0.isTerminated }) else {
            return
        }
        attachFinderObserver(to: finder)
    }

    private func attachFinderObserver(to finder: NSRunningApplication) {
        guard isStarted,
              configuration.isEnabled,
              accessibilityStatus == .authorized,
              !finder.isTerminated else {
            return
        }
        if observerState?.processIdentifier == finder.processIdentifier {
            return
        }
        detachFinderObserver(emitEvent: observerState != nil)

        let processIdentifier: pid_t = finder.processIdentifier
        let applicationElement: AXUIElement = AXUIElementCreateApplication(processIdentifier)
        _ = AXUIElementSetMessagingTimeout(applicationElement, 0.75)

        var observerReference: AXObserver?
        let createError: AXError = AXObserverCreate(
            processIdentifier,
            finderAutomationObserverCallback,
            &observerReference
        )
        guard createError == .success, let observer: AXObserver = observerReference else {
            emit(.finderWindowRule(.failed(.observerError(code: Int32(createError.rawValue)))))
            return
        }

        let context: FinderObserverContext = FinderObserverContext(service: self)
        let contextPointer: UnsafeMutableRawPointer = Unmanaged.passRetained(context).toOpaque()
        let desiredNotifications: [CFString] = [
            kAXWindowCreatedNotification as CFString,
            kAXFocusedWindowChangedNotification as CFString,
            kAXMainWindowChangedNotification as CFString,
        ]
        var registeredNotifications: [CFString] = []
        for notification in desiredNotifications {
            let addError: AXError = AXObserverAddNotification(
                observer,
                applicationElement,
                notification,
                contextPointer
            )
            if addError == .success || addError == .notificationAlreadyRegistered {
                registeredNotifications.append(notification)
            }
        }

        guard !registeredNotifications.isEmpty else {
            Unmanaged<FinderObserverContext>.fromOpaque(contextPointer).release()
            emit(.finderWindowRule(.failed(.observerError(code: Int32(AXError.notificationUnsupported.rawValue)))))
            return
        }

        let runLoopSource: CFRunLoopSource = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        observerState = FinderObserverState(
            processIdentifier: processIdentifier,
            runningApplication: finder,
            applicationElement: applicationElement,
            observer: observer,
            registeredNotifications: registeredNotifications,
            contextPointer: contextPointer
        )
        knownWindows = currentWindows(of: applicationElement)
        handledDialogs.removeAll()
        handledBrowserWindows.removeAll()
        lifecycleGeneration &+= 1
        emit(.finderAttached)
    }

    private func detachFinderObserver(emitEvent shouldEmit: Bool) {
        guard let state: FinderObserverState = observerState else {
            knownWindows.removeAll()
            handledDialogs.removeAll()
            handledBrowserWindows.removeAll()
            return
        }

        let source: CFRunLoopSource = AXObserverGetRunLoopSource(state.observer)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        for notification in state.registeredNotifications {
            _ = AXObserverRemoveNotification(
                state.observer,
                state.applicationElement,
                notification
            )
        }
        Unmanaged<FinderObserverContext>.fromOpaque(state.contextPointer).release()
        observerState = nil
        knownWindows.removeAll()
        handledDialogs.removeAll()
        handledBrowserWindows.removeAll()
        lifecycleGeneration &+= 1
        if shouldEmit {
            emit(.finderDetached)
        }
    }

    fileprivate func receiveAXNotification(
        element: AXUIElement,
        notification: String
    ) {
        guard isStarted,
              configuration.isEnabled,
              accessibilityStatus == .authorized,
              let state: FinderObserverState = observerState else {
            return
        }

        var elementProcessIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &elementProcessIdentifier) == .success,
              elementProcessIdentifier == state.processIdentifier else {
            return
        }

        let window: AXUIElement
        if notification == (kAXWindowCreatedNotification as String) {
            window = element
        } else if notification == (kAXFocusedWindowChangedNotification as String)
                    || notification == (kAXMainWindowChangedNotification as String) {
            switch AXElementAccess.elementAttribute(
                kAXFocusedWindowAttribute as CFString,
                from: state.applicationElement
            ) {
            case let .value(focusedWindow):
                window = focusedWindow
            case .unavailable:
                return
            }
        } else {
            return
        }

        guard !containsEquivalent(window, in: knownWindows) else { return }
        appendBounded(window, to: &knownWindows)
        processNewWindow(
            window,
            finderWasFrontmost: state.runningApplication.isActive,
            attempt: 0,
            generation: lifecycleGeneration
        )
    }

    private func processNewWindow(
        _ window: AXUIElement,
        finderWasFrontmost: Bool,
        attempt: Int,
        generation: UInt
    ) {
        guard generation == lifecycleGeneration, isStarted else { return }

        switch FinderAXWindowClassifier.classify(window) {
        case let .dialog(size):
            guard configuration.dialogs.isEnabled else { return }
            guard !containsEquivalent(window, in: handledDialogs) else { return }
            let result: FinderAutomationOperationResult = placeDialog(
                window,
                size: size,
                finderWasFrontmost: finderWasFrontmost
            )
            if Self.isTransientAccessibilityFailure(result), attempt < 3 {
                scheduleRetry(
                    window,
                    finderWasFrontmost: finderWasFrontmost,
                    attempt: attempt + 1,
                    generation: generation
                )
                return
            }
            appendBounded(window, to: &handledDialogs)
            emit(.finderDialogPlacement(result))

        case let .browser(frame):
            let needsWindowWork: Bool = configuration.windows.isEnabled
                || configuration.appearance.hasChanges
            guard needsWindowWork else { return }
            guard !containsEquivalent(window, in: handledBrowserWindows) else { return }

            if FinderDisplayPlacement.matchesEntireDisplay(frameInAX: frame) {
                appendBounded(window, to: &handledBrowserWindows)
                emit(.finderWindowRule(.skipped(.notEligible)))
                return
            }

            if !isFocused(window), attempt < 3 {
                scheduleRetry(
                    window,
                    finderWasFrontmost: finderWasFrontmost,
                    attempt: attempt + 1,
                    generation: generation
                )
                return
            }
            guard isFocused(window) else {
                appendBounded(window, to: &handledBrowserWindows)
                emit(.finderWindowRule(.skipped(.windowChangedBeforeApplication)))
                return
            }

            let geometry: WindowMutationResult = applyWindowRules(to: window, currentFrame: frame)
            if Self.isTransientAccessibilityFailure(geometry.result), attempt < 3 {
                scheduleRetry(
                    window,
                    finderWasFrontmost: finderWasFrontmost,
                    attempt: attempt + 1,
                    generation: generation
                )
                return
            }
            appendBounded(window, to: &handledBrowserWindows)
            emit(.finderWindowRule(geometry.result))
            applyAppearanceAutomatically(expectedAXFrame: geometry.resultingFrame)

        case let .retryable(error):
            if attempt < 3 {
                scheduleRetry(
                    window,
                    finderWasFrontmost: finderWasFrontmost,
                    attempt: attempt + 1,
                    generation: generation
                )
            } else {
                emit(.finderWindowRule(.failed(.accessibilityError(code: Int32(error.rawValue)))))
            }

        case .ineligible:
            return
        }
    }

    private func scheduleRetry(
        _ window: AXUIElement,
        finderWasFrontmost: Bool,
        attempt: Int,
        generation: UInt
    ) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.retryDelay(forAttempt: attempt))
            guard let self,
                  generation == self.lifecycleGeneration,
                  self.isStarted else {
                return
            }
            self.processNewWindow(
                window,
                finderWasFrontmost: finderWasFrontmost,
                attempt: attempt,
                generation: generation
            )
        }
    }

    private func placeDialog(
        _ dialog: AXUIElement,
        size: CGSize,
        finderWasFrontmost: Bool
    ) -> FinderAutomationOperationResult {
        guard let targetPosition: CGPoint = FinderDisplayPlacement.centeredDialogTopLeft(size: size) else {
            return .skipped(.invalidGeometry)
        }
        switch AXElementAccess.setAndVerifyPoint(
            targetPosition,
            attribute: kAXPositionAttribute as CFString,
            on: dialog
        ) {
        case .value:
            break
        case let .unavailable(error):
            return .failed(.accessibilityError(code: Int32(error.rawValue)))
        }

        if configuration.dialogs.raiseWhenFinderIsFrontmost, finderWasFrontmost,
           case let .value(actions) = AXElementAccess.actionNames(of: dialog),
           actions.contains(kAXRaiseAction as String),
           finderIsCurrentlyFrontmost() {
            // A single raise is intentional. FinderFix never runs a focus loop and
            // never changes a window level or invokes a dialog button.
            _ = AXUIElementPerformAction(dialog, kAXRaiseAction as CFString)
        }
        return .applied
    }

    private func finderIsCurrentlyFrontmost() -> Bool {
        guard let state: FinderObserverState = observerState,
              !state.runningApplication.isTerminated,
              state.runningApplication.isActive,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == state.processIdentifier else {
            return false
        }
        return true
    }

    private func applyWindowRules(
        to window: AXUIElement,
        currentFrame: CGRect
    ) -> WindowMutationResult {
        guard configuration.windows.isEnabled else {
            return WindowMutationResult(result: .noChanges, resultingFrame: currentFrame)
        }
        guard !FinderDisplayPlacement.matchesEntireDisplay(frameInAX: currentFrame) else {
            return WindowMutationResult(
                result: .skipped(.notEligible),
                resultingFrame: currentFrame
            )
        }

        var resultingFrame: CGRect = currentFrame
        var changed: Bool = false
        let requestedSize: CGSize? = configuration.windows.size
        let shouldSetSize: Bool = requestedSize.map {
            !$0.isApproximatelyEqual(to: currentFrame.size)
        } ?? false
        let shouldSetPosition: Bool = configuration.windows.position != .unchanged

        if let requestedSize {
            guard requestedSize.isUsable else {
                return WindowMutationResult(
                    result: .skipped(.invalidGeometry),
                    resultingFrame: resultingFrame
                )
            }
        }

        if shouldSetSize || shouldSetPosition {
            let geometryAttributes: [CFString] = [
                kAXSizeAttribute as CFString,
                kAXPositionAttribute as CFString,
            ]
            for attribute in geometryAttributes {
                switch AXElementAccess.isAttributeSettable(attribute, on: window) {
                case let .value(isSettable):
                    guard isSettable else {
                        return WindowMutationResult(
                            result: .skipped(.unsupportedAttribute),
                            resultingFrame: resultingFrame
                        )
                    }
                case let .unavailable(error):
                    return mutationReadFailure(error, resultingFrame: resultingFrame)
                }
            }
        }

        if shouldSetSize, let requestedSize {
            switch AXElementAccess.setAndVerifySize(
                requestedSize,
                attribute: kAXSizeAttribute as CFString,
                on: window
            ) {
            case let .value(actualSize):
                resultingFrame.size = actualSize
                changed = true
            case let .unavailable(error):
                return WindowMutationResult(
                    result: .failed(.accessibilityError(code: Int32(error.rawValue))),
                    resultingFrame: resultingFrame
                )
            }
        }

        if shouldSetPosition {
            guard let requestedPosition: CGPoint = FinderDisplayPlacement.normalWindowTopLeft(
                currentFrameInAX: currentFrame,
                targetSize: resultingFrame.size,
                configuration: configuration.windows
            ) else {
                return WindowMutationResult(
                    result: .skipped(.invalidGeometry),
                    resultingFrame: resultingFrame
                )
            }

            if !requestedPosition.isApproximatelyEqual(to: resultingFrame.origin) {
                switch AXElementAccess.setAndVerifyPoint(
                    requestedPosition,
                    attribute: kAXPositionAttribute as CFString,
                    on: window
                ) {
                case let .value(actualPosition):
                    resultingFrame.origin = actualPosition
                    changed = true
                case let .unavailable(error):
                    return WindowMutationResult(
                        result: .failed(.accessibilityError(code: Int32(error.rawValue))),
                        resultingFrame: resultingFrame
                    )
                }
            }
        }

        return WindowMutationResult(
            result: changed ? .applied : .noChanges,
            resultingFrame: resultingFrame
        )
    }

    private func mutationReadFailure(
        _ error: AXError,
        resultingFrame: CGRect
    ) -> WindowMutationResult {
        if error == .attributeUnsupported || error == .noValue {
            return WindowMutationResult(
                result: .skipped(.unsupportedAttribute),
                resultingFrame: resultingFrame
            )
        }
        return WindowMutationResult(
            result: .failed(.accessibilityError(code: Int32(error.rawValue))),
            resultingFrame: resultingFrame
        )
    }

    private func applyAppearanceAutomatically(expectedAXFrame: CGRect) {
        guard configuration.appearance.hasChanges else {
            emit(.finderWindowAppearance(.noChanges))
            return
        }
        let appearance: FinderWindowAppearanceConfiguration = configuration.appearance
        let generation: UInt = lifecycleGeneration
        Task { @MainActor [weak self, appleEvents] in
            let result: FinderAutomationOperationResult = appleEvents.applyWindowAppearance(
                appearance,
                expectedAXFrame: expectedAXFrame,
                promptForAuthorization: false
            )
            guard let self, generation == self.lifecycleGeneration, self.isStarted else { return }
            self.emit(.finderWindowAppearance(result))
        }
    }

    private func existingBrowserWindows(
        applicationElement: AXUIElement
    ) -> [ExistingBrowserWindow] {
        let windows: [AXUIElement] = currentWindows(of: applicationElement)
        var browserWindows: [ExistingBrowserWindow] = []
        browserWindows.reserveCapacity(windows.count)

        for window in windows {
            guard case let .browser(frame) = FinderAXWindowClassifier.classify(window) else { continue }
            browserWindows.append(ExistingBrowserWindow(element: window, frame: frame))
        }
        return browserWindows
    }

    private func applyWindowRulesWithRetries(
        to window: AXUIElement,
        initialFrame: CGRect,
        generation: UInt
    ) async -> WindowMutationResult {
        var currentFrame: CGRect = initialFrame
        var lastResult: WindowMutationResult = WindowMutationResult(
            result: .failed(.accessibilityError(code: Int32(AXError.cannotComplete.rawValue))),
            resultingFrame: initialFrame
        )

        for attempt in 0...3 {
            if attempt > 0 {
                try? await Task.sleep(for: Self.retryDelay(forAttempt: attempt))
                guard generation == lifecycleGeneration,
                      isStarted,
                      let state: FinderObserverState = observerState else {
                    return WindowMutationResult(
                        result: .skipped(.windowChangedBeforeApplication),
                        resultingFrame: currentFrame
                    )
                }

                var processIdentifier: pid_t = 0
                guard AXUIElementGetPid(window, &processIdentifier) == .success,
                      processIdentifier == state.processIdentifier else {
                    return WindowMutationResult(
                        result: .skipped(.windowChangedBeforeApplication),
                        resultingFrame: currentFrame
                    )
                }

                switch FinderAXWindowClassifier.classify(window) {
                case let .browser(frame):
                    currentFrame = frame
                case let .retryable(error) where error == .cannotComplete:
                    lastResult = WindowMutationResult(
                        result: .failed(.accessibilityError(code: Int32(error.rawValue))),
                        resultingFrame: currentFrame
                    )
                    continue
                case .dialog, .ineligible, .retryable:
                    return WindowMutationResult(
                        result: .skipped(.windowChangedBeforeApplication),
                        resultingFrame: currentFrame
                    )
                }
            }

            let mutation: WindowMutationResult = applyWindowRules(
                to: window,
                currentFrame: currentFrame
            )
            lastResult = mutation
            guard Self.isTransientAccessibilityFailure(mutation.result) else {
                return mutation
            }
        }

        return lastResult
    }

    private func currentWindows(of applicationElement: AXUIElement) -> [AXUIElement] {
        if case let .value(windows) = AXElementAccess.elementsAttribute(
            kAXWindowsAttribute as CFString,
            from: applicationElement
        ) {
            return windows
        }
        return []
    }

    private func isFocused(_ window: AXUIElement) -> Bool {
        guard let applicationElement: AXUIElement = observerState?.applicationElement,
              case let .value(focusedWindow) = AXElementAccess.elementAttribute(
                  kAXFocusedWindowAttribute as CFString,
                  from: applicationElement
              ) else {
            return false
        }
        return CFEqual(window, focusedWindow)
    }

    private func containsEquivalent(
        _ element: AXUIElement,
        in elements: [AXUIElement]
    ) -> Bool {
        elements.contains { CFEqual($0, element) }
    }

    private func appendBounded(_ element: AXUIElement, to elements: inout [AXUIElement]) {
        elements.append(element)
        if elements.count > 128 {
            elements.removeFirst(elements.count - 128)
        }
    }

    private func emit(_ event: FinderAutomationEvent) {
        eventHandler?(event)
    }

    private static func combinedResult(
        _ results: [FinderAutomationOperationResult]
    ) -> FinderAutomationOperationResult {
        if let failure: FinderAutomationOperationResult = results.first(where: {
            if case .failed = $0 { return true }
            return false
        }) {
            return failure
        }
        if results.contains(.applied) {
            return .applied
        }
        if let skipped: FinderAutomationOperationResult = results.first(where: {
            if case .skipped = $0 { return true }
            return false
        }) {
            return skipped
        }
        return .noChanges
    }

    private static func isTransientAccessibilityFailure(
        _ result: FinderAutomationOperationResult
    ) -> Bool {
        guard case let .failed(.accessibilityError(code)) = result else { return false }
        return code == Int32(AXError.cannotComplete.rawValue)
    }

    private static func retryDelay(forAttempt attempt: Int) -> Duration {
        switch attempt {
        case 1: .milliseconds(60)
        case 2: .milliseconds(140)
        default: .milliseconds(280)
        }
    }
}

private struct FinderObserverState {
    let processIdentifier: pid_t
    let runningApplication: NSRunningApplication
    let applicationElement: AXUIElement
    let observer: AXObserver
    let registeredNotifications: [CFString]
    let contextPointer: UnsafeMutableRawPointer
}

@MainActor
private final class FinderObserverContext {
    weak var service: FinderAutomationService?

    init(service: FinderAutomationService) {
        self.service = service
    }
}

private struct WindowMutationResult {
    let result: FinderAutomationOperationResult
    let resultingFrame: CGRect
}

private struct ExistingBrowserWindow {
    let element: AXUIElement
    let frame: CGRect
}

/// The observer source is installed only on the main run loop. This wrapper makes
/// that runtime guarantee explicit to Swift's C-callback concurrency boundary.
private struct FinderAXNotificationEnvelope: @unchecked Sendable {
    let element: AXUIElement
    let notification: String
    let contextAddress: UInt
}

private func finderAutomationObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ reference: UnsafeMutableRawPointer?
) {
    guard let reference else { return }
    let envelope: FinderAXNotificationEnvelope = FinderAXNotificationEnvelope(
        element: element,
        notification: notification as String,
        contextAddress: UInt(bitPattern: reference)
    )
    MainActor.assumeIsolated {
        guard let contextPointer: UnsafeMutableRawPointer = UnsafeMutableRawPointer(
            bitPattern: envelope.contextAddress
        ) else {
            return
        }
        let context: FinderObserverContext = Unmanaged<FinderObserverContext>
            .fromOpaque(contextPointer)
            .takeUnretainedValue()
        context.service?.receiveAXNotification(
            element: envelope.element,
            notification: envelope.notification
        )
    }
}

private extension CGSize {
    var isUsable: Bool {
        width.isFinite && height.isFinite && width > 0 && height > 0
    }

    func isApproximatelyEqual(to other: CGSize, tolerance: CGFloat = 0.5) -> Bool {
        abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}

private extension CGPoint {
    func isApproximatelyEqual(to other: CGPoint, tolerance: CGFloat = 0.5) -> Bool {
        abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance
    }
}
