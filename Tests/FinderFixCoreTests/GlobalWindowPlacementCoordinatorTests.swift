import XCTest
@testable import FinderFixCore

final class GlobalWindowPlacementCoordinatorTests: XCTestCase {
    func testBaselineSnapshotDoesNotSuppressDeferredCreation() {
        var coordinator: GlobalWindowPlacementCoordinator<Int> =
            GlobalWindowPlacementCoordinator(initialPolicy: .baseline)

        XCTAssertEqual(coordinator.recordCreated(2), [])
        let scheduled: [Int] = coordinator.completeInitialEnumeration(
            snapshotWindowIdentifiers: [1, 2]
        )

        XCTAssertEqual(scheduled, [2])
        XCTAssertTrue(coordinator.handledWindowIdentifiers.contains(1))
        XCTAssertTrue(coordinator.pendingWindowIdentifiers.contains(2))
    }

    func testDelayedCreationNotificationDoesNotMoveAnAlreadyOpenWindow() {
        var coordinator: GlobalWindowPlacementCoordinator<Int> =
            GlobalWindowPlacementCoordinator(initialPolicy: .baseline)
        XCTAssertEqual(
            coordinator.completeInitialEnumeration(snapshotWindowIdentifiers: [1]),
            []
        )

        XCTAssertEqual(coordinator.recordCreated(1), [])
        XCTAssertEqual(coordinator.recordCreated(1), [])
        XCTAssertTrue(coordinator.handledWindowIdentifiers.contains(1))
        XCTAssertFalse(coordinator.pendingWindowIdentifiers.contains(1))
        XCTAssertEqual(coordinator.recordCreated(2), [2])
    }

    func testFocusingAWindowAbsentFromTheBaselineDoesNotSchedulePlacement() {
        var coordinator: GlobalWindowPlacementCoordinator<Int> =
            GlobalWindowPlacementCoordinator(initialPolicy: .baseline)
        _ = coordinator.completeInitialEnumeration(snapshotWindowIdentifiers: [1])

        XCTAssertEqual(coordinator.reconcile(visibleWindowIdentifiers: [1, 2]), [])
        XCTAssertTrue(coordinator.pendingWindowIdentifiers.isEmpty)
        XCTAssertEqual(coordinator.recordCreated(3), [3])
    }

    func testWindowReturningAfterAnAbsentSnapshotIsNotRecentered() {
        var coordinator: GlobalWindowPlacementCoordinator<Int> =
            GlobalWindowPlacementCoordinator(initialPolicy: .baseline)
        _ = coordinator.completeInitialEnumeration(snapshotWindowIdentifiers: [])
        XCTAssertEqual(coordinator.recordCreated(1), [1])
        coordinator.finishAttempt(for: 1, outcome: .applied)
        _ = coordinator.removeClosedWindowState(visibleWindowIdentifiers: [])

        XCTAssertEqual(coordinator.reconcile(visibleWindowIdentifiers: [1]), [])
        XCTAssertTrue(coordinator.pendingWindowIdentifiers.isEmpty)
    }

    func testFailedBaselineEnumerationRetainsDeferredState() {
        var coordinator: GlobalWindowPlacementCoordinator<Int> =
            GlobalWindowPlacementCoordinator(initialPolicy: .baseline)

        XCTAssertEqual(coordinator.recordCreated(3), [])
        coordinator.initialEnumerationFailed()
        XCTAssertTrue(coordinator.initialEnumerationIsPending)
        XCTAssertEqual(coordinator.reconcile(visibleWindowIdentifiers: [1, 2, 3]), [])

        let scheduled: [Int] = coordinator.completeInitialEnumeration(
            snapshotWindowIdentifiers: [1, 2, 3]
        )
        XCTAssertEqual(scheduled, [3])
        XCTAssertTrue(coordinator.handledWindowIdentifiers.isSuperset(of: [1, 2]))
    }

    func testTreatAsNewSchedulesLaunchSnapshotAndDeferredWindowsOnce() {
        var coordinator: GlobalWindowPlacementCoordinator<Int> =
            GlobalWindowPlacementCoordinator(initialPolicy: .treatAsNew)

        XCTAssertEqual(coordinator.recordCreated(2), [])
        let scheduled: [Int] = coordinator.completeInitialEnumeration(
            snapshotWindowIdentifiers: [1, 2]
        )

        XCTAssertEqual(scheduled, [1, 2])
        XCTAssertEqual(coordinator.reconcile(visibleWindowIdentifiers: [1, 2]), [])
    }

