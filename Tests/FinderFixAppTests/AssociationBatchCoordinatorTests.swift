import FinderFixCore
import Foundation
import XCTest
@testable import FinderFixApp

@MainActor
final class AssociationBatchCoordinatorTests: XCTestCase {
    func testSuccessfulApplyPersistsWriteAheadStateBeforeVerifiedResult() async throws {
        let fixture: Fixture = try Fixture(typeNames: ["one"])
        let store: RecordingTransactionStore = RecordingTransactionStore()
        let workspace: MockWorkspaceAssociationService = MockWorkspaceAssociationService(
            handlers: fixture.previousHandlers
        )
        let coordinator: FileAssociationBatchCoordinator = FileAssociationBatchCoordinator(
            workspace: workspace,
            store: store
        )

        let result: StoredAssociationTransaction = try await coordinator.apply(fixture.plan)

        XCTAssertEqual(result.state, .applied)
        XCTAssertEqual(result.entries.first?.mutationState, .confirmedApplied)
        XCTAssertApplyOutcome(result.entries.first?.applyOutcome, equals: .applied)
        let writes: [StoredAssociationTransaction] = await store.writeLog()
        XCTAssertTrue(writes.contains { transaction in
            transaction.entries.first?.mutationState == .pendingMutation
                && transaction.entries.first?.applyOutcome == .notStarted
        })
        XCTAssertEqual(
            workspace.setCalls.map(\.application.bundleIdentifier),
            [fixture.target.bundleIdentifier]
        )
    }

    func testSetterFailureWithoutMutationDoesNotAttemptRollback() async throws {
        let fixture: Fixture = try Fixture(typeNames: ["one"])
        let store: RecordingTransactionStore = RecordingTransactionStore()
        let workspace: MockWorkspaceAssociationService = MockWorkspaceAssociationService(
            handlers: fixture.previousHandlers,
            setBehaviors: [fixture.types[0].identifier: [.failWithoutMutation]]
        )
        let coordinator: FileAssociationBatchCoordinator = FileAssociationBatchCoordinator(
            workspace: workspace,
            store: store
        )

        let result: StoredAssociationTransaction = try await coordinator.apply(fixture.plan)

        XCTAssertEqual(result.state, .failed)
        XCTAssertEqual(result.entries.first?.mutationState, .confirmedNotApplied)
        XCTAssertFailed(result.entries.first?.applyOutcome)
        XCTAssertEqual(workspace.setCalls.count, 1)
        XCTAssertTrue(workspace.currentHandler(for: fixture.types[0]).representsSameApplication(as: fixture.previous[0]))
    }

    func testVerificationFailureAfterMutationIsReconciledAndRolledBack() async throws {
        let fixture: Fixture = try Fixture(typeNames: ["one"])
        let typeIdentifier: String = fixture.types[0].identifier
        let store: RecordingTransactionStore = RecordingTransactionStore()
        let workspace: MockWorkspaceAssociationService = MockWorkspaceAssociationService(
            handlers: fixture.previousHandlers,
            readBehaviors: [typeIdentifier: [.returnCurrent, .fail]]
        )
        let coordinator: FileAssociationBatchCoordinator = FileAssociationBatchCoordinator(
            workspace: workspace,
            store: store
        )

        let result: StoredAssociationTransaction = try await coordinator.apply(fixture.plan)

        XCTAssertEqual(result.state, .rolledBackAfterFailure)
        XCTAssertEqual(result.entries.first?.mutationState, .confirmedApplied)
        XCTAssertApplyOutcome(result.entries.first?.applyOutcome, equals: .applied)
        XCTAssertEqual(result.entries.first?.restorationState, .restored)
        XCTAssertEqual(
            workspace.setCalls.map(\.application.bundleIdentifier),
            [fixture.target.bundleIdentifier, fixture.previous[0].bundleIdentifier]
        )
        XCTAssertTrue(workspace.currentHandler(for: fixture.types[0]).representsSameApplication(as: fixture.previous[0]))
    }

