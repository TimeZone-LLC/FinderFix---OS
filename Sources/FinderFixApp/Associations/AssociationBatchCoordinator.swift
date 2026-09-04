import FinderFixCore
import Foundation

enum FileAssociationCoordinatorError: LocalizedError, Sendable {
    case busy
    case transactionNotFound(id: UUID)
    case entryNotFound(contentTypeIdentifier: String)
    case resultUnavailable(id: UUID)
    case noPreviousHandler(contentTypeIdentifier: String)
    case currentStateUnavailable(contentTypeIdentifier: String)
    case currentHandlerChanged(contentTypeIdentifier: String, currentApplicationName: String?)
    case interruptedRecoveryIncomplete
    case stalePlan(contentTypeIdentifier: String)

    var errorDescription: String? {
        switch self {
        case .busy:
            return "Another file-association change is still running."
        case .transactionNotFound(let id):
            return "The saved association transaction \(id.uuidString) no longer exists."
        case .entryNotFound(let contentTypeIdentifier):
            return "The saved transaction does not contain \(contentTypeIdentifier)."
        case .resultUnavailable(let id):
            return "The association transaction \(id.uuidString) did not finish and cannot be restored automatically."
        case .noPreviousHandler(let contentTypeIdentifier):
            return "macOS did not report a previous app for \(contentTypeIdentifier), so FinderFix cannot restore it."
        case .currentStateUnavailable(let contentTypeIdentifier):
            return "FinderFix could not read the current app for \(contentTypeIdentifier)."
        case .currentHandlerChanged(let contentTypeIdentifier, let currentApplicationName):
            let currentName: String = currentApplicationName ?? "another app"
            return "\(contentTypeIdentifier) now opens with \(currentName). FinderFix left that newer choice unchanged."
        case .interruptedRecoveryIncomplete:
            return "FinderFix could not reconcile an interrupted file-association change. Try again after macOS can report the current default app."
        case .stalePlan(let contentTypeIdentifier):
            return "The default app for \(contentTypeIdentifier) changed after the preview. Review the updated state and try again."
        }
    }
}

protocol FileAssociationBatchCoordinating: Sendable {
    func history() async throws -> [StoredAssociationTransaction]
    func apply(_ plan: FileAssociationTransactionPlan) async throws -> StoredAssociationTransaction
    func restorePreviousApplication(
        transactionID: UUID,
        contentTypeIdentifier: String
    ) async throws -> StoredAssociationTransaction
    func restoreAllPreviousApplications(transactionID: UUID) async throws -> StoredAssociationTransaction
    func forget(transactionID: UUID) async throws
}