    func testTreatAsNewPromotionBeforeInitialEnumerationSchedulesSnapshot() {
        var coordinator: GlobalWindowPlacementCoordinator<Int> =
            GlobalWindowPlacementCoordinator(initialPolicy: .baseline)

        XCTAssertEqual(coordinator.mergeInitialPolicy(.treatAsNew), [])
        let scheduled: [Int] = coordinator.completeInitialEnumeration(
            snapshotWindowIdentifiers: [1, 2]
        )

        XCTAssertEqual(scheduled, [1, 2])
        XCTAssertEqual(coordinator.initialPolicy, .treatAsNew)
    }

    func testLateTreatAsNewPromotionSchedulesOnlyBaselinedSnapshotOnce() {
        var coordinator: GlobalWindowPlacementCoordinator<Int> =
            GlobalWindowPlacementCoordinator(initialPolicy: .baseline)
        XCTAssertEqual(coordinator.recordCreated(2), [])
        XCTAssertEqual(
            coordinator.completeInitialEnumeration(snapshotWindowIdentifiers: [1, 2]),
            [2]
        )

        XCTAssertEqual(coordinator.mergeInitialPolicy(.treatAsNew), [1])
        XCTAssertEqual(coordinator.mergeInitialPolicy(.treatAsNew), [])
        XCTAssertTrue(coordinator.pendingWindowIdentifiers.isSuperset(of: [1, 2]))
    }

    func testTemporaryFailureRetriesOnReconciliationButSuccessNeverDoes() {
        var coordinator: GlobalWindowPlacementCoordinator<Int> =
            GlobalWindowPlacementCoordinator(initialPolicy: .baseline)
        _ = coordinator.completeInitialEnumeration(snapshotWindowIdentifiers: [])

        XCTAssertEqual(coordinator.recordCreated(7), [7])
        coordinator.finishAttempt(for: 7, outcome: .temporarilyUnavailable)
        XCTAssertTrue(coordinator.retryableWindowIdentifiers.contains(7))
        XCTAssertEqual(coordinator.reconcile(visibleWindowIdentifiers: [7]), [7])

        coordinator.finishAttempt(for: 7, outcome: .applied)
        XCTAssertEqual(coordinator.reconcile(visibleWindowIdentifiers: [7]), [])
        XCTAssertTrue(coordinator.handledWindowIdentifiers.contains(7))
    }

    func testPermanentIneligibilityIsHandledOnce() {
        var coordinator: GlobalWindowPlacementCoordinator<Int> =
            GlobalWindowPlacementCoordinator(initialPolicy: .baseline)
        _ = coordinator.completeInitialEnumeration(snapshotWindowIdentifiers: [])

        XCTAssertEqual(coordinator.recordCreated(4), [4])
        coordinator.finishAttempt(for: 4, outcome: .permanentlyIneligible)

        XCTAssertEqual(coordinator.recordCreated(4), [])
        XCTAssertEqual(coordinator.reconcile(visibleWindowIdentifiers: [4]), [])
    }

    func testSuccessfulEnumerationPrunesOnlyClosedTerminalWindows() {
        var coordinator: GlobalWindowPlacementCoordinator<Int> =
            GlobalWindowPlacementCoordinator(initialPolicy: .baseline)
        _ = coordinator.completeInitialEnumeration(snapshotWindowIdentifiers: [1, 2])
        XCTAssertEqual(coordinator.recordCreated(3), [3])

        let removed: Set<Int> = coordinator.removeClosedWindowState(
            visibleWindowIdentifiers: [2]
        )

        XCTAssertEqual(removed, [1])
        XCTAssertTrue(coordinator.handledWindowIdentifiers.contains(2))
        XCTAssertTrue(coordinator.pendingWindowIdentifiers.contains(3))
    }

    func testPendingWindowConfirmedClosedIsRetiredWhenAttemptFinishes() {
        var coordinator: GlobalWindowPlacementCoordinator<Int> =
            GlobalWindowPlacementCoordinator(initialPolicy: .baseline)
        _ = coordinator.completeInitialEnumeration(snapshotWindowIdentifiers: [])
        XCTAssertEqual(coordinator.recordCreated(3), [3])

        XCTAssertEqual(
            coordinator.removeClosedWindowState(visibleWindowIdentifiers: []),
            []
        )
        XCTAssertTrue(coordinator.finishAttempt(for: 3, outcome: .applied))
        XCTAssertFalse(coordinator.handledWindowIdentifiers.contains(3))
        XCTAssertFalse(coordinator.pendingWindowIdentifiers.contains(3))
        XCTAssertEqual(coordinator.reconcile(visibleWindowIdentifiers: [3]), [])
    }

