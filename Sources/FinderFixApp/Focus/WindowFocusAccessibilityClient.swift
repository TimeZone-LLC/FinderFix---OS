import ApplicationServices
import CoreGraphics
import FinderFixCore
import Foundation

final class WindowFocusCommitToken: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var generation: UInt = 0

    func update(to generation: UInt) {
        lock.lock()
        self.generation = generation
        lock.unlock()
    }

    func matches(_ expectedGeneration: UInt) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == expectedGeneration
    }
}

struct ResolvedWindowFocusTarget: Sendable {
    let identifier: WindowFocusTargetIdentifier
    let processIdentifier: pid_t
    let isAlreadyFocused: Bool
    let frontmostWindowIsProtected: Bool
}

enum WindowFocusTargetResolution: Sendable {
    case target(ResolvedWindowFocusTarget)
    case noTarget
    case systemInteractionBlocked
}

enum WindowFocusRaiseResult: Sendable {
    case raised(processIdentifier: pid_t)
    case stale
    case failed
}

actor WindowFocusAccessibilityClient {
    private enum DockInteractionState: Equatable {
        case inactive
        case active
        case indeterminate
    }

    private enum StringAttributeRead {
        case value(String)
        case absent
        case failed
    }

    private static let missionControlIdentifier: String = "mc"
    private static let missionControlTitle: String = "Mission Control"
    private static let ignoredElementRoles: Set<String> = [
        "AXDockItem",
        "AXMenu",
        "AXMenuBar",
        "AXMenuBarItem",
        "AXMenuButton",
        "AXMenuItem",
    ]

    private let systemWideElement: AXUIElement
    private var lastResolvedIdentifier: WindowFocusTargetIdentifier?
    private var lastResolvedWindow: AXUIElement?

    init() {
        self.systemWideElement = AXUIElementCreateSystemWide()
        _ = AXUIElementSetMessagingTimeout(systemWideElement, 0.5)
    }

    func resolveTarget(
        at pointerPosition: WindowFocusPointerPosition,
        frontmostProcessIdentifier: pid_t?,
        dockProcessIdentifier: pid_t?
    ) -> WindowFocusTargetResolution {
        guard dockInteractionState(processIdentifier: dockProcessIdentifier) == .inactive else {
            lastResolvedIdentifier = nil
            lastResolvedWindow = nil
            return .systemInteractionBlocked
        }
        guard let window: AXUIElement = standardWindow(at: pointerPosition) else {
            lastResolvedIdentifier = nil
            lastResolvedWindow = nil
            return .noTarget
        }

        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(window, &processIdentifier) == .success,
              processIdentifier > 0 else {
            lastResolvedIdentifier = nil
            lastResolvedWindow = nil
            return .noTarget
        }

        let isAlreadyFocused: Bool = targetIsAlreadyFocused(
            window,
            processIdentifier: processIdentifier,
            frontmostProcessIdentifier: frontmostProcessIdentifier
        )
        let frontmostWindowIsProtected: Bool = focusedWindowIsProtected(
            processIdentifier: frontmostProcessIdentifier
        )
        let resolvedIdentifier: WindowFocusTargetIdentifier = identifier(
            for: window,
            processIdentifier: processIdentifier
        )
        lastResolvedIdentifier = resolvedIdentifier
        lastResolvedWindow = window
        return .target(
            ResolvedWindowFocusTarget(
                identifier: resolvedIdentifier,
                processIdentifier: processIdentifier,
                isAlreadyFocused: isAlreadyFocused,
                frontmostWindowIsProtected: frontmostWindowIsProtected
            )
        )
    }

    func raiseTargetIfStillHovered(
        _ expectedIdentifier: WindowFocusTargetIdentifier,
        at pointerPosition: WindowFocusPointerPosition,
        frontmostProcessIdentifier: pid_t?,
        dockProcessIdentifier: pid_t?,
        pauseModifier: WindowFocusPauseModifier,
        commitToken: WindowFocusCommitToken,
        expectedCommitGeneration: UInt
    ) -> WindowFocusRaiseResult {
        guard let commitPosition: WindowFocusPointerPosition = commitPositionIfSafe(
            expectedPosition: pointerPosition,
            pauseModifier: pauseModifier,
            commitToken: commitToken,
            expectedCommitGeneration: expectedCommitGeneration
        ), !focusedWindowIsProtected(processIdentifier: frontmostProcessIdentifier),
           dockInteractionState(processIdentifier: dockProcessIdentifier) == .inactive else {
            return .stale
        }
        guard lastResolvedIdentifier == expectedIdentifier,
              let lastResolvedWindow,
              let preflightTarget = matchingHoveredWindow(
                  expectedIdentifier: expectedIdentifier,
                  expectedWindow: lastResolvedWindow,
                  at: commitPosition,
                  frontmostProcessIdentifier: frontmostProcessIdentifier
              ) else {
            return .stale
        }

        guard !focusedWindowIsProtected(processIdentifier: frontmostProcessIdentifier),
              dockInteractionState(processIdentifier: dockProcessIdentifier) == .inactive,
              let finalPosition: WindowFocusPointerPosition = commitPositionIfSafe(
                  expectedPosition: commitPosition,
                  pauseModifier: pauseModifier,
                  commitToken: commitToken,
                  expectedCommitGeneration: expectedCommitGeneration
              ),
              let finalTarget = matchingHoveredWindow(
                  expectedIdentifier: expectedIdentifier,
                  expectedWindow: lastResolvedWindow,
                  at: finalPosition,
                  frontmostProcessIdentifier: frontmostProcessIdentifier
              ),
              finalTarget.processIdentifier == preflightTarget.processIdentifier,
              !focusedWindowIsProtected(processIdentifier: frontmostProcessIdentifier),
              dockInteractionState(processIdentifier: dockProcessIdentifier) == .inactive,
              commitPositionIfSafe(
                  expectedPosition: finalPosition,
                  pauseModifier: pauseModifier,
                  commitToken: commitToken,
                  expectedCommitGeneration: expectedCommitGeneration
              ) != nil else {
            return .stale
        }

        let firstError: AXError = AXUIElementPerformAction(
            finalTarget.window,
            kAXRaiseAction as CFString
        )
        if firstError == .success {
            return .raised(processIdentifier: finalTarget.processIdentifier)
        }
        guard firstError == .cannotComplete else { return .failed }
        guard let retryPosition: WindowFocusPointerPosition = commitPositionIfSafe(
                  expectedPosition: pointerPosition,
                  pauseModifier: pauseModifier,
                  commitToken: commitToken,
                  expectedCommitGeneration: expectedCommitGeneration
              ),
              !focusedWindowIsProtected(processIdentifier: frontmostProcessIdentifier),
              dockInteractionState(processIdentifier: dockProcessIdentifier) == .inactive,
              matchingHoveredWindow(
                  expectedIdentifier: expectedIdentifier,
                  expectedWindow: lastResolvedWindow,
                  at: retryPosition,
                  frontmostProcessIdentifier: frontmostProcessIdentifier
              ) != nil else {
            return .stale
        }

        guard !focusedWindowIsProtected(processIdentifier: frontmostProcessIdentifier),
              dockInteractionState(processIdentifier: dockProcessIdentifier) == .inactive,
              let finalRetryPosition: WindowFocusPointerPosition = commitPositionIfSafe(
                  expectedPosition: retryPosition,
                  pauseModifier: pauseModifier,
                  commitToken: commitToken,
                  expectedCommitGeneration: expectedCommitGeneration
              ),
              let finalRetryTarget = matchingHoveredWindow(
                  expectedIdentifier: expectedIdentifier,
                  expectedWindow: lastResolvedWindow,
                  at: finalRetryPosition,
                  frontmostProcessIdentifier: frontmostProcessIdentifier
              ),
              !focusedWindowIsProtected(processIdentifier: frontmostProcessIdentifier),
              dockInteractionState(processIdentifier: dockProcessIdentifier) == .inactive,
              commitPositionIfSafe(
                  expectedPosition: finalRetryPosition,
                  pauseModifier: pauseModifier,
                  commitToken: commitToken,
                  expectedCommitGeneration: expectedCommitGeneration
              ) != nil else {
            return .stale
        }

        let retryError: AXError = AXUIElementPerformAction(
            finalRetryTarget.window,
            kAXRaiseAction as CFString
        )
        guard retryError == .success else { return .failed }
        return .raised(processIdentifier: finalRetryTarget.processIdentifier)
    }

    func activationIsSafe(
        _ expectedIdentifier: WindowFocusTargetIdentifier,
        at pointerPosition: WindowFocusPointerPosition,
        frontmostProcessIdentifier: pid_t?,
        dockProcessIdentifier: pid_t?,
        pauseModifier: WindowFocusPauseModifier,
        commitToken: WindowFocusCommitToken,
        expectedCommitGeneration: UInt
    ) -> Bool {
        guard lastResolvedIdentifier == expectedIdentifier,
              let lastResolvedWindow,
              let commitPosition: WindowFocusPointerPosition = commitPositionIfSafe(
                  expectedPosition: pointerPosition,
                  pauseModifier: pauseModifier,
                  commitToken: commitToken,
                  expectedCommitGeneration: expectedCommitGeneration
              ),
              matchingHoveredWindow(
                  expectedIdentifier: expectedIdentifier,
                  expectedWindow: lastResolvedWindow,
                  at: commitPosition,
                  frontmostProcessIdentifier: frontmostProcessIdentifier
              ) != nil,
              !focusedWindowIsProtected(processIdentifier: frontmostProcessIdentifier),
              dockInteractionState(processIdentifier: dockProcessIdentifier) == .inactive,
              commitPositionIfSafe(
                  expectedPosition: commitPosition,
                  pauseModifier: pauseModifier,
                  commitToken: commitToken,
                  expectedCommitGeneration: expectedCommitGeneration
              ) != nil else {
            return false
        }
        return true
    }

    func targetIsFocused(
        _ expectedIdentifier: WindowFocusTargetIdentifier,
        processIdentifier: pid_t
    ) -> Bool {
        guard lastResolvedIdentifier == expectedIdentifier,
              let lastResolvedWindow else {
            return false
        }
        let applicationElement: AXUIElement = AXUIElementCreateApplication(processIdentifier)
        configureMessagingTimeout(for: applicationElement)
        guard let focusedWindow: AXUIElement = elementAttribute(
            kAXFocusedWindowAttribute as CFString,
            from: applicationElement
        ) else {
            return false
        }
        return CFEqual(focusedWindow, lastResolvedWindow)
    }

    private func standardWindow(
        at pointerPosition: WindowFocusPointerPosition
    ) -> AXUIElement? {
        let screenFrames: [CGRect] = screenFrames(containing: pointerPosition)
        guard !screenFrames.isEmpty else {
            return nil
        }
        var hitElement: AXUIElement?
        let hitTestError: AXError = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(pointerPosition.x),
            Float(pointerPosition.y),
            &hitElement
        )
        guard hitTestError == .success, let hitElement else { return nil }
        return standardWindow(containing: hitElement, screenFrames: screenFrames)
    }

    private func matchingHoveredWindow(
        expectedIdentifier: WindowFocusTargetIdentifier,
        expectedWindow: AXUIElement,
        at pointerPosition: WindowFocusPointerPosition,
        frontmostProcessIdentifier: pid_t?
    ) -> (window: AXUIElement, processIdentifier: pid_t)? {
        guard let window: AXUIElement = standardWindow(at: pointerPosition),
              CFEqual(window, expectedWindow),
              let processIdentifier: pid_t = processIdentifier(of: window),
              identifier(for: window, processIdentifier: processIdentifier)
                == expectedIdentifier,
              !targetIsAlreadyFocused(
                  window,
                  processIdentifier: processIdentifier,
                  frontmostProcessIdentifier: frontmostProcessIdentifier
              ) else {
            return nil
        }
        return (window, processIdentifier)
    }

    private func standardWindow(
        containing hitElement: AXUIElement,
        screenFrames: [CGRect]
    ) -> AXUIElement? {
        configureMessagingTimeout(for: hitElement)
        guard let hitRole: String = stringAttribute(
            kAXRoleAttribute as CFString,
            from: hitElement
        ), !Self.ignoredElementRoles.contains(hitRole) else {
            return nil
        }

        if let topLevelElement: AXUIElement = topLevelElement(containing: hitElement) {
            return isEligibleStandardWindow(topLevelElement, screenFrames: screenFrames)
                ? topLevelElement
                : nil
        }

        var currentElement: AXUIElement = hitElement

        for _ in 0..<20 {
            configureMessagingTimeout(for: currentElement)
            guard let role: String = stringAttribute(
                kAXRoleAttribute as CFString,
                from: currentElement
            ), !Self.ignoredElementRoles.contains(role) else {
                return nil
            }

            if role == (kAXWindowRole as String) {
                return isEligibleStandardWindow(currentElement, screenFrames: screenFrames)
                    ? currentElement
                    : nil
            }

            if role == (kAXSheetRole as String)
                || role == (kAXDrawerRole as String)
                || role == (kAXPopoverRole as String) {
                return nil
            }

            guard let parentElement: AXUIElement = elementAttribute(
                kAXParentAttribute as CFString,
                from: currentElement
            ), !CFEqual(parentElement, currentElement) else {
                return nil
            }
            currentElement = parentElement
        }
        return nil
    }

    private func isEligibleStandardWindow(
        _ window: AXUIElement,
        screenFrames: [CGRect]
    ) -> Bool {
        configureMessagingTimeout(for: window)
        guard isUnprotectedStandardTopLevel(window),
              boolAttribute(kAXMinimizedAttribute as CFString, from: window) == false,
              let frame: CGRect = frame(of: window),
              screenFrames.contains(where: { screenFrame in
                  WindowFocusGeometry.hasMinimumVisibleIntersection(
                      windowFrame: frame,
                      screenFrame: screenFrame
                  )
              }),
              let actions: Set<String> = actionNames(of: window),
              actions.contains(kAXRaiseAction as String) else {
            return false
        }
        return true
    }

    private func dockInteractionState(processIdentifier: pid_t?) -> DockInteractionState {
        guard let processIdentifier, processIdentifier > 0 else { return .indeterminate }
        let dockElement: AXUIElement = AXUIElementCreateApplication(processIdentifier)
        configureMessagingTimeout(for: dockElement)

        var focusedValue: CFTypeRef?
        let focusedError: AXError = AXUIElementCopyAttributeValue(
            dockElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        switch focusedError {
        case .success:
            guard let focusedValue,
                  CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
                return .indeterminate
            }
            return .active
        case .noValue:
            break
        default:
            return .indeterminate
        }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            dockElement,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == CFArrayGetTypeID() else {
            return .indeterminate
        }

        let children: CFArray = unsafeDowncast(value, to: CFArray.self)
        for index: CFIndex in 0..<CFArrayGetCount(children) {
            guard let opaqueChild: UnsafeRawPointer = CFArrayGetValueAtIndex(children, index) else {
                return .indeterminate
            }
            let childValue: AnyObject = Unmanaged<AnyObject>
                .fromOpaque(opaqueChild)
                .takeUnretainedValue()
            guard CFGetTypeID(childValue) == AXUIElementGetTypeID() else {
                return .indeterminate
            }
            let child: AXUIElement = unsafeDowncast(childValue, to: AXUIElement.self)
            let roleRead: StringAttributeRead = strictStringAttribute(
                kAXRoleAttribute as CFString,
                from: child
            )
            guard case let .value(role) = roleRead else {
                return .indeterminate
            }
            guard role == (kAXGroupRole as String) else {
                continue
            }

            let identifierRead: StringAttributeRead = strictStringAttribute(
                kAXIdentifierAttribute as CFString,
                from: child
            )
            switch identifierRead {
            case let .value(identifier):
                if identifier == Self.missionControlIdentifier {
                    return .active
                }
                return .indeterminate
            case .failed:
                return .indeterminate
            case .absent:
                break
            }

            let titleRead: StringAttributeRead = strictStringAttribute(
                kAXTitleAttribute as CFString,
                from: child
            )
            switch titleRead {
            case let .value(title):
                if title == Self.missionControlTitle {
                    return .active
                }
                return .indeterminate
            case .absent, .failed:
                return .indeterminate
            }
        }
        return .inactive
    }

    private func screenFrames(
        containing pointerPosition: WindowFocusPointerPosition
    ) -> [CGRect] {
        let point: CGPoint = CGPoint(x: pointerPosition.x, y: pointerPosition.y)
        var matchingDisplayCount: UInt32 = 0
        guard CGGetDisplaysWithPoint(
            point,
            0,
            nil,
            &matchingDisplayCount
        ) == .success,
        matchingDisplayCount > 0 else {
            return []
        }

        var displayIdentifiers: [CGDirectDisplayID] = Array(
            repeating: 0,
            count: Int(matchingDisplayCount)
        )
        var refreshedDisplayCount: UInt32 = 0
        let lookupError: CGError = displayIdentifiers.withUnsafeMutableBufferPointer { buffer in
            CGGetDisplaysWithPoint(
                point,
                UInt32(buffer.count),
                buffer.baseAddress,
                &refreshedDisplayCount
            )
        }
        guard lookupError == .success, refreshedDisplayCount > 0 else { return [] }

        let storedDisplayCount: Int = min(
            Int(refreshedDisplayCount),
            displayIdentifiers.count
        )
        return displayIdentifiers.prefix(storedDisplayCount).map { displayIdentifier in
            CGDisplayBounds(displayIdentifier)
        }
    }

    private func targetIsAlreadyFocused(
        _ targetWindow: AXUIElement,
        processIdentifier: pid_t,
        frontmostProcessIdentifier: pid_t?
    ) -> Bool {
        guard processIdentifier == frontmostProcessIdentifier else { return false }
        let applicationElement: AXUIElement = AXUIElementCreateApplication(processIdentifier)
        configureMessagingTimeout(for: applicationElement)
        guard let focusedWindow: AXUIElement = elementAttribute(
            kAXFocusedWindowAttribute as CFString,
            from: applicationElement
        ) else {
            return true
        }
        return CFEqual(focusedWindow, targetWindow)
    }

    private func focusedWindowIsProtected(processIdentifier: pid_t?) -> Bool {
        guard let processIdentifier else { return true }
        let applicationElement: AXUIElement = AXUIElementCreateApplication(processIdentifier)
        configureMessagingTimeout(for: applicationElement)
        guard let focusedElement: AXUIElement = elementAttribute(
            kAXFocusedUIElementAttribute as CFString,
            from: applicationElement
        ), let topLevelElement: AXUIElement = topLevelElement(containing: focusedElement) else {
            return true
        }
        return !isUnprotectedStandardTopLevel(topLevelElement)
    }

    private func topLevelElement(containing element: AXUIElement) -> AXUIElement? {
        configureMessagingTimeout(for: element)
        if let topLevelElement: AXUIElement = elementAttribute(
            kAXTopLevelUIElementAttribute as CFString,
            from: element
        ) {
            return topLevelElement
        }

        var currentElement: AXUIElement = element
        for _ in 0..<20 {
            configureMessagingTimeout(for: currentElement)
            guard let role: String = stringAttribute(
                kAXRoleAttribute as CFString,
                from: currentElement
            ) else {
                return nil
            }
            if role == (kAXWindowRole as String)
                || role == (kAXSheetRole as String)
                || role == (kAXDrawerRole as String)
                || role == (kAXPopoverRole as String) {
                return currentElement
            }
            guard let parentElement: AXUIElement = elementAttribute(
                kAXParentAttribute as CFString,
                from: currentElement
            ), !CFEqual(parentElement, currentElement) else {
                return nil
            }
            currentElement = parentElement
        }
        return nil
    }

    private func isUnprotectedStandardTopLevel(_ element: AXUIElement) -> Bool {
        configureMessagingTimeout(for: element)
        return stringAttribute(kAXRoleAttribute as CFString, from: element)
                == (kAXWindowRole as String)
            && stringAttribute(kAXSubroleAttribute as CFString, from: element)
                == (kAXStandardWindowSubrole as String)
            && boolAttribute(kAXModalAttribute as CFString, from: element) == false
    }

    private func commitPositionIfSafe(
        expectedPosition: WindowFocusPointerPosition,
        pauseModifier: WindowFocusPauseModifier,
        commitToken: WindowFocusCommitToken,
        expectedCommitGeneration: UInt
    ) -> WindowFocusPointerPosition? {
        guard commitToken.matches(expectedCommitGeneration),
              AXIsProcessTrusted(),
              !mouseButtonIsPressed,
              !pauseModifierIsPressed(pauseModifier),
              let event: CGEvent = CGEvent(source: nil) else {
            return nil
        }
        let location: CGPoint = event.location
        let currentPosition: WindowFocusPointerPosition = WindowFocusPointerPosition(
            x: location.x,
            y: location.y
        )
        guard !currentPosition.isMeaningfullyDifferent(
            from: expectedPosition,
            threshold: 1
        ) else {
            return nil
        }
        return currentPosition
    }

    private var mouseButtonIsPressed: Bool {
        let sourceState: CGEventSourceStateID = .combinedSessionState
        return CGEventSource.buttonState(sourceState, button: .left)
            || CGEventSource.buttonState(sourceState, button: .right)
            || CGEventSource.buttonState(sourceState, button: .center)
    }

    private func pauseModifierIsPressed(_ pauseModifier: WindowFocusPauseModifier) -> Bool {
        let flags: CGEventFlags = CGEventSource.flagsState(.combinedSessionState)
        switch pauseModifier {
        case .control:
            return flags.contains(.maskControl)
        case .option:
            return flags.contains(.maskAlternate)
        case .off:
            return false
        }
    }

    private func configureMessagingTimeout(for element: AXUIElement) {
        _ = AXUIElementSetMessagingTimeout(element, 0.25)
    }

    private func identifier(
        for window: AXUIElement,
        processIdentifier: pid_t
    ) -> WindowFocusTargetIdentifier {
        WindowFocusTargetIdentifier(
            processIdentifier: processIdentifier,
            windowIdentifier: UInt(CFHash(window))
        )
    }

    private func processIdentifier(of element: AXUIElement) -> pid_t? {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success,
              processIdentifier > 0 else {
            return nil
        }
        return processIdentifier
    }

    private func stringAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              let string: String = value as? String else {
            return nil
        }
        return string
    }

    private func strictStringAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> StringAttributeRead {
        var value: CFTypeRef?
        let error: AXError = AXUIElementCopyAttributeValue(element, attribute, &value)
        switch error {
        case .success:
            guard let value,
                  CFGetTypeID(value) == CFStringGetTypeID(),
                  let string: String = value as? String else {
                return .failed
            }
            return .value(string)
        case .attributeUnsupported, .noValue:
            return .absent
        default:
            return .failed
        }
    }

    private func boolAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let boolean: Bool = value as? Bool else {
            return nil
        }
        return boolean
    }

    private func elementAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func actionNames(of element: AXUIElement) -> Set<String>? {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let actionNames: [String] = names as? [String] else {
            return nil
        }
        return Set(actionNames)
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let position: CGPoint = pointAttribute(
            kAXPositionAttribute as CFString,
            from: element
        ), let size: CGSize = sizeAttribute(
            kAXSizeAttribute as CFString,
            from: element
        ), position.x.isFinite, position.y.isFinite,
           size.width.isFinite, size.height.isFinite else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func pointAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let accessibilityValue: AXValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(accessibilityValue) == .cgPoint else { return nil }
        var point: CGPoint = .zero
        return AXValueGetValue(accessibilityValue, .cgPoint, &point) ? point : nil
    }

    private func sizeAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let accessibilityValue: AXValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(accessibilityValue) == .cgSize else { return nil }
        var size: CGSize = .zero
        return AXValueGetValue(accessibilityValue, .cgSize, &size) ? size : nil
    }
}
