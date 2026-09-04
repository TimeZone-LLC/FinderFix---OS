import AppKit
import ApplicationServices
import CoreGraphics
import FinderFixCore
import Foundation

@MainActor
final class GlobalWindowPlacementService {
    private static let protectedBundleIdentifiers: Set<String> = [
        "com.apple.authorizationhost",
        "com.apple.controlcenter",
        "com.apple.coreservicesuiagent",
        "com.apple.dock",
        "com.apple.loginwindow",
        "com.apple.notificationcenterui",
        "com.apple.screensaver.engine",
        "com.apple.screencaptureui",
        "com.apple.securityagent",
        "com.apple.systemuiserver",
    ]

    private(set) var configuration: GlobalWindowPlacementSettings
    private(set) var isStarted: Bool = false

    private let accessibilityClient: GlobalWindowPlacementAccessibilityClient
    private var observerStates: [pid_t: GlobalApplicationObserverState] = [:]
    private var pendingRegistrations: [pid_t: GlobalPendingObserverRegistration] = [:]
    private var workspaceObservationTokens: [NSObjectProtocol] = []
    private var applicationObservationTokens: [NSObjectProtocol] = []
    private let ownHandledWindows: NSHashTable<NSWindow> = .weakObjects()
    private var lifecycleGeneration: UInt = 0

    init(configuration: GlobalWindowPlacementSettings = .defaults) {
        self.configuration = configuration.normalized()
        self.accessibilityClient = GlobalWindowPlacementAccessibilityClient()
    }

    func start() {
        guard !isStarted else {
            refreshAccessibilityAuthorization()
            return
        }
        isStarted = true
        installLifecycleObservers()
        baselineVisibleOwnWindows()
        reconcileExternalObservers()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        lifecycleGeneration &+= 1
        cancelPendingRegistrations()
        detachAllApplicationObservers()
        removeLifecycleObservers()
    }

    func updateConfiguration(_ configuration: GlobalWindowPlacementSettings) {
        let normalizedConfiguration: GlobalWindowPlacementSettings = configuration.normalized()
        guard normalizedConfiguration != self.configuration else { return }
        self.configuration = normalizedConfiguration
        guard isStarted else { return }

        lifecycleGeneration &+= 1
        cancelPendingRegistrations()
        detachAllApplicationObservers()
        baselineVisibleOwnWindows()
        reconcileExternalObservers()
    }

    func refreshAccessibilityAuthorization() {
        guard isStarted else { return }
        reconcileExternalObservers()
    }

    private func reconcileExternalObservers() {
        guard configuration.isEnabled, AccessibilityPermissionController.status == .authorized else {
            if !observerStates.isEmpty || !pendingRegistrations.isEmpty {
                lifecycleGeneration &+= 1
                cancelPendingRegistrations()
                detachAllApplicationObservers()
            }
            return
        }

        for application in NSWorkspace.shared.runningApplications where isEligible(application) {
            requestObservation(of: application, initialPolicy: .baseline)
        }
    }

    private func requestObservation(
        of application: NSRunningApplication,
        initialPolicy: GlobalWindowInitialPolicy
    ) {
        guard isEligible(application) else { return }
        let processIdentifier: pid_t = application.processIdentifier
        if let state: GlobalApplicationObserverState = observerStates[processIdentifier] {
            let scheduledIdentifiers: [UInt64] = state.coordinator.mergeInitialPolicy(
                initialPolicy
            )
            schedulePlacements(scheduledIdentifiers, in: state)
            return
        }
        if let pending: GlobalPendingObserverRegistration = pendingRegistrations[processIdentifier] {
            pending.retryState.merge(initialPolicy: initialPolicy)
            scheduleRegistrationIfNeeded(pending)
            return
        }

        let pending: GlobalPendingObserverRegistration = GlobalPendingObserverRegistration(
            processIdentifier: processIdentifier,
            retryState: GlobalObserverRegistrationRetryState(initialPolicy: initialPolicy)
        )
        pendingRegistrations[processIdentifier] = pending
        scheduleRegistrationIfNeeded(pending)
    }

