import AppKit
import CoreGraphics
import FinderFixCore
import Foundation

enum WindowFocusRuntimeState: Equatable, Sendable {
    case disabled
    case needsAccessibility
    case running
    case unavailable(String)

    var isOperational: Bool {
        switch self {
        case .running, .unavailable:
            true
        case .disabled, .needsAccessibility:
            false
        }
    }
}

@MainActor
final class WindowFocusService {
    private static let pollingInterval: Duration = .milliseconds(50)
    private static let pointerMovementThreshold: Double = 3
    private static let dockBundleIdentifier: String = "com.apple.dock"
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

    private(set) var configuration: WindowFocusSettings
    private(set) var runtimeState: WindowFocusRuntimeState = .disabled
    var stateDidChange: (@MainActor @Sendable (WindowFocusRuntimeState) -> Void)?

    private let accessibilityClient: WindowFocusAccessibilityClient
    private let commitToken: WindowFocusCommitToken = WindowFocusCommitToken()
    private var stateMachine: WindowFocusStateMachine = WindowFocusStateMachine()
    private var pollingTask: Task<Void, Never>?
    private var workspaceObservationTokens: [NSObjectProtocol] = []
    private var applicationObservationTokens: [NSObjectProtocol] = []
    private var suppressionAnchor: WindowFocusPointerPosition?
    private var sessionGeneration: UInt = 0
    private var lifecycleGeneration: UInt = 0
    private var commitGeneration: UInt = 0
    private var isStarted: Bool = false
    private var isTemporarilySuspended: Bool = false
    private var dockProcessIdentifier: pid_t?

    init(
        configuration: WindowFocusSettings = .defaults,
        accessibilityClient: WindowFocusAccessibilityClient = WindowFocusAccessibilityClient()
    ) {
        self.configuration = configuration.normalized()
        self.accessibilityClient = accessibilityClient
    }

    func start() {
        guard !isStarted else {
            reconcileRuntime()
            return
        }
        isStarted = true
        refreshDockProcessIdentifier()
        installLifecycleObservers()
        reconcileRuntime()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        lifecycleGeneration &+= 1
        stopPolling()
        removeLifecycleObservers()
        dockProcessIdentifier = nil
        transition(to: .disabled)
    }

    func updateConfiguration(_ configuration: WindowFocusSettings) {
        self.configuration = configuration.normalized()
        invalidatePendingFocus(requirePointerMovement: true)
        reconcileRuntime()
    }

    @discardableResult
    func refreshAccessibilityAuthorization() -> WindowFocusRuntimeState {
        reconcileRuntime()
        return runtimeState
    }

    func suppressUntilPointerMoves() {
        invalidatePendingFocus(requirePointerMovement: true)
    }

    func setTemporarilySuspended(_ suspended: Bool) {
        guard isTemporarilySuspended != suspended else { return }
        isTemporarilySuspended = suspended
        invalidatePendingFocus(requirePointerMovement: !suspended)
    }

    private func reconcileRuntime() {
        guard isStarted, configuration.isEnabled else {
            stopPolling()
            transition(to: .disabled)
            return
        }
        guard AccessibilityPermissionController.status == .authorized else {
            stopPolling()
            transition(to: .needsAccessibility)
            return
        }

        transition(to: .running)
        startPollingIfNeeded()
    }

