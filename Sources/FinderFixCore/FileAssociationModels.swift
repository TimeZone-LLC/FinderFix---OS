import Foundation

public struct ApplicationIdentity: Codable, Hashable, Sendable {
    public let bundleIdentifier: String
    public let displayName: String
    public let applicationURL: URL

    public init(bundleIdentifier: String, displayName: String, applicationURL: URL) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.applicationURL = applicationURL
    }

    /// App locations and display names can change while the bundle identifier
    /// remains stable.
    public func representsSameApplication(as other: ApplicationIdentity) -> Bool {
        bundleIdentifier == other.bundleIdentifier
    }
}

public struct FileContentType: Codable, Hashable, Sendable, Identifiable {
    public let identifier: String
    public let isDeclared: Bool
    public let isDynamic: Bool
    public let filenameExtensions: [FileExtension]

    public var id: String {
        identifier
    }

    public init(
        identifier: String,
        isDeclared: Bool,
        isDynamic: Bool,
        filenameExtensions: [FileExtension]
    ) {
        self.identifier = identifier
        self.isDeclared = isDeclared
        self.isDynamic = isDynamic
        self.filenameExtensions = Self.deduplicated(filenameExtensions)
    }

    private static func deduplicated(_ extensions: [FileExtension]) -> [FileExtension] {
        var seenExtensions: Set<FileExtension> = []
        return extensions.filter { seenExtensions.insert($0).inserted }
    }
}

public struct ResolvedFileExtension: Codable, Hashable, Sendable {
    public let requestedExtension: FileExtension
    public let contentType: FileContentType

    public init(requestedExtension: FileExtension, contentType: FileContentType) {
        self.requestedExtension = requestedExtension
        self.contentType = contentType
    }
}

/// An explicit snapshot. A `nil` handler is different from an absent snapshot:
/// it means the system reported that no default handler exists.
public struct FileAssociationCurrentState: Codable, Hashable, Sendable, Identifiable {
    public let contentTypeIdentifier: String
    public let handler: ApplicationIdentity?

    public var id: String {
        contentTypeIdentifier
    }

    public init(contentTypeIdentifier: String, handler: ApplicationIdentity?) {
        self.contentTypeIdentifier = contentTypeIdentifier
        self.handler = handler
    }
}

public struct FileAssociationPlanEntry: Codable, Hashable, Sendable, Identifiable {
    public let contentType: FileContentType
    public let requestedExtensions: [FileExtension]
    public let previousHandler: ApplicationIdentity?
    public let targetHandler: ApplicationIdentity

    public var id: String {
        contentType.identifier
    }

    public var requiresChange: Bool {
        guard let previousHandler else {
            return true
        }
        return !previousHandler.representsSameApplication(as: targetHandler)
    }

    public init(
        contentType: FileContentType,
        requestedExtensions: [FileExtension],
        previousHandler: ApplicationIdentity?,
        targetHandler: ApplicationIdentity
    ) {
        self.contentType = contentType
        self.requestedExtensions = requestedExtensions
        self.previousHandler = previousHandler
        self.targetHandler = targetHandler
    }
}

public struct FileAssociationTransactionPlan: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let entries: [FileAssociationPlanEntry]

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        entries: [FileAssociationPlanEntry]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.entries = entries
    }
}

public enum FileAssociationPlanError: Error, Equatable, Sendable {
    case emptySelection
    case emptyContentTypeIdentifier
    case duplicateCurrentState(contentTypeIdentifier: String)
    case missingCurrentState(contentTypeIdentifier: String)
    case conflictingTypeMetadata(contentTypeIdentifier: String)
}

public struct FileAssociationFailure: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
        case consentDenied
        case unsupportedType
        case targetUnavailable
        case systemError
    }

    public let kind: Kind
    public let code: String?
    public let message: String

    public init(kind: Kind, code: String? = nil, message: String) {
        self.kind = kind
        self.code = code
        self.message = message
    }
}

public enum FileAssociationApplyOutcome: Codable, Hashable, Sendable {
    case notStarted
    case applied
    case unchanged
    case cancelled
    case failed(FileAssociationFailure)

    public var changedSystemState: Bool {
        if case .applied = self {
            return true
        }
        return false
    }
}

public struct FileAssociationEntryResult: Codable, Hashable, Sendable, Identifiable {
    public let contentTypeIdentifier: String
    public let outcome: FileAssociationApplyOutcome