    private func scheduleRegistrationIfNeeded(
        _ pending: GlobalPendingObserverRegistration
    ) {
        guard pending.task == nil,
              pending.retryState.beginAttempt() else {
            return
        }
        let generation: UInt = lifecycleGeneration
        let delayMilliseconds: Int = pending.retryState.delayBeforeNextAttemptMilliseconds
        pending.task = Task { @MainActor [weak self, accessibilityClient] in
            if delayMilliseconds > 0 {
                do {
                    try await Task.sleep(for: .milliseconds(delayMilliseconds))
                } catch {
                    return
                }
            }
            guard let self else { return }
            guard generation == self.lifecycleGeneration,
                  self.pendingRegistrations[pending.processIdentifier] === pending else {
                return
            }
            guard self.configuration.isEnabled,
                  AccessibilityPermissionController.status == .authorized,
                  let application: NSRunningApplication = NSRunningApplication(
                      processIdentifier: pending.processIdentifier
                  ), self.isEligible(application) else {
                self.abandonRegistration(pending)
                return
            }

            let context: GlobalWindowPlacementObserverContext =
                GlobalWindowPlacementObserverContext(
                    service: self,
                    processIdentifier: pending.processIdentifier
                )
            let contextPointer: UnsafeMutableRawPointer = Unmanaged.passRetained(context).toOpaque()
            let contextAddress: UInt = UInt(bitPattern: contextPointer)
            let result: GlobalObserverRegistrationResult = await accessibilityClient
                .registerObserver(
                    processIdentifier: pending.processIdentifier,
                    contextAddress: contextAddress
                )
            await self.completeRegistration(
                result,
                pending: pending,
                contextAddress: contextAddress,
                generation: generation
            )
        }
    }

    private func completeRegistration(
        _ result: GlobalObserverRegistrationResult,
        pending: GlobalPendingObserverRegistration,
        contextAddress: UInt,
        generation: UInt
    ) async {
        let pendingIsCurrent: Bool = generation == lifecycleGeneration
            && pendingRegistrations[pending.processIdentifier] === pending
        let currentApplication: NSRunningApplication? = NSRunningApplication(
            processIdentifier: pending.processIdentifier
        )
        let requestIsCurrent: Bool = pendingIsCurrent
            && configuration.isEnabled
            && AccessibilityPermissionController.status == .authorized
            && currentApplication.map(isEligible) == true

        guard requestIsCurrent else {
            if case let .registered(registration) = result {
                await accessibilityClient.unregisterObserver(registration)
            }
            releaseObserverContext(at: contextAddress)
            if pendingIsCurrent {
                abandonRegistration(pending)
            }
            return
        }

        switch result {
        case .failed:
            releaseObserverContext(at: contextAddress)
            pending.task = nil
            pending.retryState.recordFailure()
            scheduleRegistrationIfNeeded(pending)

        case let .registered(registration):
            pending.task = nil
            pendingRegistrations.removeValue(forKey: pending.processIdentifier)
            let state: GlobalApplicationObserverState = GlobalApplicationObserverState(
                registration: registration,
                initialPolicy: pending.retryState.initialPolicy
            )
            observerStates[pending.processIdentifier] = state
            let source: CFRunLoopSource = AXObserverGetRunLoopSource(registration.observer)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            enumerateInitialWindows(for: state)
        }
    }