    func testPartialBatchFailureRollsBackPriorVerifiedChangesInReverseOrder() async throws {
        let fixture: Fixture = try Fixture(typeNames: ["one", "two"])
        let secondIdentifier: String = fixture.types[1].identifier
        let store: RecordingTransactionStore = RecordingTransactionStore()
        let workspace: MockWorkspaceAssociationService = MockWorkspaceAssociationService(
            handlers: fixture.previousHandlers,
            setBehaviors: [secondIdentifier: [.failWithoutMutation]]
        )
        let coordinator: FileAssociationBatchCoordinator = FileAssociationBatchCoordinator(
            workspace: workspace,
            store: store
        )

        let result: StoredAssociationTransaction = try await coordinator.apply(fixture.plan)

        XCTAssertEqual(result.state, .rolledBackAfterFailure)
        XCTAssertEqual(result.entries[0].restorationState, .restored)
        XCTAssertFailed(result.entries[1].applyOutcome)
        XCTAssertEqual(
            workspace.setCalls.map { "\($0.contentTypeIdentifier):\($0.application.bundleIdentifier)" },
            [
                "\(fixture.types[0].identifier):\(fixture.target.bundleIdentifier)",
                "\(fixture.types[1].identifier):\(fixture.target.bundleIdentifier)",
                "\(fixture.types[0].identifier):\(fixture.previous[0].bundleIdentifier)",
            ]
        )
        XCTAssertTrue(workspace.currentHandler(for: fixture.types[0]).representsSameApplication(as: fixture.previous[0]))
        XCTAssertTrue(workspace.currentHandler(for: fixture.types[1]).representsSameApplication(as: fixture.previous[1]))
    }

    func testHistoryRecoversInterruptedPendingMutationAndRestoresPreviousHandler() async throws {
        let fixture: Fixture = try Fixture(typeNames: ["one"])
        var interrupted: StoredAssociationTransaction = StoredAssociationTransaction(plan: fixture.plan)
        interrupted.entries[0].mutationState = .pendingMutation
        let store: RecordingTransactionStore = RecordingTransactionStore([interrupted])
        let workspace: MockWorkspaceAssociationService = MockWorkspaceAssociationService(
            handlers: [fixture.types[0].identifier: fixture.target]
        )
        let coordinator: FileAssociationBatchCoordinator = FileAssociationBatchCoordinator(
            workspace: workspace,
            store: store
        )

        let recoveredHistory: [StoredAssociationTransaction] = try await coordinator.history()
        let recovered: StoredAssociationTransaction = try XCTUnwrap(recoveredHistory.first)

        XCTAssertEqual(recovered.state, .rolledBackAfterFailure)
        XCTAssertEqual(recovered.entries[0].mutationState, .confirmedApplied)
        XCTAssertEqual(recovered.entries[0].restorationState, .restored)
        XCTAssertTrue(workspace.currentHandler(for: fixture.types[0]).representsSameApplication(as: fixture.previous[0]))
        XCTAssertEqual(
            workspace.setCalls.map(\.application.bundleIdentifier),
            [fixture.previous[0].bundleIdentifier]
        )
    }

    func testInterruptedRecoveryNeverOverwritesExternalHandlerDrift() async throws {
        let fixture: Fixture = try Fixture(typeNames: ["one"])
        let external: ApplicationIdentity = Fixture.application(name: "External")
        var interrupted: StoredAssociationTransaction = StoredAssociationTransaction(plan: fixture.plan)
        interrupted.entries[0].mutationState = .pendingMutation
        let store: RecordingTransactionStore = RecordingTransactionStore([interrupted])
        let workspace: MockWorkspaceAssociationService = MockWorkspaceAssociationService(
            handlers: [fixture.types[0].identifier: external]
        )
        let coordinator: FileAssociationBatchCoordinator = FileAssociationBatchCoordinator(
            workspace: workspace,
            store: store
        )

        let recoveredHistory: [StoredAssociationTransaction] = try await coordinator.history()
        let recovered: StoredAssociationTransaction = try XCTUnwrap(recoveredHistory.first)

        XCTAssertEqual(recovered.state, .rollbackIncomplete)
        XCTAssertEqual(recovered.entries[0].mutationState, .indeterminate)
        XCTAssertTrue(workspace.setCalls.isEmpty)
        XCTAssertTrue(workspace.currentHandler(for: fixture.types[0]).representsSameApplication(as: external))
    }
}

private actor RecordingTransactionStore: AssociationTransactionStoring {
    private var stored: [StoredAssociationTransaction]
    private var writes: [StoredAssociationTransaction] = []

    init(_ transactions: [StoredAssociationTransaction] = []) {
        self.stored = transactions
    }

    func transactions() async throws -> [StoredAssociationTransaction] {
        stored.sorted { $0.plan.createdAt > $1.plan.createdAt }
    }

    func upsert(_ transaction: StoredAssociationTransaction) async throws {
        if let index: Int = stored.firstIndex(where: { $0.id == transaction.id }) {
            stored[index] = transaction
        } else {
            stored.append(transaction)
        }
        writes.append(transaction)
    }

    func remove(id: UUID) async throws {
        stored.removeAll { $0.id == id }
    }

    func writeLog() -> [StoredAssociationTransaction] {
        writes
    }
}

@MainActor
private final class MockWorkspaceAssociationService: WorkspaceAssociationServicing {
    enum SetBehavior: Sendable {
        case succeed
        case failWithoutMutation
    }