    public var id: String {
        contentTypeIdentifier
    }

    public init(contentTypeIdentifier: String, outcome: FileAssociationApplyOutcome) {
        self.contentTypeIdentifier = contentTypeIdentifier
        self.outcome = outcome
    }
}

public struct FileAssociationTransactionResult: Codable, Hashable, Sendable, Identifiable {
    public let plan: FileAssociationTransactionPlan
    public let completedAt: Date
    public let results: [FileAssociationEntryResult]

    public var id: UUID {
        plan.id
    }

    public init(
        plan: FileAssociationTransactionPlan,
        completedAt: Date = Date(),
        results: [FileAssociationEntryResult]
    ) {
        self.plan = plan
        self.completedAt = completedAt
        self.results = results
    }
}

public enum FileAssociationRollbackSkipReason: Codable, Hashable, Sendable {
    case notApplied
    case noPreviousHandler
    case currentStateUnavailable
    case currentHandlerChanged(expected: ApplicationIdentity, actual: ApplicationIdentity?)
}

public enum FileAssociationRollbackAction: Codable, Hashable, Sendable {
    case restore(ApplicationIdentity)
    case skip(FileAssociationRollbackSkipReason)
}

public struct FileAssociationRollbackStep: Codable, Hashable, Sendable, Identifiable {
    public let entry: FileAssociationPlanEntry
    public let action: FileAssociationRollbackAction

    public var id: String {
        entry.id
    }

    public init(entry: FileAssociationPlanEntry, action: FileAssociationRollbackAction) {
        self.entry = entry
        self.action = action
    }
}

public struct FileAssociationRollbackPlan: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let sourceTransactionID: UUID
    public let createdAt: Date
    public let steps: [FileAssociationRollbackStep]

    public init(
        id: UUID = UUID(),
        sourceTransactionID: UUID,
        createdAt: Date = Date(),
        steps: [FileAssociationRollbackStep]
    ) {
        self.id = id
        self.sourceTransactionID = sourceTransactionID
        self.createdAt = createdAt
        self.steps = steps
    }
}

public enum FileAssociationPlanner {
    public static func makePlan(
        resolutions: [ResolvedFileExtension],
        targetHandler: ApplicationIdentity,
        currentStates: [FileAssociationCurrentState],
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) throws -> FileAssociationTransactionPlan {
        guard !resolutions.isEmpty else {
            throw FileAssociationPlanError.emptySelection
        }

        let currentStatesByType: [String: FileAssociationCurrentState] = try indexedCurrentStates(currentStates)
        var groupedEntries: [MutablePlanEntry] = []
        var groupIndexByType: [String: Int] = [:]

        for resolution: ResolvedFileExtension in resolutions {
            let identifier: String = resolution.contentType.identifier
            guard !identifier.isEmpty else {
                throw FileAssociationPlanError.emptyContentTypeIdentifier
            }

            if let groupIndex: Int = groupIndexByType[identifier] {
                let existingType: FileContentType = groupedEntries[groupIndex].contentType
                guard existingType.isDeclared == resolution.contentType.isDeclared,
                      existingType.isDynamic == resolution.contentType.isDynamic else {
                    throw FileAssociationPlanError.conflictingTypeMetadata(contentTypeIdentifier: identifier)
                }
                groupedEntries[groupIndex].merge(resolution)
            } else {
                groupIndexByType[identifier] = groupedEntries.count
                groupedEntries.append(MutablePlanEntry(resolution: resolution))
            }
        }

        let entries: [FileAssociationPlanEntry] = try groupedEntries.map { groupedEntry in
            let identifier: String = groupedEntry.contentType.identifier
            guard let currentState: FileAssociationCurrentState = currentStatesByType[identifier] else {
                throw FileAssociationPlanError.missingCurrentState(contentTypeIdentifier: identifier)
            }
            return FileAssociationPlanEntry(
                contentType: groupedEntry.contentType,
                requestedExtensions: groupedEntry.requestedExtensions,
                previousHandler: currentState.handler,
                targetHandler: targetHandler
            )
        }

        return FileAssociationTransactionPlan(id: id, createdAt: createdAt, entries: entries)
    }