    private func enumerateInitialWindows(
        for state: GlobalApplicationObserverState
    ) {
        guard state.coordinator.initialEnumerationIsPending,
              state.initialEnumerationTask == nil else {
            return
        }
        let generation: UInt = lifecycleGeneration
        let stateGeneration: UInt = state.commitGeneration
        let delayMilliseconds: Int = Self.retryDelayMilliseconds(
            failureCount: state.initialEnumerationFailureCount
        )
        let applicationReference: GlobalAXElementReference = GlobalAXElementReference(
            element: state.registration.applicationElement
        )
        state.initialEnumerationTask = Task { @MainActor [weak self, accessibilityClient] in
            if delayMilliseconds > 0 {
                do {
                    try await Task.sleep(for: .milliseconds(delayMilliseconds))
                } catch {
                    return
                }
            }
            guard let self,
                  self.stateIsCurrent(state, generation: generation),
                  state.commitGeneration == stateGeneration else {
                return
            }
            let result: GlobalWindowEnumerationResult = await accessibilityClient.windows(
                in: applicationReference
            )
            guard self.stateIsCurrent(state, generation: generation),
                  state.commitGeneration == stateGeneration else {
                return
            }
            state.initialEnumerationTask = nil

            switch result {
            case .failed:
                state.coordinator.initialEnumerationFailed()
                state.initialEnumerationFailureCount += 1
                self.enumerateInitialWindows(for: state)

            case let .windows(references):
                state.initialEnumerationFailureCount = 0
                let identifiers: [UInt64] = references.map { reference in
                    state.identifier(for: reference.element)
                }
                let scheduledIdentifiers: [UInt64] = state.coordinator
                    .completeInitialEnumeration(snapshotWindowIdentifiers: identifiers)
                self.schedulePlacements(scheduledIdentifiers, in: state)
            }
        }
    }

