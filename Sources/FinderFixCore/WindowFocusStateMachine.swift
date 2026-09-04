import Foundation

public struct WindowFocusTargetIdentifier: Hashable, Sendable {
    public let processIdentifier: Int32
    public let windowIdentifier: UInt

    public init(processIdentifier: Int32, windowIdentifier: UInt) {
        self.processIdentifier = processIdentifier
        self.windowIdentifier = windowIdentifier
    }
}

public struct WindowFocusPointerPosition: Hashable, Sendable {
    public static let zero: WindowFocusPointerPosition = WindowFocusPointerPosition(x: 0, y: 0)

    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public func isMeaningfullyDifferent(
        from other: WindowFocusPointerPosition,
        threshold: Double
    ) -> Bool {
        let horizontalDifference: Double = x - other.x
        let verticalDifference: Double = y - other.y
        return (horizontalDifference * horizontalDifference)
            + (verticalDifference * verticalDifference) >= threshold * threshold
    }
}

public struct WindowFocusSample: Sendable {
    public let target: WindowFocusTargetIdentifier?
    public let pointerPosition: WindowFocusPointerPosition
    public let monotonicTime: TimeInterval
    public let isInteractionBlocked: Bool
    public let isAlreadyFocused: Bool
    public let sessionGeneration: UInt

    public init(
        target: WindowFocusTargetIdentifier?,
        pointerPosition: WindowFocusPointerPosition,
        monotonicTime: TimeInterval,
        isInteractionBlocked: Bool,
        isAlreadyFocused: Bool,
        sessionGeneration: UInt
    ) {
        self.target = target
        self.pointerPosition = pointerPosition
        self.monotonicTime = monotonicTime
        self.isInteractionBlocked = isInteractionBlocked
        self.isAlreadyFocused = isAlreadyFocused
        self.sessionGeneration = sessionGeneration
    }
}

public enum WindowFocusDecision: Equatable, Sendable {
    case none
    case focus(WindowFocusTargetIdentifier)
}

public struct WindowFocusStateMachine: Sendable {
    private var candidate: WindowFocusTargetIdentifier?
    private var candidateBeganAt: TimeInterval?
    private var stationaryAnchorPosition: WindowFocusPointerPosition?
    private var hasEmittedDecision: Bool = false
    private var retryNotBefore: TimeInterval?
    private var sessionGeneration: UInt?

    public init() {}

    public mutating func evaluate(
        _ sample: WindowFocusSample,
        activationDelayMilliseconds: Int,
        requirePointerStop: Bool
    ) -> WindowFocusDecision {
        guard sample.monotonicTime.isFinite,
              sample.pointerPosition.x.isFinite,
              sample.pointerPosition.y.isFinite else {
            resetCandidate()
            return .none
        }

        if let previousGeneration: UInt = sessionGeneration,
           previousGeneration != sample.sessionGeneration {
            resetCandidate()
            sessionGeneration = sample.sessionGeneration
            return .none
        }
        sessionGeneration = sample.sessionGeneration

        guard !sample.isInteractionBlocked,
              !sample.isAlreadyFocused,
              let target: WindowFocusTargetIdentifier = sample.target else {
            resetCandidate()
            return .none
        }

        let boundedDelayMilliseconds: Int = min(max(activationDelayMilliseconds, 0), 60_000)
        let delay: TimeInterval = TimeInterval(boundedDelayMilliseconds) / 1_000

        guard candidate == target,
              let beganAt: TimeInterval = candidateBeganAt else {
            beginCandidate(target, sample: sample)
            if delay == 0 {
                hasEmittedDecision = true
                return .focus(target)
            }
            return .none
        }

        if requirePointerStop,
           let anchorPosition: WindowFocusPointerPosition = stationaryAnchorPosition,
           sample.pointerPosition.isMeaningfullyDifferent(from: anchorPosition, threshold: 1) {
            candidateBeganAt = sample.monotonicTime
            stationaryAnchorPosition = sample.pointerPosition
            hasEmittedDecision = false
            retryNotBefore = nil
        }

        guard !hasEmittedDecision else { return .none }
        if let retryNotBefore: TimeInterval,
           sample.monotonicTime < retryNotBefore {
            return .none
        }
        let effectiveBeganAt: TimeInterval = candidateBeganAt ?? beganAt
        guard sample.monotonicTime >= effectiveBeganAt else {
            candidateBeganAt = sample.monotonicTime
            return .none
        }
        guard sample.monotonicTime - effectiveBeganAt >= delay else {
            return .none
        }

        hasEmittedDecision = true
        return .focus(target)
    }

    public mutating func reset() {
        sessionGeneration = nil
        resetCandidate()
    }

    public mutating func focusAttemptFailed(
        for target: WindowFocusTargetIdentifier,
        monotonicTime: TimeInterval,
        retryDelayMilliseconds: Int = 250
    ) {
        guard candidate == target, monotonicTime.isFinite else {
            resetCandidate()
            return
        }
        let boundedRetryMilliseconds: Int = min(max(retryDelayMilliseconds, 0), 60_000)
        retryNotBefore = monotonicTime + TimeInterval(boundedRetryMilliseconds) / 1_000
        candidateBeganAt = monotonicTime
        hasEmittedDecision = false
    }

    private mutating func beginCandidate(
        _ target: WindowFocusTargetIdentifier,
        sample: WindowFocusSample
    ) {
        candidate = target
        candidateBeganAt = sample.monotonicTime
        stationaryAnchorPosition = sample.pointerPosition
        hasEmittedDecision = false
        retryNotBefore = nil
    }

    private mutating func resetCandidate() {
        candidate = nil
        candidateBeganAt = nil
        stationaryAnchorPosition = nil
        hasEmittedDecision = false
        retryNotBefore = nil
    }
}
