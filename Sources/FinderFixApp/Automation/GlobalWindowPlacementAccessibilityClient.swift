import ApplicationServices
import CoreGraphics
import FinderFixCore
import Foundation

struct GlobalAXElementReference: @unchecked Sendable {
    let element: AXUIElement
}

struct GlobalWindowScreenContext: Sendable {
    let primaryFrameInAppKit: CGRect
    let primaryVisibleFrameInAppKit: CGRect
    let displayFramesInAppKit: [CGRect]
}

enum GlobalWindowEnumerationResult: @unchecked Sendable {
    case windows([GlobalAXElementReference])
    case failed
}

enum GlobalWindowMutationResult: Sendable {
    case applied
    case permanentlyIneligible
    case temporarilyUnavailable
}

struct GlobalApplicationObserverRegistration: @unchecked Sendable {
    let processIdentifier: pid_t
    let applicationElement: AXUIElement
    let observer: AXObserver
    let registeredNotifications: [CFString]
    let contextAddress: UInt
}

enum GlobalObserverRegistrationResult: @unchecked Sendable {
    case registered(GlobalApplicationObserverRegistration)
    case failed
}

final class GlobalWindowPlacementCommitToken: @unchecked Sendable {
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

actor GlobalWindowPlacementAccessibilityClient {
    func registerObserver(
        processIdentifier: pid_t,
        contextAddress: UInt
    ) -> GlobalObserverRegistrationResult {
        let applicationElement: AXUIElement = AXUIElementCreateApplication(processIdentifier)
        _ = AXUIElementSetMessagingTimeout(applicationElement, 0.35)

        var observerReference: AXObserver?
        let createError: AXError = AXObserverCreate(
            processIdentifier,
            globalWindowPlacementObserverCallback,
            &observerReference
        )
        guard createError == .success, let observer: AXObserver = observerReference,
              let contextPointer: UnsafeMutableRawPointer = UnsafeMutableRawPointer(
                  bitPattern: contextAddress
              ) else {
            return .failed
        }

        let windowCreatedNotification: CFString = kAXWindowCreatedNotification as CFString
        let windowCreatedError: AXError = AXObserverAddNotification(
            observer,
            applicationElement,
            windowCreatedNotification,
            contextPointer
        )
        guard windowCreatedError == .success
                || windowCreatedError == .notificationAlreadyRegistered else {
            return .failed
        }

        let optionalNotifications: [CFString] = [
            kAXFocusedWindowChangedNotification as CFString,
            kAXMainWindowChangedNotification as CFString,
        ]
        var registeredNotifications: [CFString] = [windowCreatedNotification]
        for notification in optionalNotifications {
            let error: AXError = AXObserverAddNotification(
                observer,
                applicationElement,
                notification,
                contextPointer
            )
            if error == .success || error == .notificationAlreadyRegistered {
                registeredNotifications.append(notification)
            }
        }
        return .registered(
            GlobalApplicationObserverRegistration(
                processIdentifier: processIdentifier,
                applicationElement: applicationElement,
                observer: observer,
                registeredNotifications: registeredNotifications,
                contextAddress: contextAddress
            )
        )
    }

    func unregisterObserver(_ registration: GlobalApplicationObserverRegistration) {
        for notification in registration.registeredNotifications {
            _ = AXObserverRemoveNotification(
                registration.observer,
                registration.applicationElement,
                notification
            )
        }
    }

    func windows(
        in applicationReference: GlobalAXElementReference
    ) -> GlobalWindowEnumerationResult {
        switch AXElementAccess.elementsAttribute(
            kAXWindowsAttribute as CFString,
            from: applicationReference.element
        ) {
        case let .value(windows):
            return .windows(
                windows.map { window in GlobalAXElementReference(element: window) }
            )
        case .unavailable:
            return .failed
        }
    }

    func place(
        windowReference: GlobalAXElementReference,
        settings: GlobalWindowPlacementSettings,
        screenContext: GlobalWindowScreenContext,
        commitToken: GlobalWindowPlacementCommitToken,
        expectedGeneration: UInt
    ) -> GlobalWindowMutationResult {
        guard commitToken.matches(expectedGeneration), AXIsProcessTrusted() else {
            return .temporarilyUnavailable
        }

        let window: AXUIElement = windowReference.element
        _ = AXUIElementSetMessagingTimeout(window, 0.35)
        let eligibilityResult: EligibilityResult = eligibility(
            of: window,
            screenContext: screenContext
        )
        let initialFrame: CGRect
        switch eligibilityResult {
        case let .eligible(frame):
            initialFrame = frame
        case .permanentlyIneligible:
            return .permanentlyIneligible
        case .temporarilyUnavailable:
            return .temporarilyUnavailable
        }
        guard let initialPlan: GlobalWindowPlacementPlan = GlobalWindowPlacementGeometry.plan(
            settings: settings,
            primaryDisplayFrameInAppKit: screenContext.primaryFrameInAppKit,
            primaryVisibleFrameInAppKit: screenContext.primaryVisibleFrameInAppKit
        ), commitToken.matches(expectedGeneration), !Self.mouseButtonIsPressed else {
            return .temporarilyUnavailable
        }

        let sizeError: AXError = AXElementAccess.setSize(
            initialPlan.targetFrameInAppKit.size,
            attribute: kAXSizeAttribute as CFString,
            on: window
        )
        guard sizeError == .success else {
            return Self.isRetryable(sizeError) ? .temporarilyUnavailable : .permanentlyIneligible
        }

        let acceptedSize: CGSize
        switch AXElementAccess.sizeAttribute(kAXSizeAttribute as CFString, from: window) {
        case let .value(size):
            guard size.isFiniteAndPositive else {
                restoreInitialFrameIfSafe(
                    initialFrame,
                    expectedMutatedFrame: CGRect(
                        origin: initialFrame.origin,
                        size: initialPlan.targetFrameInAppKit.size
                    ),
                    window: window
                )
                return .temporarilyUnavailable
            }
            acceptedSize = size
        case let .unavailable(error):
            restoreInitialFrameIfSafe(
                initialFrame,
                expectedMutatedFrame: CGRect(
                    origin: initialFrame.origin,
                    size: initialPlan.targetFrameInAppKit.size
                ),
                window: window
            )
            return Self.isRetryable(error) ? .temporarilyUnavailable : .permanentlyIneligible
        }

        let resizedFrame: CGRect = CGRect(origin: initialFrame.origin, size: acceptedSize)
        guard commitToken.matches(expectedGeneration), !Self.mouseButtonIsPressed else {
            restoreInitialFrameIfSafe(
                initialFrame,
                expectedMutatedFrame: resizedFrame,
                window: window
            )
            return .temporarilyUnavailable
        }
        guard acceptedSize.isApproximatelyEqual(
            to: initialPlan.targetFrameInAppKit.size,
            tolerance: 4
        ), aspectRatioMatches(acceptedSize, settings: settings),
        let targetFrame: CGRect = centeredFrame(
            acceptedSize: acceptedSize,
            screenContext: screenContext
        ), let targetTopLeft: CGPoint = PlacementGeometry.axTopLeft(
            forAppKitFrame: targetFrame,
            primaryDisplayFrameInAppKit: screenContext.primaryFrameInAppKit
        ) else {
            restoreInitialFrameIfSafe(
                initialFrame,
                expectedMutatedFrame: resizedFrame,
                window: window
            )
            return .permanentlyIneligible
        }

        guard commitToken.matches(expectedGeneration) else {
            restoreInitialFrameIfSafe(
                initialFrame,
                expectedMutatedFrame: resizedFrame,
                window: window
            )
            return .temporarilyUnavailable
        }
        let positionError: AXError = AXElementAccess.setPoint(
            targetTopLeft,
            attribute: kAXPositionAttribute as CFString,
            on: window
        )
        guard positionError == .success else {
            restoreInitialFrameIfSafe(
                initialFrame,
                expectedMutatedFrame: resizedFrame,
                window: window
            )
            return Self.isRetryable(positionError)
                ? .temporarilyUnavailable
                : .permanentlyIneligible
        }

        let expectedFinalFrame: CGRect = CGRect(origin: targetTopLeft, size: acceptedSize)
        guard commitToken.matches(expectedGeneration) else {
            restoreInitialFrameIfSafe(
                initialFrame,
                expectedMutatedFrame: expectedFinalFrame,
                window: window
            )
            return .temporarilyUnavailable
        }

        let finalFrame: CGRect
        switch AXElementAccess.frame(of: window) {
        case let .value(frame):
            finalFrame = frame
        case let .unavailable(error):
            restoreInitialFrameIfSafe(
                initialFrame,
                expectedMutatedFrame: expectedFinalFrame,
                window: window
            )
            return Self.isRetryable(error) ? .temporarilyUnavailable : .permanentlyIneligible
        }
        guard finalGeometryMatches(
            finalFrame,
            expectedFrameInAX: expectedFinalFrame,
            settings: settings,
            screenContext: screenContext
        ) else {
            restoreInitialFrameIfSafe(
                initialFrame,
                expectedMutatedFrame: expectedFinalFrame,
                window: window
            )
            return .permanentlyIneligible
        }
        guard commitToken.matches(expectedGeneration) else {
            restoreInitialFrameIfSafe(
                initialFrame,
                expectedMutatedFrame: expectedFinalFrame,
                window: window
            )
            return .temporarilyUnavailable
        }
        return .applied
    }

    private enum EligibilityResult {
        case eligible(CGRect)
        case permanentlyIneligible
        case temporarilyUnavailable
    }

    private func eligibility(
        of window: AXUIElement,
        screenContext: GlobalWindowScreenContext
    ) -> EligibilityResult {
        switch AXElementAccess.stringAttribute(kAXRoleAttribute as CFString, from: window) {
        case let .value(role):
            guard role == (kAXWindowRole as String) else { return .permanentlyIneligible }
        case let .unavailable(error):
            return Self.isRetryable(error) ? .temporarilyUnavailable : .permanentlyIneligible
        }
        switch AXElementAccess.stringAttribute(kAXSubroleAttribute as CFString, from: window) {
        case let .value(subrole):
            guard subrole == (kAXStandardWindowSubrole as String) else {
                return .permanentlyIneligible
            }
        case let .unavailable(error):
            return Self.isRetryable(error) ? .temporarilyUnavailable : .permanentlyIneligible
        }

        switch AXElementAccess.boolAttribute(kAXModalAttribute as CFString, from: window) {
        case let .value(isModal):
            guard !isModal else { return .permanentlyIneligible }
        case let .unavailable(error):
            guard error == .attributeUnsupported || error == .noValue else {
                return Self.isRetryable(error) ? .temporarilyUnavailable : .permanentlyIneligible
            }
        }
        switch AXElementAccess.boolAttribute(kAXMinimizedAttribute as CFString, from: window) {
        case let .value(isMinimized):
            guard !isMinimized else { return .permanentlyIneligible }
        case let .unavailable(error):
            guard error == .attributeUnsupported || error == .noValue else {
                return Self.isRetryable(error) ? .temporarilyUnavailable : .permanentlyIneligible
            }
        }

        let frame: CGRect
        switch AXElementAccess.frame(of: window) {
        case let .value(value):
            frame = value
        case let .unavailable(error):
            return Self.isRetryable(error) ? .temporarilyUnavailable : .permanentlyIneligible
        }
        guard !matchesEntireDisplay(frameInAX: frame, screenContext: screenContext) else {
            return .permanentlyIneligible
        }

        for attribute: CFString in [
            kAXSizeAttribute as CFString,
            kAXPositionAttribute as CFString,
        ] {
            switch AXElementAccess.isAttributeSettable(attribute, on: window) {
            case let .value(isSettable):
                guard isSettable else { return .permanentlyIneligible }
            case let .unavailable(error):
                return Self.isRetryable(error) ? .temporarilyUnavailable : .permanentlyIneligible
            }
        }
        return .eligible(frame)
    }

    private func centeredFrame(
        acceptedSize: CGSize,
        screenContext: GlobalWindowScreenContext
    ) -> CGRect? {
        let visibleFrame: CGRect = screenContext.primaryVisibleFrameInAppKit
        let centeredFrame: CGRect = CGRect(
            x: visibleFrame.midX - (acceptedSize.width / 2),
            y: visibleFrame.midY - (acceptedSize.height / 2),
            width: acceptedSize.width,
            height: acceptedSize.height
        )
        return PlacementGeometry.clampedAppKitFrame(centeredFrame, toVisibleFrame: visibleFrame)
    }

    private func aspectRatioMatches(
        _ size: CGSize,
        settings: GlobalWindowPlacementSettings,
        relativeTolerance: CGFloat = 0.02
    ) -> Bool {
        guard size.isFiniteAndPositive else { return false }
        let settings: GlobalWindowPlacementSettings = settings.normalized()
        let expectedRatio: CGFloat = settings.aspectRatioWidth / settings.aspectRatioHeight
        let actualRatio: CGFloat = size.width / size.height
        return abs(actualRatio - expectedRatio) / expectedRatio <= relativeTolerance
    }

    private func finalGeometryMatches(
        _ frameInAX: CGRect,
        expectedFrameInAX: CGRect,
        settings: GlobalWindowPlacementSettings,
        screenContext: GlobalWindowScreenContext,
        tolerance: CGFloat = 4
    ) -> Bool {
        guard frameInAX.isApproximatelyEqual(
            to: expectedFrameInAX,
            tolerance: tolerance
        ), aspectRatioMatches(frameInAX.size, settings: settings),
        let frameInAppKit: CGRect = PlacementGeometry.appKitFrame(
            fromAXTopLeft: frameInAX.origin,
            windowSize: frameInAX.size,
            primaryDisplayFrameInAppKit: screenContext.primaryFrameInAppKit
        ) else {
            return false
        }
        let toleratedVisibleFrame: CGRect = screenContext.primaryVisibleFrameInAppKit.insetBy(
            dx: -tolerance,
            dy: -tolerance
        )
        return toleratedVisibleFrame.contains(frameInAppKit)
    }

    private func restoreInitialFrameIfSafe(
        _ initialFrame: CGRect,
        expectedMutatedFrame: CGRect,
        window: AXUIElement
    ) {
        guard case let .value(currentFrame) = AXElementAccess.frame(of: window),
              currentFrame.isApproximatelyEqual(to: expectedMutatedFrame, tolerance: 4) else {
            return
        }
        _ = AXElementAccess.setSize(
            initialFrame.size,
            attribute: kAXSizeAttribute as CFString,
            on: window
        )
        _ = AXElementAccess.setPoint(
            initialFrame.origin,
            attribute: kAXPositionAttribute as CFString,
            on: window
        )
    }

    private func matchesEntireDisplay(
        frameInAX: CGRect,
        screenContext: GlobalWindowScreenContext,
        tolerance: CGFloat = 2
    ) -> Bool {
        guard let frameInAppKit: CGRect = PlacementGeometry.appKitFrame(
            fromAXTopLeft: frameInAX.origin,
            windowSize: frameInAX.size,
            primaryDisplayFrameInAppKit: screenContext.primaryFrameInAppKit
        ) else {
            return true
        }
        return screenContext.displayFramesInAppKit.contains { displayFrame in
            frameInAppKit.isApproximatelyEqual(to: displayFrame, tolerance: tolerance)
        }
    }

    private static var mouseButtonIsPressed: Bool {
        let sourceState: CGEventSourceStateID = .combinedSessionState
        return CGEventSource.buttonState(sourceState, button: .left)
            || CGEventSource.buttonState(sourceState, button: .right)
            || CGEventSource.buttonState(sourceState, button: .center)
    }

    private static func isRetryable(_ error: AXError) -> Bool {
        error == .cannotComplete || error == .noValue
    }
}

private extension CGSize {
    var isFiniteAndPositive: Bool {
        width.isFinite && height.isFinite && width > 0 && height > 0
    }

    func isApproximatelyEqual(to other: CGSize, tolerance: CGFloat) -> Bool {
        abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}

private extension CGPoint {
    func isApproximatelyEqual(to other: CGPoint, tolerance: CGFloat) -> Bool {
        abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance
    }
}

private extension CGRect {
    func isApproximatelyEqual(to other: CGRect, tolerance: CGFloat) -> Bool {
        origin.isApproximatelyEqual(to: other.origin, tolerance: tolerance)
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