    private func requestReconciliation(
        for state: GlobalApplicationObserverState,
        minimumDelayMilliseconds: Int = 0
    ) {
        guard !state.coordinator.initialEnumerationIsPending else {
            enumerateInitialWindows(for: state)
            return
        }
        if state.reconciliationTask != nil || state.scheduledReconciliationTask != nil {
            state.needsAnotherReconciliation = true
            return
        }

        let failureDelay: Int = Self.retryDelayMilliseconds(
            failureCount: state.reconciliationFailureCount
        )
        let delayMilliseconds: Int = max(minimumDelayMilliseconds, failureDelay)
        if delayMilliseconds > 0 {
            let generation: UInt = lifecycleGeneration
            let stateGeneration: UInt = state.commitGeneration
            state.scheduledReconciliationTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(delayMilliseconds))
                } catch {
                    return
                }
                guard let self,
                      self.stateIsCurrent(state, generation: generation),
                      state.commitGeneration == stateGeneration else {
                    return
                }
                state.scheduledReconciliationTask = nil
                self.beginReconciliation(for: state)
            }
            return
        }
        beginReconciliation(for: state)
    }

    private func beginReconciliation(for state: GlobalApplicationObserverState) {
        guard state.reconciliationTask == nil,
              state.scheduledReconciliationTask == nil,
              !state.coordinator.initialEnumerationIsPending else {
            return
        }
        let generation: UInt = lifecycleGeneration
        let stateGeneration: UInt = state.commitGeneration
        let applicationReference: GlobalAXElementReference = GlobalAXElementReference(
            element: state.registration.applicationElement
        )
        state.reconciliationTask = Task { @MainActor [weak self, accessibilityClient] in
            guard let self,
                  self.stateIsCurrent(state, generation: generation),
                  state.commitGeneration == stateGeneration else {
                return
            }
            let result: GlobalWindowEnumerationResult = await accessibilityClient.windows(
                in: applicationReference
            )
            guard self.stateIsCurrent(state, generation: generation),
                  state.commitGeneration == stateGeneration else {
                return
            }
            state.reconciliationTask = nil

            switch result {
            case .failed:
                state.reconciliationFailureCount += 1
                self.requestReconciliation(for: state)

            case let .windows(references):
                state.reconciliationFailureCount = 0
                let identifiers: [UInt64] = references.map { reference in
                    state.identifier(for: reference.element)
                }
                let visibleIdentifiers: Set<UInt64> = Set(identifiers)
                let scheduledIdentifiers: [UInt64] = state.coordinator.reconcile(
                    visibleWindowIdentifiers: identifiers
                )
                let removedIdentifiers: Set<UInt64> = state.coordinator
                    .removeClosedWindowState(visibleWindowIdentifiers: visibleIdentifiers)
                state.removeElementMappings(for: removedIdentifiers)
                self.schedulePlacements(scheduledIdentifiers, in: state)
                if state.needsAnotherReconciliation {
                    state.needsAnotherReconciliation = false
                    self.requestReconciliation(for: state)
                }
            }
        }
    }

    fileprivate func receiveAXNotification(
        processIdentifier: pid_t,
        element: AXUIElement,
        notification: String
    ) {
        guard isStarted,
              configuration.isEnabled,
              AccessibilityPermissionController.status == .authorized,
              let state: GlobalApplicationObserverState = observerStates[processIdentifier] else {
            return
        }

        if notification == (kAXWindowCreatedNotification as String) {
            let identifier: UInt64 = state.identifier(for: element)
            let scheduledIdentifiers: [UInt64] = state.coordinator.recordCreated(identifier)
            schedulePlacements(scheduledIdentifiers, in: state)
            return
        }
        if notification == (kAXFocusedWindowChangedNotification as String)
            || notification == (kAXMainWindowChangedNotification as String) {
            requestReconciliation(for: state)
        }
    }

    private func schedulePlacements(
        _ identifiers: [UInt64],
        in state: GlobalApplicationObserverState
    ) {
        for identifier in identifiers {
            schedulePlacement(identifier, in: state)
        }
    }

    private func schedulePlacement(
        _ identifier: UInt64,
        in state: GlobalApplicationObserverState
    ) {
        guard let element: AXUIElement = state.elementsByIdentifier[identifier] else {
            let shouldRemoveMapping: Bool = state.coordinator.finishAttempt(
                for: identifier,
                outcome: .temporarilyUnavailable
            )
            if shouldRemoveMapping {
                state.removeElementMappings(for: [identifier])
            }
            requestReconciliation(for: state, minimumDelayMilliseconds: 250)
            return
        }
        let windowReference: GlobalAXElementReference = GlobalAXElementReference(element: element)
        let settings: GlobalWindowPlacementSettings = configuration
        let generation: UInt = lifecycleGeneration
        let stateGeneration: UInt = state.commitGeneration
        let retryDelayMilliseconds: Int = Self.retryDelayMilliseconds(
            failureCount: state.placementFailureCounts[identifier, default: 0]
        )

        Task { @MainActor [weak self, accessibilityClient] in
            var finalOutcome: GlobalWindowPlacementAttemptOutcome = .temporarilyUnavailable
            for attempt: Int in 0...4 {
                let attemptDelayMilliseconds: Int = attempt == 0
                    ? retryDelayMilliseconds
                    : Self.retryDelayMilliseconds(failureCount: attempt)
                if attemptDelayMilliseconds > 0 {
                    do {
                        try await Task.sleep(for: .milliseconds(attemptDelayMilliseconds))
                    } catch {
                        return
                    }
                }
                guard let self,
                      self.stateIsCurrent(state, generation: generation),
                      state.commitGeneration == stateGeneration else {
                    return
                }
                guard self.workspaceInteractionIsSafe,
                      let screenContext: GlobalWindowScreenContext = self.screenContext else {
                    continue
                }

                let result: GlobalWindowMutationResult = await accessibilityClient.place(
                    windowReference: windowReference,
                    settings: settings,
                    screenContext: screenContext,
                    commitToken: state.commitToken,
                    expectedGeneration: stateGeneration
                )
                guard self.stateIsCurrent(state, generation: generation) else {
                    return
                }
                if state.commitGeneration != stateGeneration {
                    if result == .applied {
                        let shouldRemoveMapping: Bool = state.coordinator.finishAttempt(
                            for: identifier,
                            outcome: .applied
                        )
                        if shouldRemoveMapping {
                            state.removeElementMappings(for: [identifier])
                        }
                        state.placementFailureCounts.removeValue(forKey: identifier)
                    }
                    return
                }
                switch result {
                case .applied:
                    finalOutcome = .applied
                    break
                case .permanentlyIneligible:
                    finalOutcome = .permanentlyIneligible
                    break
                case .temporarilyUnavailable:
                    continue
                }
                break
            }

            guard let self,
                  self.stateIsCurrent(state, generation: generation),
                  state.commitGeneration == stateGeneration else {
                return
            }
            let shouldRemoveMapping: Bool = state.coordinator.finishAttempt(
                for: identifier,
                outcome: finalOutcome
            )
            if shouldRemoveMapping {
                state.removeElementMappings(for: [identifier])
                return
            }
            switch finalOutcome {
            case .applied, .permanentlyIneligible:
                state.placementFailureCounts.removeValue(forKey: identifier)
            case .temporarilyUnavailable:
                state.placementFailureCounts[identifier, default: 0] += 1
                self.requestReconciliation(
                    for: state,
                    minimumDelayMilliseconds: Self.retryDelayMilliseconds(
                        failureCount: state.placementFailureCounts[identifier, default: 1]
                    )
                )
            }
        }
    }

    private func placeOwnWindowIfNew(_ window: NSWindow) {
        guard !ownHandledWindows.contains(window) else { return }
        guard configuration.isEnabled else {
            ownHandledWindows.add(window)
            return
        }
        guard isEligibleOwnWindow(window) else {
            ownHandledWindows.add(window)
            return
        }
        guard let screenContext,
              let plan: GlobalWindowPlacementPlan = GlobalWindowPlacementGeometry.plan(
                  settings: configuration,
                  primaryDisplayFrameInAppKit: screenContext.primaryFrameInAppKit,
                  primaryVisibleFrameInAppKit: screenContext.primaryVisibleFrameInAppKit
              ) else {
            return
        }
        window.setFrame(plan.targetFrameInAppKit, display: true, animate: false)
        ownHandledWindows.add(window)
    }

    private func isEligibleOwnWindow(_ window: NSWindow) -> Bool {
        window.level == .normal
            && !window.isMiniaturized
            && window.sheetParent == nil
            && !(window is NSPanel)
            && window.styleMask.contains(.titled)
            && window.styleMask.contains(.resizable)
            && !window.styleMask.contains(.fullScreen)
            && window.isMovable
    }

    private func baselineVisibleOwnWindows() {
        for window in NSApplication.shared.windows where window.isVisible {
            ownHandledWindows.add(window)
        }
    }

    private func isEligible(_ application: NSRunningApplication) -> Bool {
        guard !application.isTerminated,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              application.activationPolicy == .regular,
              let bundleIdentifier: String = application.bundleIdentifier?.lowercased(),
              !Self.protectedBundleIdentifiers.contains(bundleIdentifier),
              !excludedBundleIdentifiers.contains(bundleIdentifier) else {
            return false
        }
        return true
    }

    private var excludedBundleIdentifiers: Set<String> {
        Set(
            configuration.excludedApplicationBundleIdentifiers.map { identifier in
                identifier.lowercased()
            }
        )
    }

    private var workspaceInteractionIsSafe: Bool {
        guard AccessibilityPermissionController.status == .authorized else { return false }
        guard let frontmostIdentifier: String = NSWorkspace.shared.frontmostApplication?
            .bundleIdentifier?.lowercased() else {
            return true
        }
        return !Self.protectedBundleIdentifiers.contains(frontmostIdentifier)
    }

    private var screenContext: GlobalWindowScreenContext? {
        guard let primaryScreen: NSScreen = NSScreen.screens.first else { return nil }
        return GlobalWindowScreenContext(
            primaryFrameInAppKit: primaryScreen.frame,
            primaryVisibleFrameInAppKit: primaryScreen.visibleFrame,
            displayFramesInAppKit: NSScreen.screens.map(\.frame)
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
            MainActor.assumeIsolated {
                guard let self, let application,
                      self.configuration.isEnabled,
                      AccessibilityPermissionController.status == .authorized else {
                    return
                }
                self.requestObservation(of: application, initialPolicy: .treatAsNew)
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
            MainActor.assumeIsolated {
                guard let processIdentifier: pid_t = application?.processIdentifier else { return }
                self?.cancelRegistration(processIdentifier: processIdentifier)
                self?.detachApplicationObserver(processIdentifier: processIdentifier)
            }
        }
        let activationToken: NSObjectProtocol = workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application: NSRunningApplication? = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let application,
                      self.configuration.isEnabled,
                      AccessibilityPermissionController.status == .authorized else {
                    return
                }
                if let state: GlobalApplicationObserverState = self.observerStates[
                    application.processIdentifier
                ] {
                    self.requestReconciliation(for: state)
                } else {
                    self.requestObservation(of: application, initialPolicy: .baseline)
                }
            }
        }
        let contextChangeNotifications: [Notification.Name] = [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.willSleepNotification,
        ]
        let contextTokens: [NSObjectProtocol] = contextChangeNotifications.map { name in
            workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.workspaceContextChanged()
                }
            }
        }
        workspaceObservationTokens = [launchToken, terminateToken, activationToken] + contextTokens

        let ownWindowToken: NSObjectProtocol = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let window: NSWindow? = notification.object as? NSWindow
            MainActor.assumeIsolated {
                guard let window else { return }
                self?.placeOwnWindowIfNew(window)
            }
        }
        let screenToken: NSObjectProtocol = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.workspaceContextChanged()
            }
        }
        applicationObservationTokens = [ownWindowToken, screenToken]
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

    private func workspaceContextChanged() {
        guard isStarted else { return }
        for state in observerStates.values {
            state.invalidate()
            requestReconciliation(for: state, minimumDelayMilliseconds: 500)
        }
    }

    private func stateIsCurrent(
        _ state: GlobalApplicationObserverState,
        generation: UInt
    ) -> Bool {
        generation == lifecycleGeneration
            && observerStates[state.registration.processIdentifier] === state
            && configuration.isEnabled
            && AccessibilityPermissionController.status == .authorized
    }

    private func cancelRegistration(processIdentifier: pid_t) {
        guard let pending: GlobalPendingObserverRegistration = pendingRegistrations.removeValue(
            forKey: processIdentifier
        ) else {
            return
        }
        pending.task?.cancel()
        pending.task = nil
    }

    private func abandonRegistration(_ pending: GlobalPendingObserverRegistration) {
        guard pendingRegistrations[pending.processIdentifier] === pending else { return }
        pending.task = nil
        pending.retryState.abandonAttempt()
        pendingRegistrations.removeValue(forKey: pending.processIdentifier)
    }

    private func cancelPendingRegistrations() {
        let processIdentifiers: [pid_t] = Array(pendingRegistrations.keys)
        for processIdentifier in processIdentifiers {
            cancelRegistration(processIdentifier: processIdentifier)
        }
    }

    private func detachApplicationObserver(processIdentifier: pid_t) {
        guard let state: GlobalApplicationObserverState = observerStates.removeValue(
            forKey: processIdentifier
        ) else {
            return
        }
        state.invalidate()
        detachInvalidatedApplicationObserver(state)
    }

    private func detachInvalidatedApplicationObserver(
        _ state: GlobalApplicationObserverState
    ) {
        let source: CFRunLoopSource = AXObserverGetRunLoopSource(state.registration.observer)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        let registration: GlobalApplicationObserverRegistration = state.registration
        Task { @MainActor [accessibilityClient] in
            await accessibilityClient.unregisterObserver(registration)
            releaseObserverContext(at: registration.contextAddress)
        }
    }

    private func detachAllApplicationObservers() {
        let states: [GlobalApplicationObserverState] = Array(observerStates.values)
        for state in states {
            state.invalidate()
        }
        observerStates.removeAll()
        for state in states {
            detachInvalidatedApplicationObserver(state)
        }
    }

    private static func retryDelayMilliseconds(failureCount: Int) -> Int {
        switch failureCount {
        case ...0: 0
        case 1: 100
        case 2: 250
        case 3: 500
        case 4: 1_000
        case 5: 2_000
        default: 5_000
        }
    }
}

