import Foundation

public enum GlobalWindowInitialPolicy: Sendable, Equatable {
    case baseline
    case treatAsNew

    public func merged(with other: GlobalWindowInitialPolicy) -> GlobalWindowInitialPolicy {
        if self == .treatAsNew || other == .treatAsNew {
            return .treatAsNew
        }
        return .baseline
    }
}

public enum GlobalWindowPlacementAttemptOutcome: Sendable, Equatable {
    case applied
    case permanentlyIneligible
    case temporarilyUnavailable
}

/// Tracks observation state without retaining Accessibility objects.
public struct GlobalWindowPlacementCoordinator<WindowIdentifier>: Sendable
where WindowIdentifier: Hashable & Sendable {
    public private(set) var initialPolicy: GlobalWindowInitialPolicy
    public private(set) var initialEnumerationIsPending: Bool = true
    public private(set) var pendingWindowIdentifiers: Set<WindowIdentifier> = []
    public private(set) var handledWindowIdentifiers: Set<WindowIdentifier> = []
    public private(set) var retryableWindowIdentifiers: Set<WindowIdentifier> = []

    private var deferredCreatedWindowIdentifiers: [WindowIdentifier] = []
    private var initialBaselinedWindowIdentifiers: [WindowIdentifier] = []
    private var pendingIdentifiersMissingFromEnumeration: Set<WindowIdentifier> = []

    public init(initialPolicy: GlobalWindowInitialPolicy) {
        self.initialPolicy = initialPolicy
    }

    /// Creation notifications are retained separately from the initial snapshot.
    /// A window can appear in both when it is created while the snapshot is read.
    public mutating func recordCreated(
        _ identifier: WindowIdentifier
    ) -> [WindowIdentifier] {
        pendingIdentifiersMissingFromEnumeration.remove(identifier)
        guard initialEnumerationIsPending else {
            return enqueue([identifier])
        }
        appendUnique(identifier, to: &deferredCreatedWindowIdentifiers)
        return []
    }

    public mutating func completeInitialEnumeration(
        snapshotWindowIdentifiers: [WindowIdentifier]
    ) -> [WindowIdentifier] {
        guard initialEnumerationIsPending else { return [] }
        initialEnumerationIsPending = false

        let deferredIdentifiers: [WindowIdentifier] = deferredCreatedWindowIdentifiers
        deferredCreatedWindowIdentifiers.removeAll()
        let deferredSet: Set<WindowIdentifier> = Set(deferredIdentifiers)

        switch initialPolicy {
        case .baseline:
            for identifier in snapshotWindowIdentifiers where !deferredSet.contains(identifier) {
                if handledWindowIdentifiers.insert(identifier).inserted {
                    appendUnique(identifier, to: &initialBaselinedWindowIdentifiers)
                }
            }
            return enqueue(deferredIdentifiers)
        case .treatAsNew:
            return enqueue(snapshotWindowIdentifiers + deferredIdentifiers)
        }
    }

    /// Promotes an initial baseline registration when the corresponding launch
    /// notification arrives later. Windows baselined by the startup race become
    /// pending exactly once; terminal placement results remain terminal.
    public mutating func mergeInitialPolicy(
        _ policy: GlobalWindowInitialPolicy
    ) -> [WindowIdentifier] {
        let mergedPolicy: GlobalWindowInitialPolicy = initialPolicy.merged(with: policy)
        guard mergedPolicy != initialPolicy else { return [] }
        initialPolicy = mergedPolicy
        guard !initialEnumerationIsPending, mergedPolicy == .treatAsNew else { return [] }

        let promotedIdentifiers: [WindowIdentifier] = initialBaselinedWindowIdentifiers
        initialBaselinedWindowIdentifiers.removeAll()
        handledWindowIdentifiers.subtract(promotedIdentifiers)
        return enqueue(promotedIdentifiers)
    }

    /// Failure leaves the initial phase intact. A later successful snapshot still
    /// distinguishes baseline windows from deferred creation notifications.
    public mutating func initialEnumerationFailed() {
        // State is intentionally retained for a later retry.
    }

    public mutating func reconcile(
        visibleWindowIdentifiers: [WindowIdentifier]
    ) -> [WindowIdentifier] {
        guard !initialEnumerationIsPending else { return [] }
        // Focus and Space changes can reveal existing windows absent from the
        // baseline. Only a creation or launch event may start their placement.
        let retryIdentifiers: [WindowIdentifier] = visibleWindowIdentifiers.filter {
            retryableWindowIdentifiers.contains($0)
        }
        return enqueue(retryIdentifiers)
    }

    @discardableResult
    public mutating func finishAttempt(
        for identifier: WindowIdentifier,
        outcome: GlobalWindowPlacementAttemptOutcome
    ) -> Bool {
        let windowWasConfirmedClosed: Bool = pendingIdentifiersMissingFromEnumeration.remove(
            identifier
        ) != nil
        switch outcome {
        case .applied, .permanentlyIneligible:
            pendingWindowIdentifiers.remove(identifier)
            retryableWindowIdentifiers.remove(identifier)
            if windowWasConfirmedClosed {
                handledWindowIdentifiers.remove(identifier)
            } else {
                handledWindowIdentifiers.insert(identifier)
            }
        case .temporarilyUnavailable:
            let attemptWasPending: Bool = pendingWindowIdentifiers.remove(identifier) != nil
            if windowWasConfirmedClosed {
                retryableWindowIdentifiers.remove(identifier)
            } else if attemptWasPending {
                retryableWindowIdentifiers.insert(identifier)
            }
        }
        return windowWasConfirmedClosed
    }

    public mutating func makePendingAttemptsTemporarilyUnavailable() {
        let pendingIdentifiers: Set<WindowIdentifier> = pendingWindowIdentifiers
        pendingWindowIdentifiers.removeAll()
        retryableWindowIdentifiers.formUnion(pendingIdentifiers)
    }

    /// Removes terminal state only after a successful full-window enumeration
    /// proves that the corresponding Accessibility element is no longer present.
    @discardableResult
    public mutating func removeClosedWindowState(
        visibleWindowIdentifiers: Set<WindowIdentifier>
    ) -> Set<WindowIdentifier> {
        guard !initialEnumerationIsPending else { return [] }
        pendingIdentifiersMissingFromEnumeration.formUnion(
            pendingWindowIdentifiers.subtracting(visibleWindowIdentifiers)
        )
        pendingIdentifiersMissingFromEnumeration.subtract(visibleWindowIdentifiers)
        let removableIdentifiers: Set<WindowIdentifier> = handledWindowIdentifiers
            .union(retryableWindowIdentifiers)
            .subtracting(pendingWindowIdentifiers)
            .subtracting(visibleWindowIdentifiers)
        handledWindowIdentifiers.subtract(removableIdentifiers)
        retryableWindowIdentifiers.subtract(removableIdentifiers)
        pendingIdentifiersMissingFromEnumeration.subtract(removableIdentifiers)
        initialBaselinedWindowIdentifiers.removeAll { identifier in
            removableIdentifiers.contains(identifier)
        }
        return removableIdentifiers
    }

    private mutating func enqueue(
        _ identifiers: [WindowIdentifier]
    ) -> [WindowIdentifier] {
        var scheduledIdentifiers: [WindowIdentifier] = []
        var seenInRequest: Set<WindowIdentifier> = []
        for identifier in identifiers {
            guard seenInRequest.insert(identifier).inserted,
                  !handledWindowIdentifiers.contains(identifier),
                  !pendingWindowIdentifiers.contains(identifier) else {
                continue
            }
            retryableWindowIdentifiers.remove(identifier)
            pendingWindowIdentifiers.insert(identifier)
            scheduledIdentifiers.append(identifier)
        }
        return scheduledIdentifiers
    }

    private func appendUnique(
        _ identifier: WindowIdentifier,
        to identifiers: inout [WindowIdentifier]
    ) {
        guard !identifiers.contains(identifier) else { return }
        identifiers.append(identifier)
    }
}

public struct GlobalObserverRegistrationRetryState: Sendable, Equatable {
    public private(set) var initialPolicy: GlobalWindowInitialPolicy
    public private(set) var failureCount: Int = 0
    public private(set) var attemptIsInFlight: Bool = false

    public init(initialPolicy: GlobalWindowInitialPolicy) {
        self.initialPolicy = initialPolicy
    }

    public mutating func merge(initialPolicy: GlobalWindowInitialPolicy) {
        self.initialPolicy = self.initialPolicy.merged(with: initialPolicy)
    }

    @discardableResult
    public mutating func beginAttempt() -> Bool {
        guard !attemptIsInFlight else { return false }
        attemptIsInFlight = true
        return true
    }

    public mutating func recordFailure() {
        guard attemptIsInFlight else { return }
        attemptIsInFlight = false
        failureCount = min(failureCount + 1, Int.max - 1)
    }

    public mutating func abandonAttempt() {
        attemptIsInFlight = false
    }

    public var delayBeforeNextAttemptMilliseconds: Int {
        switch failureCount {
        case 0: 0
        case 1: 100
        case 2: 250
        case 3: 500
        case 4: 1_000
        case 5: 2_000
        default: 5_000
        }
    }
}
