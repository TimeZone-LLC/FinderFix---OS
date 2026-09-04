import Foundation
import XCTest
@testable import FinderFixCore

final class WindowFocusStateMachineTests: XCTestCase {
    private let firstTarget: WindowFocusTargetIdentifier = WindowFocusTargetIdentifier(
        processIdentifier: 100,
        windowIdentifier: 1
    )
    private let secondTarget: WindowFocusTargetIdentifier = WindowFocusTargetIdentifier(
        processIdentifier: 200,
        windowIdentifier: 2
    )

    func testFocusesAfterDwellDelay() {
        var stateMachine: WindowFocusStateMachine = WindowFocusStateMachine()

        XCTAssertEqual(evaluate(&stateMachine, target: firstTarget, time: 10), .none)
        XCTAssertEqual(evaluate(&stateMachine, target: firstTarget, time: 10.249), .none)
        XCTAssertEqual(evaluate(&stateMachine, target: firstTarget, time: 10.250), .focus(firstTarget))
    }

    func testZeroDelayFocusesOnTheFirstEligibleSample() {
        var stateMachine: WindowFocusStateMachine = WindowFocusStateMachine()

        XCTAssertEqual(
            evaluate(
                &stateMachine,
                target: firstTarget,
                time: 10,
                activationDelayMilliseconds: 0
            ),
            .focus(firstTarget)
        )
        XCTAssertEqual(
            evaluate(
                &stateMachine,
                target: firstTarget,
                time: 10.050,
                activationDelayMilliseconds: 0
            ),
            .none
        )
    }

    func testFocusDecisionFiresOnlyOnceForSameTarget() {
        var stateMachine: WindowFocusStateMachine = WindowFocusStateMachine()

        XCTAssertEqual(evaluate(&stateMachine, target: firstTarget, time: 10), .none)
        XCTAssertEqual(evaluate(&stateMachine, target: firstTarget, time: 10.250), .focus(firstTarget))
        XCTAssertEqual(evaluate(&stateMachine, target: firstTarget, time: 10.500), .none)
        XCTAssertEqual(evaluate(&stateMachine, target: firstTarget, time: 11), .none)
    }

    func testChangingTargetRestartsDwellDelay() {
        var stateMachine: WindowFocusStateMachine = WindowFocusStateMachine()

        XCTAssertEqual(evaluate(&stateMachine, target: firstTarget, time: 10), .none)
        XCTAssertEqual(evaluate(&stateMachine, target: secondTarget, time: 10.200), .none)
        XCTAssertEqual(evaluate(&stateMachine, target: secondTarget, time: 10.449), .none)
        XCTAssertEqual(evaluate(&stateMachine, target: secondTarget, time: 10.450), .focus(secondTarget))
    }

    func testPointerMovementRestartsDwellWhenPointerMustStop() {
        var stateMachine: WindowFocusStateMachine = WindowFocusStateMachine()

        XCTAssertEqual(evaluate(&stateMachine, target: firstTarget, time: 10), .none)
        XCTAssertEqual(
            evaluate(
                &stateMachine,
                target: firstTarget,
                position: WindowFocusPointerPosition(x: 2, y: 0),
                time: 10.200,
                requirePointerStop: true
            ),
            .none
        )
        XCTAssertEqual(
            evaluate(
                &stateMachine,
                target: firstTarget,
                position: WindowFocusPointerPosition(x: 2, y: 0),
                time: 10.449,
                requirePointerStop: true
            ),
            .none
        )
        XCTAssertEqual(
            evaluate(
                &stateMachine,
                target: firstTarget,
                position: WindowFocusPointerPosition(x: 2, y: 0),
                time: 10.450,
                requirePointerStop: true
            ),
            .focus(firstTarget)
        )
    }

    func testSlowCumulativeMovementRestartsDwellWhenPointerMustStop() {
        var stateMachine: WindowFocusStateMachine = WindowFocusStateMachine()

        XCTAssertEqual(evaluate(&stateMachine, target: firstTarget, time: 10), .none)
        XCTAssertEqual(
            evaluate(
                &stateMachine,
                target: firstTarget,
                position: WindowFocusPointerPosition(x: 0.4, y: 0),
                time: 10.050
            ),
            .none
        )
        XCTAssertEqual(
            evaluate(
                &stateMachine,
                target: firstTarget,
                position: WindowFocusPointerPosition(x: 0.8, y: 0),
                time: 10.100
            ),
            .none
        )
        XCTAssertEqual(
            evaluate(
                &stateMachine,
                target: firstTarget,
                position: WindowFocusPointerPosition(x: 1.2, y: 0),
                time: 10.200
            ),
            .none
        )
        XCTAssertEqual(
            evaluate(
                &stateMachine,
                target: firstTarget,
                position: WindowFocusPointerPosition(x: 1.2, y: 0),
                time: 10.450
            ),
            .focus(firstTarget)
        )
    }

