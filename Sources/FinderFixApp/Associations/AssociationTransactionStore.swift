import FinderFixCore
import Foundation

enum StoredAssociationRestorationState: String, Codable, Hashable, Sendable {
    case pending
    case restored
    case skippedNotApplied
    case skippedNoPreviousHandler
    case skippedCurrentStateUnavailable
    case skippedCurrentHandlerChanged
    case failed
}

enum StoredAssociationMutationState: String, Codable, Hashable, Sendable {
    case notStarted
    case pendingMutation
    case confirmedApplied
    case confirmedNotApplied
    case indeterminate
}

struct StoredAssociationEntry: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let planEntry: FileAssociationPlanEntry
    var mutationState: StoredAssociationMutationState
    var applyOutcome: FileAssociationApplyOutcome
    var attemptFailure: FileAssociationFailure?
    var restorationState: StoredAssociationRestorationState?
    var restorationDetail: String?
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        planEntry: FileAssociationPlanEntry,
        mutationState: StoredAssociationMutationState = .notStarted,
        applyOutcome: FileAssociationApplyOutcome = .notStarted,
        attemptFailure: FileAssociationFailure? = nil,
        restorationState: StoredAssociationRestorationState? = nil,
        restorationDetail: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.planEntry = planEntry
        self.mutationState = mutationState
        self.applyOutcome = applyOutcome
        self.attemptFailure = attemptFailure
        self.restorationState = restorationState
        self.restorationDetail = restorationDetail
        self.updatedAt = updatedAt
    }
}

enum StoredAssociationTransactionState: String, Codable, Hashable, Sendable {
    case applying
    case applied
    case failed
    case rolledBackAfterFailure
    case rollbackIncomplete
    case restored
}

struct StoredAssociationTransaction: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let plan: FileAssociationTransactionPlan
    var state: StoredAssociationTransactionState
    var entries: [StoredAssociationEntry]
    var completedAt: Date?

    init(plan: FileAssociationTransactionPlan) {
        self.id = plan.id
        self.plan = plan
        self.state = .applying
        self.entries = plan.entries.map { StoredAssociationEntry(planEntry: $0) }
        self.completedAt = nil
    }

    var targetApplication: ApplicationIdentity? {
        plan.entries.first?.targetHandler
    }

    var result: FileAssociationTransactionResult? {
        guard let completedAt else { return nil }
        return FileAssociationTransactionResult(
            plan: plan,
            completedAt: completedAt,
            results: entries.map { entry in
                FileAssociationEntryResult(
                    contentTypeIdentifier: entry.planEntry.contentType.identifier,
                    outcome: entry.applyOutcome
                )
            }
        )
    }
}

enum AssociationTransactionStoreError: LocalizedError, Sendable {
    case unreadableData
    case encodingFailed(description: String)

    var errorDescription: String? {
        switch self {
        case .unreadableData:
            "FinderFix could not read the saved association history."
        case .encodingFailed(let description):
            "FinderFix could not save the association history: \(description)"
        }
    }
}

protocol AssociationTransactionStoring: Sendable {
    func transactions() async throws -> [StoredAssociationTransaction]
    func upsert(_ transaction: StoredAssociationTransaction) async throws
    func remove(id: UUID) async throws
}

actor UserDefaultsAssociationTransactionStore: AssociationTransactionStoring {
    private static let defaultStorageKey: String = "FinderFix.fileAssociationTransactions.v2"

    private let defaults: UserDefaults
    private let storageKey: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        suiteName: String? = nil,
        storageKey: String = UserDefaultsAssociationTransactionStore.defaultStorageKey
    ) {
        if let suiteName, let suiteDefaults: UserDefaults = UserDefaults(suiteName: suiteName) {
            self.defaults = suiteDefaults
        } else {
            self.defaults = .standard
        }
        self.storageKey = storageKey
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    func transactions() async throws -> [StoredAssociationTransaction] {
        try loadTransactions()
    }

    func upsert(_ transaction: StoredAssociationTransaction) async throws {
        var storedTransactions: [StoredAssociationTransaction] = try loadTransactions()
        if let index: Array<StoredAssociationTransaction>.Index = storedTransactions.firstIndex(where: { $0.id == transaction.id }) {
            storedTransactions[index] = transaction
        } else {
            storedTransactions.append(transaction)
        }
        try persist(storedTransactions)
    }

    func remove(id: UUID) async throws {
        var storedTransactions: [StoredAssociationTransaction] = try loadTransactions()
        storedTransactions.removeAll { $0.id == id }
        try persist(storedTransactions)
    }

    private func loadTransactions() throws -> [StoredAssociationTransaction] {
        guard let data: Data = defaults.data(forKey: storageKey) else {
            return []
        }
        guard let decoded: [StoredAssociationTransaction] = try? decoder.decode(
            [StoredAssociationTransaction].self,
            from: data
        ) else {
            throw AssociationTransactionStoreError.unreadableData
        }
        return decoded.sorted { $0.plan.createdAt > $1.plan.createdAt }
    }

    private func persist(_ transactions: [StoredAssociationTransaction]) throws {
        do {
            let data: Data = try encoder.encode(transactions)
            defaults.set(data, forKey: storageKey)
        } catch {
            throw AssociationTransactionStoreError.encodingFailed(description: error.localizedDescription)
        }
    }
}