    /// Builds rollback steps in reverse apply order. A changed current handler
    /// is treated as an external edit and is never overwritten automatically.
    public static func makeRollbackPlan(
        transaction: FileAssociationTransactionResult,
        currentStates: [FileAssociationCurrentState],
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) -> FileAssociationRollbackPlan {
        let currentStatesByType: [String: FileAssociationCurrentState] = uniquelyIndexedCurrentStates(currentStates)
        let resultsByType: [String: FileAssociationEntryResult] = uniquelyIndexedResults(transaction.results)

        let steps: [FileAssociationRollbackStep] = transaction.plan.entries.reversed().map { entry in
            guard let result: FileAssociationEntryResult = resultsByType[entry.id],
                  result.outcome.changedSystemState else {
                return FileAssociationRollbackStep(entry: entry, action: .skip(.notApplied))
            }
            guard let previousHandler: ApplicationIdentity = entry.previousHandler else {
                return FileAssociationRollbackStep(entry: entry, action: .skip(.noPreviousHandler))
            }
            guard let currentState: FileAssociationCurrentState = currentStatesByType[entry.id] else {
                return FileAssociationRollbackStep(entry: entry, action: .skip(.currentStateUnavailable))
            }
            guard let currentHandler: ApplicationIdentity = currentState.handler,
                  currentHandler.representsSameApplication(as: entry.targetHandler) else {
                return FileAssociationRollbackStep(
                    entry: entry,
                    action: .skip(
                        .currentHandlerChanged(
                            expected: entry.targetHandler,
                            actual: currentState.handler
                        )
                    )
                )
            }
            return FileAssociationRollbackStep(entry: entry, action: .restore(previousHandler))
        }

        return FileAssociationRollbackPlan(
            id: id,
            sourceTransactionID: transaction.plan.id,
            createdAt: createdAt,
            steps: steps
        )
    }

    private static func indexedCurrentStates(
        _ states: [FileAssociationCurrentState]
    ) throws -> [String: FileAssociationCurrentState] {
        var result: [String: FileAssociationCurrentState] = [:]
        for state: FileAssociationCurrentState in states {
            if result.updateValue(state, forKey: state.contentTypeIdentifier) != nil {
                throw FileAssociationPlanError.duplicateCurrentState(
                    contentTypeIdentifier: state.contentTypeIdentifier
                )
            }
        }
        return result
    }

    private static func uniquelyIndexedCurrentStates(
        _ states: [FileAssociationCurrentState]
    ) -> [String: FileAssociationCurrentState] {
        var result: [String: FileAssociationCurrentState] = [:]
        var duplicateIdentifiers: Set<String> = []
        for state: FileAssociationCurrentState in states {
            if result[state.id] != nil {
                duplicateIdentifiers.insert(state.id)
            } else {
                result[state.id] = state
            }
        }
        for identifier: String in duplicateIdentifiers {
            result.removeValue(forKey: identifier)
        }
        return result
    }

    private static func uniquelyIndexedResults(
        _ results: [FileAssociationEntryResult]
    ) -> [String: FileAssociationEntryResult] {
        var indexedResults: [String: FileAssociationEntryResult] = [:]
        var duplicateIdentifiers: Set<String> = []
        for result: FileAssociationEntryResult in results {
            if indexedResults[result.id] != nil {
                duplicateIdentifiers.insert(result.id)
            } else {
                indexedResults[result.id] = result
            }
        }
        for identifier: String in duplicateIdentifiers {
            indexedResults.removeValue(forKey: identifier)
        }
        return indexedResults
    }
}

private struct MutablePlanEntry {
    private(set) var contentType: FileContentType
    private(set) var requestedExtensions: [FileExtension]

    init(resolution: ResolvedFileExtension) {
        self.contentType = resolution.contentType
        self.requestedExtensions = [resolution.requestedExtension]
    }

    mutating func merge(_ resolution: ResolvedFileExtension) {
        if !requestedExtensions.contains(resolution.requestedExtension) {
            requestedExtensions.append(resolution.requestedExtension)
        }

        var filenameExtensions: [FileExtension] = contentType.filenameExtensions
        for fileExtension: FileExtension in resolution.contentType.filenameExtensions
            where !filenameExtensions.contains(fileExtension) {
            filenameExtensions.append(fileExtension)
        }
        contentType = FileContentType(
            identifier: contentType.identifier,
            isDeclared: contentType.isDeclared,
            isDynamic: contentType.isDynamic,
            filenameExtensions: filenameExtensions
        )
    }
}