    func testFailedAttemptRetriesAfterBackoff() {
        var stateMachine: WindowFocusStateMachine = WindowFocusStateMachine()

        XCTAssertEqual(evaluate(&stateMachine, target: firstTarget, time: 10), .none)
        XCTAssertEqual(evaluate(&stateMachine, target: firstTarget, time: 10.250), .focus(firstTarget))

        stateMachine.focusAttemptFailed(
            for: firstTarget,
            monotonicTime: 10.250,
            retryDelayMilliseconds: 250
        )

        XCTAssertEqual(evaluate(&stateMachine, target: firstTarget, time: 10.499), .none)
        XCTAssertEqual(evaluate(&stateMachine, target: firstTarget, time: 10.500), .focus(firstTarget))
    }

    func testPointerMovementDoesNotRestartDwellWhenPointerNeedNotStop() {
        var stateMachine: WindowFocusStateMachine = WindowFocusStateMachine()

        XCTAssertEqual(
            evaluate(
                &stateMachine,
                target: firstTarget,
                position: WindowFocusPointerPosition(x: 0, y: 0),
                time: 10,
                requirePointerStop: false
            ),
            .none
        )
        XCTAssertEqual(
            evaluate(
                &stateMachine,
                target: firstTarget,
                position: WindowFocusPointerPosition(x: 100, y: 100),
                time: 10.200,
                requirePointerStop: false
            ),
            .none
        )
        XCTAssertEqual(
            evaluate(
                &stateMachine,
                target: firstTarget,
                position: WindowFocusPointerPosition(x: 200, y: 200),
                time: 10.250,
                requirePointerStop: false
            ),
            .focus(firstTarget)
        )
    }

    func testBlockedInteractionCancelsCandidate() {
        var stateMachine: WindowFocusStateMachine = WindowFocusStateMachine()

        XCTAssertEqual(evaluate(&stateMachine, target: firstTarget, time: 10), .none)
        XCTAssertEqual(
            evaluate(
                &stateMachine,
                target: firstTarget,
                time: 10.200,
                isInteractionBlocked: true
            ),
            .none
        )
        XCTAssertEqual(evaluate(&stateMachine, target: firstTarget, time: 10.300), .none)
        XCTAssertEqual(evaluate(&stateMachine, target: firstTarget, time: 10.550), .focus(firstTarget))
    }

    func testAlreadyFocusedTargetCancelsCandidate() {
        var stateMachine: WindowFocusStateMachine = WindowFocusStateMachine()

        XCTAssertEqual(evaluate(&stateMachine, target: firstTarget, time: 10), .none)
        XCTAssertEqual(
            evaluate(
                &stateMachine,
                target: firstTarget,
                time: 10.200,
                isAlreadyFocused: true
            ),
            .none
        )
        XCTAssertEqual(evaluate(&stateMachine, target: firstTarget, time: 10.300), .none)
        XCTAssertEqual(evaluate(&stateMachine, target: firstTarget, time: 10.550), .focus(firstTarget))
    }

    func testSessionGenerationChangeCancelsCandidate() {
        var stateMachine: WindowFocusStateMachine = WindowFocusStateMachine()

        XCTAssertEqual(evaluate(&stateMachine, target: firstTarget, time: 10, generation: 1), .none)
        XCTAssertEqual(evaluate(&stateMachine, target: firstTarget, time: 10.250, generation: 2), .none)
        XCTAssertEqual(evaluate(&stateMachine, target: firstTarget, time: 10.300, generation: 2), .none)
        XCTAssertEqual(
            evaluate(&stateMachine, target: firstTarget, time: 10.550, generation: 2),
            .focus(firstTarget)
        )
    }

    private func evaluate(
        _ stateMachine: inout WindowFocusStateMachine,
        target: WindowFocusTargetIdentifier?,
        position: WindowFocusPointerPosition = WindowFocusPointerPosition(x: 0, y: 0),
        time: TimeInterval,
        isInteractionBlocked: Bool = false,
        isAlreadyFocused: Bool = false,
        generation: UInt = 1,
        activationDelayMilliseconds: Int = 250,
        requirePointerStop: Bool = true
    ) -> WindowFocusDecision {
        stateMachine.evaluate(
            WindowFocusSample(
                target: target,
                pointerPosition: position,
                monotonicTime: time,
                isInteractionBlocked: isInteractionBlocked,
                isAlreadyFocused: isAlreadyFocused,
                sessionGeneration: generation
            ),
            activationDelayMilliseconds: activationDelayMilliseconds,
            requirePointerStop: requirePointerStop
        )
    }
}