    func testPendingWindowSeenAgainIsNotRetiredWhenAttemptFinishes() {
        var coordinator: GlobalWindowPlacementCoordinator<Int> =
            GlobalWindowPlacementCoordinator(initialPolicy: .baseline)
        _ = coordinator.completeInitialEnumeration(snapshotWindowIdentifiers: [])
        XCTAssertEqual(coordinator.recordCreated(3), [3])
        _ = coordinator.removeClosedWindowState(visibleWindowIdentifiers: [])
        _ = coordinator.removeClosedWindowState(visibleWindowIdentifiers: [3])

        XCTAssertFalse(coordinator.finishAttempt(for: 3, outcome: .applied))
        XCTAssertTrue(coordinator.handledWindowIdentifiers.contains(3))
    }

    func testGenerationChangeMakesPendingWindowsRetryable() {
        var coordinator: GlobalWindowPlacementCoordinator<Int> =
            GlobalWindowPlacementCoordinator(initialPolicy: .baseline)
        _ = coordinator.completeInitialEnumeration(snapshotWindowIdentifiers: [])
        XCTAssertEqual(coordinator.recordCreated(9), [9])

        coordinator.makePendingAttemptsTemporarilyUnavailable()

        XCTAssertTrue(coordinator.pendingWindowIdentifiers.isEmpty)
        XCTAssertTrue(coordinator.retryableWindowIdentifiers.contains(9))
        XCTAssertEqual(coordinator.reconcile(visibleWindowIdentifiers: [9]), [9])
    }

    func testLateAppliedResultWinsOverGenerationRetryState() {
        var coordinator: GlobalWindowPlacementCoordinator<Int> =
            GlobalWindowPlacementCoordinator(initialPolicy: .baseline)
        _ = coordinator.completeInitialEnumeration(snapshotWindowIdentifiers: [])
        XCTAssertEqual(coordinator.recordCreated(9), [9])
        coordinator.makePendingAttemptsTemporarilyUnavailable()

        coordinator.finishAttempt(for: 9, outcome: .applied)

        XCTAssertTrue(coordinator.handledWindowIdentifiers.contains(9))
        XCTAssertFalse(coordinator.retryableWindowIdentifiers.contains(9))
        XCTAssertEqual(coordinator.reconcile(visibleWindowIdentifiers: [9]), [])
    }

    func testRegistrationRetryRetainsTreatAsNewPolicyAndBacksOff() {
        var state: GlobalObserverRegistrationRetryState =
            GlobalObserverRegistrationRetryState(initialPolicy: .baseline)
        state.merge(initialPolicy: .treatAsNew)

        XCTAssertTrue(state.beginAttempt())
        XCTAssertFalse(state.beginAttempt())
        state.recordFailure()
        XCTAssertEqual(state.initialPolicy, .treatAsNew)
        XCTAssertEqual(state.delayBeforeNextAttemptMilliseconds, 100)

        XCTAssertTrue(state.beginAttempt())
        state.recordFailure()
        XCTAssertEqual(state.delayBeforeNextAttemptMilliseconds, 250)
    }

    func testRegistrationBackoffIsBounded() {
        var state: GlobalObserverRegistrationRetryState =
            GlobalObserverRegistrationRetryState(initialPolicy: .treatAsNew)

        for _ in 0..<20 {
            XCTAssertTrue(state.beginAttempt())
            state.recordFailure()
        }

        XCTAssertEqual(state.delayBeforeNextAttemptMilliseconds, 5_000)
    }

    func testAbandonedRegistrationCanBeStartedAgainWithoutFailureBackoff() {
        var state: GlobalObserverRegistrationRetryState =
            GlobalObserverRegistrationRetryState(initialPolicy: .treatAsNew)

        XCTAssertTrue(state.beginAttempt())
        state.abandonAttempt()

        XCTAssertFalse(state.attemptIsInFlight)
        XCTAssertEqual(state.failureCount, 0)
        XCTAssertEqual(state.initialPolicy, .treatAsNew)
        XCTAssertTrue(state.beginAttempt())
    }
}