actor FileAssociationBatchCoordinator: FileAssociationBatchCoordinating {
    private let workspace: any WorkspaceAssociationServicing
    private let store: any AssociationTransactionStoring
    private var mutationInProgress: Bool = false

    init(
        workspace: any WorkspaceAssociationServicing,
        store: any AssociationTransactionStoring
    ) {
        self.workspace = workspace
        self.store = store
    }

    func history() async throws -> [StoredAssociationTransaction] {
        try beginMutation()
        defer { mutationInProgress = false }
        try await recoverInterruptedTransactions(requireCompleteRecovery: false)
        return try await store.transactions()
    }

    func apply(_ plan: FileAssociationTransactionPlan) async throws -> StoredAssociationTransaction {
        try beginMutation()
        defer { mutationInProgress = false }

        try await recoverInterruptedTransactions(requireCompleteRecovery: true)
        try await validateCurrentStates(in: plan)

        var transaction: StoredAssociationTransaction = StoredAssociationTransaction(plan: plan)
        try await store.upsert(transaction)

        var batchFailed: Bool = false

        for index: Int in transaction.entries.indices {
            if Task.isCancelled {
                transaction.entries[index].mutationState = .confirmedNotApplied
                transaction.entries[index].applyOutcome = .cancelled
                transaction.entries[index].updatedAt = Date()
                batchFailed = true
                markRemainingEntriesCancelled(in: &transaction, after: index)
                break
            }

            let planEntry: FileAssociationPlanEntry = transaction.entries[index].planEntry
            guard planEntry.requiresChange else {
                transaction.entries[index].mutationState = .confirmedNotApplied
                transaction.entries[index].applyOutcome = .unchanged
                transaction.entries[index].updatedAt = Date()
                try await store.upsert(transaction)
                continue
            }

            // Durable write-ahead marker: after this succeeds, startup recovery
            // must assume the following call may have changed Launch Services.
            transaction.entries[index].mutationState = .pendingMutation
            transaction.entries[index].updatedAt = Date()
            try await store.upsert(transaction)

            do {
                try await workspace.setDefaultApplication(
                    planEntry.targetHandler,
                    for: planEntry.contentType
                )
                try await verify(
                    expectedApplication: planEntry.targetHandler,
                    contentType: planEntry.contentType
                )
                transaction.entries[index].mutationState = .confirmedApplied
                transaction.entries[index].applyOutcome = .applied
                transaction.entries[index].attemptFailure = nil
                transaction.entries[index].updatedAt = Date()
            } catch is CancellationError {
                let cancellationFailure: FileAssociationFailure = FileAssociationFailure(
                    kind: .systemError,
                    code: "CancellationError",
                    message: "The operation was cancelled."
                )
                _ = await reconcilePendingMutation(
                    at: index,
                    in: &transaction,
                    failure: cancellationFailure,
                    cancelled: true
                )
                batchFailed = true
                markRemainingEntriesCancelled(in: &transaction, after: index)
                try? await store.upsert(transaction)
                break
            } catch {
                _ = await reconcilePendingMutation(
                    at: index,
                    in: &transaction,
                    failure: failure(from: error, for: planEntry),
                    cancelled: false
                )
                batchFailed = true
                markRemainingEntriesCancelled(in: &transaction, after: index)
                try? await store.upsert(transaction)
                break
            }

            do {
                try await store.upsert(transaction)
            } catch {
                // The system change succeeded, so retain `.applied` and roll it
                // back rather than losing the previous-handler snapshot.
                batchFailed = true
                markRemainingEntriesCancelled(in: &transaction, after: index)
                break
            }

            if Task.isCancelled {
                batchFailed = true
                markRemainingEntriesCancelled(in: &transaction, after: index)
                break
            }
        }

        transaction.completedAt = Date()

        if batchFailed {
            if transaction.entries.contains(where: { $0.applyOutcome.changedSystemState }) {
                transaction.state = .failed
                transaction = await rollBackAppliedEntries(in: transaction)
                transaction.completedAt = Date()
            } else {
                transaction.state = transaction.needsMutationReview
                    ? .rollbackIncomplete
                    : .failed
            }
        } else {
            transaction.state = .applied
        }

        try await store.upsert(transaction)
        return transaction
    }

    func restorePreviousApplication(
        transactionID: UUID,
        contentTypeIdentifier: String
    ) async throws -> StoredAssociationTransaction {
        try beginMutation()
        defer { mutationInProgress = false }

        try await recoverInterruptedTransactions(requireCompleteRecovery: true)

        var transaction: StoredAssociationTransaction = try await transaction(id: transactionID)
        guard let index: Int = transaction.entries.firstIndex(where: {
            $0.planEntry.contentType.identifier == contentTypeIdentifier
        }) else {
            throw FileAssociationCoordinatorError.entryNotFound(
                contentTypeIdentifier: contentTypeIdentifier
            )
        }

        do {
            try await restoreEntry(at: index, in: &transaction)
            updateRestorationState(of: &transaction)
            try await store.upsert(transaction)
            return transaction
        } catch {
            updateRestorationState(of: &transaction)
            try? await store.upsert(transaction)
            throw error
        }
    }

    func restoreAllPreviousApplications(transactionID: UUID) async throws -> StoredAssociationTransaction {
        try beginMutation()
        defer { mutationInProgress = false }

        try await recoverInterruptedTransactions(requireCompleteRecovery: true)

        var transaction: StoredAssociationTransaction = try await transaction(id: transactionID)
        var firstError: (any Error)?

        for index: Int in transaction.entries.indices.reversed()
            where transaction.entries[index].applyOutcome.changedSystemState {
            do {
                try await restoreEntry(at: index, in: &transaction)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        updateRestorationState(of: &transaction)
        try await store.upsert(transaction)

        if let firstError {
            throw firstError
        }
        return transaction
    }

    func forget(transactionID: UUID) async throws {
        try beginMutation()
        defer { mutationInProgress = false }
        try await recoverInterruptedTransactions(requireCompleteRecovery: true)
        try await store.remove(id: transactionID)
    }

    private func beginMutation() throws {
        guard !mutationInProgress else {
            throw FileAssociationCoordinatorError.busy
        }
        mutationInProgress = true
    }

    private func transaction(id: UUID) async throws -> StoredAssociationTransaction {
        let transactions: [StoredAssociationTransaction] = try await store.transactions()
        guard let transaction: StoredAssociationTransaction = transactions.first(where: { $0.id == id }) else {
            throw FileAssociationCoordinatorError.transactionNotFound(id: id)
        }
        return transaction
    }

    private func recoverInterruptedTransactions(requireCompleteRecovery: Bool) async throws {
        let storedTransactions: [StoredAssociationTransaction] = try await store.transactions()
        var recoveryIncomplete: Bool = false

        for storedTransaction: StoredAssociationTransaction in storedTransactions
            where storedTransaction.state == .applying
                || storedTransaction.hasPendingMutation
                || storedTransaction.hasPendingRestoration {
            var transaction: StoredAssociationTransaction = storedTransaction
            let wasInterruptedApply: Bool = transaction.state == .applying
                || transaction.hasPendingMutation

            for index: Int in transaction.entries.indices {
                switch transaction.entries[index].mutationState {
                case .pendingMutation:
                    let failure: FileAssociationFailure = FileAssociationFailure(
                        kind: .systemError,
                        code: "interrupted",
                        message: "FinderFix was interrupted while changing this content type."
                    )
                    let unresolved: Bool = await reconcilePendingMutation(
                        at: index,
                        in: &transaction,
                        failure: failure,
                        cancelled: true
                    )
                    recoveryIncomplete = recoveryIncomplete || unresolved

                case .notStarted where wasInterruptedApply:
                    transaction.entries[index].mutationState = .confirmedNotApplied
                    transaction.entries[index].applyOutcome = .cancelled
                    transaction.entries[index].updatedAt = Date()

                case .notStarted,
                     .confirmedApplied,
                     .confirmedNotApplied,
                     .indeterminate:
                    break
                }
            }

            transaction.completedAt = Date()

            if wasInterruptedApply,
               transaction.entries.contains(where: { $0.applyOutcome.changedSystemState }) {
                transaction.state = .failed
                transaction = await rollBackAppliedEntries(in: transaction)
                transaction.completedAt = Date()
            } else if wasInterruptedApply {
                transaction.state = transaction.needsMutationReview
                    ? .rollbackIncomplete
                    : .failed
            }

            if transaction.hasPendingRestoration {
                transaction = await reconcilePendingRestorations(in: transaction)
            }
            if transaction.needsMutationReview || transaction.hasPendingRestoration {
                transaction.state = .rollbackIncomplete
            }
            recoveryIncomplete = recoveryIncomplete
                || transaction.hasPendingMutation
                || transaction.hasPendingRestoration

            try await store.upsert(transaction)
        }

        if requireCompleteRecovery && recoveryIncomplete {
            throw FileAssociationCoordinatorError.interruptedRecoveryIncomplete
        }
    }

    private func validateCurrentStates(in plan: FileAssociationTransactionPlan) async throws {
        for entry: FileAssociationPlanEntry in plan.entries {
            let currentState: FileAssociationCurrentState = try await workspace.currentState(
                for: entry.contentType
            )
            guard handlersMatch(currentState.handler, entry.previousHandler) else {
                throw FileAssociationCoordinatorError.stalePlan(
                    contentTypeIdentifier: entry.contentType.identifier
                )
            }
        }
    }

    /// Returns true only when macOS could not report enough state to decide
    /// whether the write-ahead mutation occurred.
    private func reconcilePendingMutation(
        at index: Int,
        in transaction: inout StoredAssociationTransaction,
        failure: FileAssociationFailure,
        cancelled: Bool
    ) async -> Bool {
        let entry: FileAssociationPlanEntry = transaction.entries[index].planEntry
        transaction.entries[index].attemptFailure = failure

        do {
            let currentState: FileAssociationCurrentState = try await workspace.currentState(
                for: entry.contentType
            )
            if let currentHandler: ApplicationIdentity = currentState.handler,
               currentHandler.representsSameApplication(as: entry.targetHandler) {
                transaction.entries[index].mutationState = .confirmedApplied
                transaction.entries[index].applyOutcome = .applied
            } else if handlersMatch(currentState.handler, entry.previousHandler) {
                transaction.entries[index].mutationState = .confirmedNotApplied
                transaction.entries[index].applyOutcome = cancelled
                    ? .cancelled
                    : .failed(failure)
            } else {
                transaction.entries[index].mutationState = .indeterminate
                transaction.entries[index].applyOutcome = .failed(
                    FileAssociationFailure(
                        kind: failure.kind,
                        code: failure.code,
                        message: "\(failure.message) A different current app was preserved."
                    )
                )
            }
            transaction.entries[index].updatedAt = Date()
            return false
        } catch {
            transaction.entries[index].mutationState = .pendingMutation
            transaction.entries[index].applyOutcome = .failed(
                FileAssociationFailure(
                    kind: .systemError,
                    code: failure.code,
                    message: "\(failure.message) The current app could not be reconciled: \(error.localizedDescription)"
                )
            )
            transaction.entries[index].updatedAt = Date()
            return true
        }
    }

    private func reconcilePendingRestorations(
        in transaction: StoredAssociationTransaction
    ) async -> StoredAssociationTransaction {
        var updatedTransaction: StoredAssociationTransaction = transaction

        for index: Int in updatedTransaction.entries.indices
            where updatedTransaction.entries[index].restorationState == .pending {
            let entry: FileAssociationPlanEntry = updatedTransaction.entries[index].planEntry
            guard let previousHandler: ApplicationIdentity = entry.previousHandler else {
                updatedTransaction.entries[index].restorationState = .skippedNoPreviousHandler
                updatedTransaction.entries[index].restorationDetail = "No previous app was reported by macOS."
                continue
            }

            do {
                let currentState: FileAssociationCurrentState = try await workspace.currentState(
                    for: entry.contentType
                )
                if let currentHandler: ApplicationIdentity = currentState.handler,
                   currentHandler.representsSameApplication(as: previousHandler) {
                    updatedTransaction.entries[index].restorationState = .restored
                    updatedTransaction.entries[index].restorationDetail = nil
                } else if let currentHandler: ApplicationIdentity = currentState.handler,
                          currentHandler.representsSameApplication(as: entry.targetHandler) {
                    // The rollback write did not land. Leave it retryable.
                    updatedTransaction.entries[index].restorationState = .failed
                    updatedTransaction.entries[index].restorationDetail = "The previous app was not restored."
                } else {
                    updatedTransaction.entries[index].restorationState = .skippedCurrentHandlerChanged
                    updatedTransaction.entries[index].restorationDetail = "A newer external app choice was preserved."
                }
            } catch {
                updatedTransaction.entries[index].restorationDetail = error.localizedDescription
            }
            updatedTransaction.entries[index].updatedAt = Date()
        }

        updateRestorationState(of: &updatedTransaction)
        return updatedTransaction
    }

    private func handlersMatch(
        _ lhs: ApplicationIdentity?,
        _ rhs: ApplicationIdentity?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (.some(let lhs), .some(let rhs)):
            return lhs.representsSameApplication(as: rhs)
        case (.some, nil), (nil, .some):
            return false
        }
    }

    private func verify(
        expectedApplication: ApplicationIdentity,
        contentType: FileContentType
    ) async throws {
        let currentState: FileAssociationCurrentState = try await workspace.currentState(for: contentType)
        guard let currentApplication: ApplicationIdentity = currentState.handler,
              currentApplication.representsSameApplication(as: expectedApplication) else {
            throw FileAssociationServiceError.verificationFailed(
                contentTypeIdentifier: contentType.identifier,
                expectedBundleIdentifier: expectedApplication.bundleIdentifier,
                actualBundleIdentifier: currentState.handler?.bundleIdentifier
            )
        }
    }

    private func markRemainingEntriesCancelled(
        in transaction: inout StoredAssociationTransaction,
        after index: Int
    ) {
        guard index < transaction.entries.index(before: transaction.entries.endIndex) else { return }
        for remainingIndex: Int in transaction.entries.index(after: index)..<transaction.entries.endIndex {
            guard case .notStarted = transaction.entries[remainingIndex].applyOutcome else { continue }
            transaction.entries[remainingIndex].mutationState = .confirmedNotApplied
            transaction.entries[remainingIndex].applyOutcome = .cancelled
            transaction.entries[remainingIndex].updatedAt = Date()
        }
    }

    private func rollBackAppliedEntries(
        in transaction: StoredAssociationTransaction
    ) async -> StoredAssociationTransaction {
        var updatedTransaction: StoredAssociationTransaction = transaction
        guard let result: FileAssociationTransactionResult = updatedTransaction.result else {
            updatedTransaction.state = .rollbackIncomplete
            return updatedTransaction
        }

        let currentStates: [FileAssociationCurrentState] = await currentStates(
            for: result.plan.entries.map(\.contentType)
        )
        let rollbackPlan: FileAssociationRollbackPlan = FileAssociationPlanner.makeRollbackPlan(
            transaction: result,
            currentStates: currentStates
        )
        var rollbackIncomplete: Bool = false

        for step: FileAssociationRollbackStep in rollbackPlan.steps {
            guard let index: Int = updatedTransaction.entries.firstIndex(where: {
                $0.planEntry.contentType.identifier == step.entry.contentType.identifier
            }) else { continue }

            switch step.action {
            case .restore(let previousApplication):
                if updatedTransaction.entries[index].restorationState == .restored {
                    continue
                }

                updatedTransaction.entries[index].restorationState = .pending
                updatedTransaction.entries[index].restorationDetail = nil
                updatedTransaction.entries[index].updatedAt = Date()
                do {
                    // Persist the rollback intent before touching Launch Services
                    // so a crash can reconcile whether restoration landed.
                    try await store.upsert(updatedTransaction)
                    try await workspace.setDefaultApplication(
                        previousApplication,
                        for: step.entry.contentType
                    )
                    try await verify(
                        expectedApplication: previousApplication,
                        contentType: step.entry.contentType
                    )
                    updatedTransaction.entries[index].restorationState = .restored
                    updatedTransaction.entries[index].restorationDetail = nil
                } catch {
                    let restored: Bool = await reconcileRestorationFailure(
                        at: index,
                        in: &updatedTransaction,
                        error: error
                    )
                    rollbackIncomplete = rollbackIncomplete || !restored
                }

            case .skip(let reason):
                if case .currentHandlerChanged(_, let actualHandler) = reason,
                   let previousHandler: ApplicationIdentity = step.entry.previousHandler,
                   let actualHandler,
                   actualHandler.representsSameApplication(as: previousHandler) {
                    updatedTransaction.entries[index].restorationState = .restored
                    updatedTransaction.entries[index].restorationDetail = nil
                } else {
                    let mappedReason: (StoredAssociationRestorationState, String?) = restorationState(for: reason)
                    updatedTransaction.entries[index].restorationState = mappedReason.0
                    updatedTransaction.entries[index].restorationDetail = mappedReason.1
                    if mappedReason.0 != .skippedNotApplied {
                        rollbackIncomplete = true
                    }
                }
            }
            updatedTransaction.entries[index].updatedAt = Date()
            try? await store.upsert(updatedTransaction)
        }

        updatedTransaction.state = rollbackIncomplete ? .rollbackIncomplete : .rolledBackAfterFailure
        return updatedTransaction
    }

    private func reconcileRestorationFailure(
        at index: Int,
        in transaction: inout StoredAssociationTransaction,
        error: any Error
    ) async -> Bool {
        let entry: FileAssociationPlanEntry = transaction.entries[index].planEntry
        guard let previousHandler: ApplicationIdentity = entry.previousHandler else {
            transaction.entries[index].restorationState = .skippedNoPreviousHandler
            transaction.entries[index].restorationDetail = "No previous app was reported by macOS."
            return false
        }

        do {
            let currentState: FileAssociationCurrentState = try await workspace.currentState(
                for: entry.contentType
            )
            if let currentHandler: ApplicationIdentity = currentState.handler,
               currentHandler.representsSameApplication(as: previousHandler) {
                transaction.entries[index].restorationState = .restored
                transaction.entries[index].restorationDetail = nil
                return true
            }
            if let currentHandler: ApplicationIdentity = currentState.handler,
               currentHandler.representsSameApplication(as: entry.targetHandler) {
                transaction.entries[index].restorationState = .failed
                transaction.entries[index].restorationDetail = error.localizedDescription
            } else {
                transaction.entries[index].restorationState = .skippedCurrentHandlerChanged
                transaction.entries[index].restorationDetail = "A newer external app choice was preserved."
            }
        } catch {
            // Keep the write-ahead restoration marker for startup recovery.
            transaction.entries[index].restorationState = .pending
            transaction.entries[index].restorationDetail = error.localizedDescription
        }
        return false
    }

    private func currentStates(for contentTypes: [FileContentType]) async -> [FileAssociationCurrentState] {
        var states: [FileAssociationCurrentState] = []
        states.reserveCapacity(contentTypes.count)
        for contentType: FileContentType in contentTypes {
            if let state: FileAssociationCurrentState = try? await workspace.currentState(for: contentType) {
                states.append(state)
            }
        }
        return states
    }

    private func restoreEntry(
        at index: Int,
        in transaction: inout StoredAssociationTransaction
    ) async throws {
        let entry: FileAssociationPlanEntry = transaction.entries[index].planEntry
        guard transaction.entries[index].applyOutcome.changedSystemState else {
            transaction.entries[index].restorationState = .skippedNotApplied
            transaction.entries[index].restorationDetail = "FinderFix did not change this content type."
            transaction.entries[index].updatedAt = Date()
            return
        }
        guard let previousHandler: ApplicationIdentity = entry.previousHandler else {
            transaction.entries[index].restorationState = .skippedNoPreviousHandler
            transaction.entries[index].restorationDetail = "No previous app was reported by macOS."
            transaction.entries[index].updatedAt = Date()
            throw FileAssociationCoordinatorError.noPreviousHandler(
                contentTypeIdentifier: entry.contentType.identifier
            )
        }

        let currentState: FileAssociationCurrentState
        do {
            currentState = try await workspace.currentState(for: entry.contentType)
        } catch {
            transaction.entries[index].restorationState = .skippedCurrentStateUnavailable
            transaction.entries[index].restorationDetail = error.localizedDescription
            transaction.entries[index].updatedAt = Date()
            throw FileAssociationCoordinatorError.currentStateUnavailable(
                contentTypeIdentifier: entry.contentType.identifier
            )
        }

        if let currentHandler: ApplicationIdentity = currentState.handler,
           currentHandler.representsSameApplication(as: previousHandler) {
            transaction.entries[index].restorationState = .restored
            transaction.entries[index].restorationDetail = nil
            transaction.entries[index].updatedAt = Date()
            return
        }

        guard let currentHandler: ApplicationIdentity = currentState.handler,
              currentHandler.representsSameApplication(as: entry.targetHandler) else {
            transaction.entries[index].restorationState = .skippedCurrentHandlerChanged
            transaction.entries[index].restorationDetail = "The current handler was changed outside FinderFix."
            transaction.entries[index].updatedAt = Date()
            throw FileAssociationCoordinatorError.currentHandlerChanged(
                contentTypeIdentifier: entry.contentType.identifier,
                currentApplicationName: currentState.handler?.displayName
            )
        }

        transaction.entries[index].restorationState = .pending
        transaction.entries[index].restorationDetail = nil
        transaction.entries[index].updatedAt = Date()
        try await store.upsert(transaction)

        do {
            try await workspace.setDefaultApplication(previousHandler, for: entry.contentType)
            try await verify(
                expectedApplication: previousHandler,
                contentType: entry.contentType
            )
            transaction.entries[index].restorationState = .restored
            transaction.entries[index].restorationDetail = nil
            transaction.entries[index].updatedAt = Date()
        } catch {
            let restored: Bool = await reconcileRestorationFailure(
                at: index,
                in: &transaction,
                error: error
            )
            transaction.entries[index].updatedAt = Date()
            if !restored {
                throw error
            }
        }
    }

    private func updateRestorationState(of transaction: inout StoredAssociationTransaction) {
        let changedEntries: [StoredAssociationEntry] = transaction.entries.filter {
            $0.applyOutcome.changedSystemState
        }
        if changedEntries.allSatisfy({ $0.restorationState == .restored }) {
            transaction.state = .restored
        } else if changedEntries.contains(where: { entry in
            guard let restorationState: StoredAssociationRestorationState = entry.restorationState else {
                return false
            }
            return restorationState != .restored && restorationState != .skippedNotApplied
        }) {
            transaction.state = .rollbackIncomplete
        }
    }

    private func restorationState(
        for reason: FileAssociationRollbackSkipReason
    ) -> (StoredAssociationRestorationState, String?) {
        switch reason {
        case .notApplied:
            (.skippedNotApplied, "FinderFix did not change this content type.")
        case .noPreviousHandler:
            (.skippedNoPreviousHandler, "No previous app was reported by macOS.")
        case .currentStateUnavailable:
            (.skippedCurrentStateUnavailable, "The current app could not be read.")
        case .currentHandlerChanged(_, let actual):
            (
                .skippedCurrentHandlerChanged,
                "The current app is \(actual?.displayName ?? "unknown") and was not overwritten."
            )
        }
    }

    private func failure(
        from error: any Error,
        for entry: FileAssociationPlanEntry
    ) -> FileAssociationFailure {
        let nsError: NSError = error as NSError
        let kind: FileAssociationFailure.Kind

        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
            kind = .consentDenied
        } else if !FileManager.default.fileExists(atPath: entry.targetHandler.applicationURL.path) {
            kind = .targetUnavailable
        } else if entry.contentType.isDynamic {
            kind = .unsupportedType
        } else {
            kind = .systemError
        }

        return FileAssociationFailure(
            kind: kind,
            code: "\(nsError.domain):\(nsError.code)",
            message: error.localizedDescription
        )
    }
}

private extension StoredAssociationTransaction {
    var hasPendingMutation: Bool {
        entries.contains { $0.mutationState == .pendingMutation }
    }

    var needsMutationReview: Bool {
        entries.contains {
            $0.mutationState == .pendingMutation || $0.mutationState == .indeterminate
        }
    }

    var hasPendingRestoration: Bool {
        entries.contains { $0.restorationState == .pending }
    }
}