    private func startPollingIfNeeded() {
        guard pollingTask == nil else { return }
        lifecycleGeneration &+= 1
        advanceCommitGeneration()
        let generation: UInt = lifecycleGeneration
        suppressionAnchor = currentPointerPosition()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.pollingInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.poll(generation: generation)
            }
        }
    }

    private func stopPolling() {
        if pollingTask != nil {
            advanceCommitGeneration()
        }
        pollingTask?.cancel()
        pollingTask = nil
        stateMachine.reset()
        suppressionAnchor = nil
    }

    private func poll(generation: UInt) async {
        guard generation == lifecycleGeneration,
              runtimeState.isOperational,
              configuration.isEnabled else {
            return
        }
        guard AccessibilityPermissionController.status == .authorized else {
            reconcileRuntime()
            return
        }
        guard let pointerPosition: WindowFocusPointerPosition = currentPointerPosition() else {
            resetCandidateWithBlockedSample(at: .zero)
            return
        }
        guard !shouldSuspendForOwnInterface(at: pointerPosition) else {
            resetCandidateWithBlockedSample(at: pointerPosition)
            return
        }
        let focusSessionGeneration: UInt = sessionGeneration
        let focusCommitGeneration: UInt = commitGeneration
        let focusDockProcessIdentifier: pid_t? = dockProcessIdentifier

        if let suppressionAnchor,
           !pointerPosition.isMeaningfullyDifferent(
               from: suppressionAnchor,
               threshold: Self.pointerMovementThreshold
           ) {
            resetCandidateWithBlockedSample(at: pointerPosition)
            return
        }
        suppressionAnchor = nil

        guard !isTemporarilySuspended,
              !mouseButtonIsPressed,
              !pauseModifierIsPressed else {
            resetCandidateWithBlockedSample(at: pointerPosition)
            return
        }

        let frontmostApplication: NSRunningApplication? = NSWorkspace.shared.frontmostApplication
        if let frontmostBundleIdentifier: String = frontmostApplication?.bundleIdentifier,
           Self.protectedBundleIdentifiers.contains(frontmostBundleIdentifier.lowercased()) {
            resetCandidateWithBlockedSample(at: pointerPosition)
            return
        }
        let frontmostProcessIdentifier: pid_t? = frontmostApplication?.processIdentifier
        let resolution: WindowFocusTargetResolution = await accessibilityClient.resolveTarget(
            at: pointerPosition,
            frontmostProcessIdentifier: frontmostProcessIdentifier,
            dockProcessIdentifier: focusDockProcessIdentifier
        )

        guard generation == lifecycleGeneration,
              focusSessionGeneration == sessionGeneration,
              focusDockProcessIdentifier == dockProcessIdentifier,
              runtimeState.isOperational,
              AccessibilityPermissionController.status == .authorized,
              !isTemporarilySuspended,
              !mouseButtonIsPressed,
              !pauseModifierIsPressed,
              NSWorkspace.shared.frontmostApplication?.processIdentifier
                == frontmostProcessIdentifier,
              let currentPointerPosition: WindowFocusPointerPosition = currentPointerPosition(),
              !currentPointerPosition.isMeaningfullyDifferent(
                  from: pointerPosition,
                  threshold: 1
        ) else {
            return
        }
        let resolvedTarget: ResolvedWindowFocusTarget?
        switch resolution {
        case let .target(target):
            resolvedTarget = target
        case .noTarget:
            resolvedTarget = nil
        case .systemInteractionBlocked:
            invalidatePendingFocus(requirePointerMovement: true)
            return
        }
        guard let resolvedTarget,
              !resolvedTarget.frontmostWindowIsProtected,
              let targetApplication: NSRunningApplication = eligibleApplication(
                  processIdentifier: resolvedTarget.processIdentifier
              ) else {
            evaluate(
                target: nil,
                pointerPosition: currentPointerPosition,
                isAlreadyFocused: false
            )
            return
        }
        _ = targetApplication

        let decision: WindowFocusDecision = evaluate(
            target: resolvedTarget.identifier,
            pointerPosition: currentPointerPosition,
            isAlreadyFocused: resolvedTarget.isAlreadyFocused
        )
        guard case let .focus(targetIdentifier) = decision else { return }
        await raise(
            targetIdentifier,
            at: currentPointerPosition,
            generation: generation,
            sessionGeneration: focusSessionGeneration,
            commitGeneration: focusCommitGeneration,
            frontmostProcessIdentifier: frontmostProcessIdentifier,
            dockProcessIdentifier: focusDockProcessIdentifier
        )
    }

    private func raise(
        _ targetIdentifier: WindowFocusTargetIdentifier,
        at pointerPosition: WindowFocusPointerPosition,
        generation: UInt,
        sessionGeneration expectedSessionGeneration: UInt,
        commitGeneration expectedCommitGeneration: UInt,
        frontmostProcessIdentifier: pid_t?,
        dockProcessIdentifier expectedDockProcessIdentifier: pid_t?
    ) async {
        guard generation == lifecycleGeneration,
              expectedSessionGeneration == sessionGeneration,
              expectedCommitGeneration == commitGeneration,
              expectedDockProcessIdentifier == dockProcessIdentifier,
              runtimeState.isOperational,
              configuration.isEnabled,
              !isTemporarilySuspended,
              !mouseButtonIsPressed,
              !pauseModifierIsPressed,
              AccessibilityPermissionController.status == .authorized,
              NSWorkspace.shared.frontmostApplication?.processIdentifier
                == frontmostProcessIdentifier else {
            stateMachine.reset()
            return
        }
        let result: WindowFocusRaiseResult = await accessibilityClient.raiseTargetIfStillHovered(
            targetIdentifier,
            at: pointerPosition,
            frontmostProcessIdentifier: frontmostProcessIdentifier,
            dockProcessIdentifier: expectedDockProcessIdentifier,
            pauseModifier: configuration.pauseModifier,
            commitToken: commitToken,
            expectedCommitGeneration: expectedCommitGeneration
        )
        guard generation == lifecycleGeneration,
              expectedSessionGeneration == sessionGeneration,
              expectedCommitGeneration == commitGeneration,
              expectedDockProcessIdentifier == dockProcessIdentifier,
              runtimeState.isOperational,
              configuration.isEnabled,
              AccessibilityPermissionController.status == .authorized,
              !isTemporarilySuspended,
              !mouseButtonIsPressed,
              !pauseModifierIsPressed,
              let currentPosition: WindowFocusPointerPosition = currentPointerPosition(),
              !currentPosition.isMeaningfullyDifferent(from: pointerPosition, threshold: 1) else {
            stateMachine.reset()
            return
        }

        switch result {
        case .stale:
            stateMachine.reset()
        case .failed:
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == frontmostProcessIdentifier else {
                stateMachine.reset()
                return
            }
            recordFocusAttemptFailure(
                targetIdentifier,
                message: "The last window could not be raised. FinderFix will keep trying."
            )
        case let .raised(processIdentifier):
            let currentFrontmostProcessIdentifier: pid_t? = NSWorkspace.shared
                .frontmostApplication?.processIdentifier
            guard currentFrontmostProcessIdentifier == frontmostProcessIdentifier
                    || currentFrontmostProcessIdentifier == processIdentifier,
                  eligibleApplication(
                      processIdentifier: processIdentifier
                  ) != nil else {
                stateMachine.reset()
                return
            }

            let activationRequestWasAccepted: Bool
            if currentFrontmostProcessIdentifier == processIdentifier {
                activationRequestWasAccepted = true
            } else {
                let activationIsSafe: Bool = await accessibilityClient.activationIsSafe(
                    targetIdentifier,
                    at: pointerPosition,
                    frontmostProcessIdentifier: frontmostProcessIdentifier,
                    dockProcessIdentifier: expectedDockProcessIdentifier,
                    pauseModifier: configuration.pauseModifier,
                    commitToken: commitToken,
                    expectedCommitGeneration: expectedCommitGeneration
                )
                guard activationIsSafe,
                      generation == lifecycleGeneration,
                      expectedSessionGeneration == sessionGeneration,
                      expectedCommitGeneration == commitGeneration,
                      expectedDockProcessIdentifier == dockProcessIdentifier,
                      runtimeState.isOperational,
                      configuration.isEnabled,
                      AccessibilityPermissionController.status == .authorized,
                      !isTemporarilySuspended,
                      !mouseButtonIsPressed,
                      !pauseModifierIsPressed,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier
                        == frontmostProcessIdentifier,
                      let activationPointerPosition: WindowFocusPointerPosition
                        = currentPointerPosition(),
                      !activationPointerPosition.isMeaningfullyDifferent(
                          from: pointerPosition,
                          threshold: 1
                      ),
                      let application: NSRunningApplication = eligibleApplication(
                          processIdentifier: processIdentifier
                      ) else {
                    stateMachine.reset()
                    return
                }
                activationRequestWasAccepted = application.activate(options: [])
            }
            do {
                try await Task.sleep(for: .milliseconds(75))
            } catch {
                stateMachine.reset()
                return
            }
            guard configuration.isEnabled,
                  runtimeState.isOperational,
                  AccessibilityPermissionController.status == .authorized else {
                stateMachine.reset()
                return
            }

            let targetIsFocused: Bool = await accessibilityClient.targetIsFocused(
                targetIdentifier,
                processIdentifier: processIdentifier
            )
            let verifiedFrontmostProcessIdentifier: pid_t? = NSWorkspace.shared
                .frontmostApplication?.processIdentifier
            if targetIsFocused,
               verifiedFrontmostProcessIdentifier == processIdentifier {
                transition(to: .running)
                return
            }

            guard let verifiedPointerPosition: WindowFocusPointerPosition = currentPointerPosition(),
                  !verifiedPointerPosition.isMeaningfullyDifferent(
                      from: pointerPosition,
                      threshold: 1
                  ),
                  !mouseButtonIsPressed,
                  !pauseModifierIsPressed,
                  verifiedFrontmostProcessIdentifier == frontmostProcessIdentifier
                    || verifiedFrontmostProcessIdentifier == processIdentifier else {
                stateMachine.reset()
                return
            }
            let failureMessage: String = activationRequestWasAccepted
                ? "FinderFix could not confirm the last window-focus request. It will retry."
                : "macOS declined the last window-focus request. FinderFix will retry."
            recordFocusAttemptFailure(targetIdentifier, message: failureMessage)
        }
    }

    private func recordFocusAttemptFailure(
        _ targetIdentifier: WindowFocusTargetIdentifier,
        message: String
    ) {
        stateMachine.focusAttemptFailed(
            for: targetIdentifier,
            monotonicTime: ProcessInfo.processInfo.systemUptime,
            retryDelayMilliseconds: max(configuration.activationDelayMilliseconds, 250)
        )
        transition(to: .unavailable(message))
    }

    private func advanceCommitGeneration() {
        commitGeneration &+= 1
        commitToken.update(to: commitGeneration)
    }

    @discardableResult
    private func evaluate(
        target: WindowFocusTargetIdentifier?,
        pointerPosition: WindowFocusPointerPosition,
        isAlreadyFocused: Bool
    ) -> WindowFocusDecision {
        stateMachine.evaluate(
            WindowFocusSample(
                target: target,
                pointerPosition: pointerPosition,
                monotonicTime: ProcessInfo.processInfo.systemUptime,
                isInteractionBlocked: false,
                isAlreadyFocused: isAlreadyFocused,
                sessionGeneration: sessionGeneration
            ),
            activationDelayMilliseconds: configuration.activationDelayMilliseconds,
            requirePointerStop: configuration.requirePointerStop
        )
    }

    private func resetCandidateWithBlockedSample(at pointerPosition: WindowFocusPointerPosition) {
        _ = stateMachine.evaluate(
            WindowFocusSample(
                target: nil,
                pointerPosition: pointerPosition,
                monotonicTime: ProcessInfo.processInfo.systemUptime,
                isInteractionBlocked: true,
                isAlreadyFocused: false,
                sessionGeneration: sessionGeneration
            ),
            activationDelayMilliseconds: configuration.activationDelayMilliseconds,
            requirePointerStop: configuration.requirePointerStop
        )
    }

    private func eligibleApplication(processIdentifier: pid_t) -> NSRunningApplication? {
        guard processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let application: NSRunningApplication = NSRunningApplication(
                  processIdentifier: processIdentifier
              ), !application.isTerminated,
              application.activationPolicy == .regular,
              let bundleIdentifier: String = application.bundleIdentifier else {
            return nil
        }

        let normalizedBundleIdentifier: String = bundleIdentifier.lowercased()
        guard !targetProtectedBundleIdentifiers.contains(normalizedBundleIdentifier),
              !userExcludedBundleIdentifiers.contains(normalizedBundleIdentifier) else {
            return nil
        }
        return application
    }

    private func shouldSuspendForOwnInterface(
        at pointerPosition: WindowFocusPointerPosition
    ) -> Bool {
        guard let primaryScreen: NSScreen = NSScreen.screens.first else { return true }
        let visibleWindowFrames: [CGRect] = NSApplication.shared.windows.compactMap { window in
            window.isVisible ? window.frame : nil
        }
        return WindowFocusGeometry.shouldSuspendForOwnInterface(
            applicationIsActive: NSApplication.shared.isActive,
            pointerPositionInAX: pointerPosition,
            primaryDisplayFrameInAppKit: primaryScreen.frame,
            visibleWindowFramesInAppKit: visibleWindowFrames
        )
    }

    private var targetProtectedBundleIdentifiers: Set<String> {
        var identifiers: Set<String> = Self.protectedBundleIdentifiers
        if let ownBundleIdentifier: String = Bundle.main.bundleIdentifier?.lowercased() {
            identifiers.insert(ownBundleIdentifier)
        }
        return identifiers
    }

    private var userExcludedBundleIdentifiers: Set<String> {
        Set(
            configuration.excludedApplicationBundleIdentifiers.map { identifier in
                identifier.lowercased()
            }
        )
    }

    private var mouseButtonIsPressed: Bool {
        let sourceState: CGEventSourceStateID = .combinedSessionState
        return CGEventSource.buttonState(sourceState, button: .left)
            || CGEventSource.buttonState(sourceState, button: .right)
            || CGEventSource.buttonState(sourceState, button: .center)
    }

    private var pauseModifierIsPressed: Bool {
        let flags: CGEventFlags = CGEventSource.flagsState(.combinedSessionState)
        switch configuration.pauseModifier {
        case .control:
            return flags.contains(.maskControl)
        case .option:
            return flags.contains(.maskAlternate)
        case .off:
            return false
        }
    }

    private func currentPointerPosition() -> WindowFocusPointerPosition? {
        guard let event: CGEvent = CGEvent(source: nil) else { return nil }
        let location: CGPoint = event.location
        guard location.x.isFinite, location.y.isFinite else { return nil }
        return WindowFocusPointerPosition(x: location.x, y: location.y)
    }

    private func invalidatePendingFocus(requirePointerMovement: Bool) {
        sessionGeneration &+= 1
        advanceCommitGeneration()
        stateMachine.reset()
        suppressionAnchor = requirePointerMovement ? currentPointerPosition() : nil
    }

    private func installLifecycleObservers() {
        let workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
        let workspaceNotifications: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.willSleepNotification,
        ]
        workspaceObservationTokens = workspaceNotifications.map { notificationName in
            workspaceCenter.addObserver(
                forName: notificationName,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.workspaceContextChanged()
                }
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
        applicationObservationTokens = [screenToken]
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
        refreshDockProcessIdentifier()
        invalidatePendingFocus(requirePointerMovement: true)
        reconcileRuntime()
    }

    private func refreshDockProcessIdentifier() {
        dockProcessIdentifier = NSWorkspace.shared.runningApplications.first { application in
            application.bundleIdentifier?.lowercased() == Self.dockBundleIdentifier
        }?.processIdentifier
    }

    private func transition(to state: WindowFocusRuntimeState) {
        guard runtimeState != state else { return }
        runtimeState = state
        stateDidChange?(state)
    }

}