    enum ReadBehavior: Sendable {
        case returnCurrent
        case fail
    }

    struct MockError: LocalizedError, Sendable {
        let message: String

        var errorDescription: String? { message }
    }

    struct SetCall: Sendable {
        let application: ApplicationIdentity
        let contentTypeIdentifier: String
    }

    private var handlers: [String: ApplicationIdentity]
    private var setBehaviors: [String: [SetBehavior]]
    private var readBehaviors: [String: [ReadBehavior]]
    private(set) var setCalls: [SetCall] = []

    init(
        handlers: [String: ApplicationIdentity],
        setBehaviors: [String: [SetBehavior]] = [:],
        readBehaviors: [String: [ReadBehavior]] = [:]
    ) {
        self.handlers = handlers
        self.setBehaviors = setBehaviors
        self.readBehaviors = readBehaviors
    }

    func currentState(for contentType: FileContentType) throws -> FileAssociationCurrentState {
        if var behaviors: [ReadBehavior] = readBehaviors[contentType.identifier], !behaviors.isEmpty {
            let behavior: ReadBehavior = behaviors.removeFirst()
            readBehaviors[contentType.identifier] = behaviors
            if case .fail = behavior {
                throw MockError(message: "Injected current-handler read failure")
            }
        }
        return FileAssociationCurrentState(
            contentTypeIdentifier: contentType.identifier,
            handler: handlers[contentType.identifier]
        )
    }

    func compatibleApplications(for contentType: FileContentType) throws -> [ApplicationIdentity] {
        Array(handlers.values)
    }

    func application(at url: URL) throws -> ApplicationIdentity {
        guard let application: ApplicationIdentity = handlers.values.first(where: {
            $0.applicationURL == url
        }) else {
            throw MockError(message: "Unknown application")
        }
        return application
    }

    func setDefaultApplication(
        _ application: ApplicationIdentity,
        for contentType: FileContentType
    ) async throws {
        setCalls.append(
            SetCall(application: application, contentTypeIdentifier: contentType.identifier)
        )
        var behaviors: [SetBehavior] = setBehaviors[contentType.identifier] ?? []
        let behavior: SetBehavior = behaviors.isEmpty ? .succeed : behaviors.removeFirst()
        setBehaviors[contentType.identifier] = behaviors

        switch behavior {
        case .succeed:
            handlers[contentType.identifier] = application
        case .failWithoutMutation:
            throw MockError(message: "Injected setter failure")
        }
    }

    func currentHandler(for contentType: FileContentType) -> ApplicationIdentity {
        handlers[contentType.identifier]!
    }
}

private struct Fixture {
    let types: [FileContentType]
    let previous: [ApplicationIdentity]
    let target: ApplicationIdentity
    let plan: FileAssociationTransactionPlan

    var previousHandlers: [String: ApplicationIdentity] {
        Dictionary(uniqueKeysWithValues: zip(types.map(\.identifier), previous))
    }

    init(typeNames: [String]) throws {
        let builtTypes: [FileContentType] = try typeNames.map { name in
            let fileExtension: FileExtension = try FileExtension(validating: name)
            return FileContentType(
                identifier: "com.example.\(name)",
                isDeclared: true,
                isDynamic: false,
                filenameExtensions: [fileExtension]
            )
        }
        let builtPrevious: [ApplicationIdentity] = typeNames.map {
            Self.application(name: "Previous-\($0)")
        }
        let builtTarget: ApplicationIdentity = Self.application(name: "Target")
        self.types = builtTypes
        self.previous = builtPrevious
        self.target = builtTarget
        self.plan = FileAssociationTransactionPlan(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_000),
            entries: zip(builtTypes, builtPrevious).map { contentType, previousHandler in
                FileAssociationPlanEntry(
                    contentType: contentType,
                    requestedExtensions: contentType.filenameExtensions,
                    previousHandler: previousHandler,
                    targetHandler: builtTarget
                )
            }
        )
    }

    static func application(name: String) -> ApplicationIdentity {
        ApplicationIdentity(
            bundleIdentifier: "com.example.\(name)",
            displayName: name,
            applicationURL: URL(fileURLWithPath: "/Applications/\(name).app")
        )
    }
}

private func XCTAssertApplyOutcome(
    _ actual: FileAssociationApplyOutcome?,
    equals expected: FileAssociationApplyOutcome,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(actual, expected, file: file, line: line)
}

private func XCTAssertFailed(
    _ outcome: FileAssociationApplyOutcome?,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .failed = outcome else {
        XCTFail("Expected a failed outcome, got \(String(describing: outcome)).", file: file, line: line)
        return
    }
}