@MainActor
private final class GlobalPendingObserverRegistration {
    let processIdentifier: pid_t
    var retryState: GlobalObserverRegistrationRetryState
    var task: Task<Void, Never>?

    init(processIdentifier: pid_t, retryState: GlobalObserverRegistrationRetryState) {
        self.processIdentifier = processIdentifier
        self.retryState = retryState
    }
}

@MainActor
private final class GlobalApplicationObserverState {
    let registration: GlobalApplicationObserverRegistration
    var coordinator: GlobalWindowPlacementCoordinator<UInt64>
    let commitToken: GlobalWindowPlacementCommitToken = GlobalWindowPlacementCommitToken()
    private(set) var commitGeneration: UInt = 0
    var elementsByIdentifier: [UInt64: AXUIElement] = [:]
    var initialEnumerationTask: Task<Void, Never>?
    var reconciliationTask: Task<Void, Never>?
    var scheduledReconciliationTask: Task<Void, Never>?
    var initialEnumerationFailureCount: Int = 0
    var reconciliationFailureCount: Int = 0
    var placementFailureCounts: [UInt64: Int] = [:]
    var needsAnotherReconciliation: Bool = false
    private var nextIdentifier: UInt64 = 1

    init(
        registration: GlobalApplicationObserverRegistration,
        initialPolicy: GlobalWindowInitialPolicy
    ) {
        self.registration = registration
        self.coordinator = GlobalWindowPlacementCoordinator(initialPolicy: initialPolicy)
        commitToken.update(to: commitGeneration)
    }

    func identifier(for element: AXUIElement) -> UInt64 {
        if let match: (key: UInt64, value: AXUIElement) = elementsByIdentifier.first(where: {
            CFEqual($0.value, element)
        }) {
            return match.key
        }
        let identifier: UInt64 = nextIdentifier
        nextIdentifier &+= 1
        if nextIdentifier == 0 {
            nextIdentifier = 1
        }
        elementsByIdentifier[identifier] = element
        return identifier
    }

    func removeElementMappings(for identifiers: Set<UInt64>) {
        for identifier in identifiers {
            elementsByIdentifier.removeValue(forKey: identifier)
            placementFailureCounts.removeValue(forKey: identifier)
        }
    }

    func invalidateMutations() {
        commitGeneration &+= 1
        commitToken.update(to: commitGeneration)
        coordinator.makePendingAttemptsTemporarilyUnavailable()
    }

    func invalidate() {
        invalidateMutations()
        initialEnumerationTask?.cancel()
        initialEnumerationTask = nil
        reconciliationTask?.cancel()
        reconciliationTask = nil
        scheduledReconciliationTask?.cancel()
        scheduledReconciliationTask = nil
    }
}

@MainActor
private final class GlobalWindowPlacementObserverContext {
    weak var service: GlobalWindowPlacementService?
    let processIdentifier: pid_t

    init(service: GlobalWindowPlacementService, processIdentifier: pid_t) {
        self.service = service
        self.processIdentifier = processIdentifier
    }
}

private struct GlobalWindowPlacementNotificationEnvelope: @unchecked Sendable {
    let element: AXUIElement
    let notification: String
    let contextAddress: UInt
}

func globalWindowPlacementObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ reference: UnsafeMutableRawPointer?
) {
    guard let reference else { return }
    let envelope: GlobalWindowPlacementNotificationEnvelope =
        GlobalWindowPlacementNotificationEnvelope(
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
        let context: GlobalWindowPlacementObserverContext =
            Unmanaged<GlobalWindowPlacementObserverContext>
                .fromOpaque(contextPointer)
                .takeUnretainedValue()
        context.service?.receiveAXNotification(
            processIdentifier: context.processIdentifier,
            element: envelope.element,
            notification: envelope.notification
        )
    }
}

@MainActor
private func releaseObserverContext(at address: UInt) {
    guard let pointer: UnsafeMutableRawPointer = UnsafeMutableRawPointer(bitPattern: address) else {
        return
    }
    Unmanaged<GlobalWindowPlacementObserverContext>.fromOpaque(pointer).release()
}
