import AppKit
import Combine
import FinderFixCore
import Foundation
import UniformTypeIdentifiers

struct FileAssociationNotice: Identifiable, Sendable {
    enum Tone: Sendable {
        case information
        case success
        case warning
        case error
    }

    let id: UUID
    let tone: Tone
    let message: String

    init(tone: Tone, message: String) {
        self.id = UUID()
        self.tone = tone
        self.message = message
    }
}

enum AssociationManagerError: LocalizedError, Sendable {
    case unresolvedContentTypes
    case noApplicationSelected

    var errorDescription: String? {
        switch self {
        case .unresolvedContentTypes:
            return "Choose a content type for every ambiguous extension."
        case .noApplicationSelected:
            return "Choose the application that should open these files."
        }
    }
}

@MainActor
final class AssociationManagerViewModel: ObservableObject {
    @Published var extensionInput: String = ""
    @Published private(set) var resolutions: [FileExtensionResolution] = []
    @Published private(set) var selectedContentTypeIdentifiers: [FileExtension: String] = [:]
    @Published private(set) var compatibleApplications: [ApplicationIdentity] = []
    @Published private(set) var selectedApplication: ApplicationIdentity?
    @Published private(set) var previewPlan: FileAssociationTransactionPlan?
    @Published private(set) var history: [StoredAssociationTransaction] = []
    @Published private(set) var notice: FileAssociationNotice?
    @Published private(set) var isWorking: Bool = false

    private let resolver: any FileContentTypeResolving
    private let workspace: any WorkspaceAssociationServicing
    private let coordinator: any FileAssociationBatchCoordinating
    private var compatibleBundleIdentifiersByType: [String: Set<String>] = [:]
    private var operationTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?

    convenience init() {
        let workspace: NSWorkspaceAssociationService = NSWorkspaceAssociationService()
        let store: UserDefaultsAssociationTransactionStore = UserDefaultsAssociationTransactionStore()
        let coordinator: FileAssociationBatchCoordinator = FileAssociationBatchCoordinator(
            workspace: workspace,
            store: store
        )
        self.init(
            resolver: UniformFileContentTypeResolver(),
            workspace: workspace,
            coordinator: coordinator
        )
    }

    init(
        resolver: any FileContentTypeResolving,
        workspace: any WorkspaceAssociationServicing,
        coordinator: any FileAssociationBatchCoordinating
    ) {
        self.resolver = resolver
        self.workspace = workspace
        self.coordinator = coordinator
    }

    deinit {
        operationTask?.cancel()
        historyTask?.cancel()
    }

    var hasUnresolvedAmbiguities: Bool {
        resolutions.contains { resolution in
            selectedContentTypeIdentifiers[resolution.requestedExtension] == nil
        }
    }

    var canChooseApplication: Bool {
        !resolutions.isEmpty && !hasUnresolvedAmbiguities && !isWorking
    }

    var canApply: Bool {
        guard let previewPlan else { return false }
        return previewPlan.entries.contains(where: \.requiresChange)
            && selectedApplication != nil
            && !isWorking
    }

    func resolveInput() {
        guard !isWorking else { return }

        do {
            let fileExtensions: [FileExtension] = try ExtensionListParser.parse(extensionInput)
            let newResolutions: [FileExtensionResolution] = try resolver.resolve(fileExtensions)
            var newSelections: [FileExtension: String] = [:]

            for resolution: FileExtensionResolution in newResolutions {
                let priorSelection: String? = selectedContentTypeIdentifiers[resolution.requestedExtension]
                if let priorSelection,
                   resolution.candidates.contains(where: { $0.identifier == priorSelection }) {
                    newSelections[resolution.requestedExtension] = priorSelection
                } else if resolution.candidates.count == 1 {
                    newSelections[resolution.requestedExtension] = resolution.candidates[0].identifier
                }
            }

            resolutions = newResolutions
            selectedContentTypeIdentifiers = newSelections
            selectedApplication = nil
            previewPlan = nil
            notice = nil
            refreshCompatibleApplicationsAndPreview()
        } catch {
            resolutions = []
            selectedContentTypeIdentifiers = [:]
            compatibleApplications = []
            selectedApplication = nil
            previewPlan = nil
            notice = FileAssociationNotice(tone: .error, message: message(for: error))
        }
    }

    func selectedContentTypeIdentifier(for fileExtension: FileExtension) -> String? {
        selectedContentTypeIdentifiers[fileExtension]
    }

    func selectContentType(identifier: String, for fileExtension: FileExtension) {
        guard let resolution: FileExtensionResolution = resolutions.first(where: {
            $0.requestedExtension == fileExtension
        }), resolution.candidates.contains(where: { $0.identifier == identifier }) else {
            return
        }

        selectedContentTypeIdentifiers[fileExtension] = identifier
        selectedApplication = nil
        previewPlan = nil
        notice = nil
        refreshCompatibleApplicationsAndPreview()
    }

    func selectApplication(_ application: ApplicationIdentity) {
        selectedApplication = application
        rebuildPreview()
    }

    func chooseApplication() {
        guard canChooseApplication else { return }

        let panel: NSOpenPanel = NSOpenPanel()
        panel.title = "Choose an Application"
        panel.message = "Choose the application that should open the selected file types."
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        panel.begin { [weak self] response in
            guard response == .OK, let url: URL = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    self.selectedApplication = try self.workspace.application(at: url)
                    self.notice = nil
                    self.rebuildPreview()
                } catch {
                    self.notice = FileAssociationNotice(
                        tone: .error,
                        message: self.message(for: error)
                    )
                }
            }
        }
    }

    func targetAdvertisesSupport(for contentType: FileContentType) -> Bool {
        guard let selectedApplication else { return false }
        return compatibleBundleIdentifiersByType[contentType.identifier]?
            .contains(selectedApplication.bundleIdentifier) == true
    }

    func applyPreview() {
        guard !isWorking else { return }
        operationTask?.cancel()
        isWorking = true
        notice = FileAssociationNotice(
            tone: .information,
            message: "Waiting for macOS to apply the file associations."
        )

        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isWorking = false
                self.operationTask = nil
            }

            do {
                // Rebuild immediately before mutation so every previous handler
                // snapshot reflects the current Launch Services state.
                let plan: FileAssociationTransactionPlan = try self.makePlan()
                let transaction: StoredAssociationTransaction = try await self.coordinator.apply(plan)
                self.notice = Self.notice(for: transaction)
                self.previewPlan = nil
                self.history = try await self.coordinator.history()
            } catch is CancellationError {
                self.notice = FileAssociationNotice(
                    tone: .warning,
                    message: "The change was cancelled. FinderFix restored completed items when possible."
                )
                await self.reloadHistoryAfterOperation()
            } catch {
                self.notice = FileAssociationNotice(
                    tone: .error,
                    message: self.message(for: error)
                )
                await self.reloadHistoryAfterOperation()
            }
        }
    }

    func cancelCurrentOperation() {
        operationTask?.cancel()
    }

    func restorePreviousApplication(
        transactionID: UUID,
        contentTypeIdentifier: String
    ) {
        runHistoryOperation {
            try await self.coordinator.restorePreviousApplication(
                transactionID: transactionID,
                contentTypeIdentifier: contentTypeIdentifier
            )
        }
    }

    func restoreAllPreviousApplications(transactionID: UUID) {
        runHistoryOperation {
            try await self.coordinator.restoreAllPreviousApplications(
                transactionID: transactionID
            )
        }
    }

    func forget(transactionID: UUID) {
        runHistoryOperation {
            try await self.coordinator.forget(transactionID: transactionID)
            return nil
        }
    }

    func loadHistory() {
        historyTask?.cancel()
        historyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.history = try await self.coordinator.history()
            } catch is CancellationError {
                return
            } catch {
                self.notice = FileAssociationNotice(
                    tone: .error,
                    message: self.message(for: error)
                )
            }
        }
    }

    private func refreshCompatibleApplicationsAndPreview() {
        guard let selectedResolutions: [ResolvedFileExtension] = try? selectedResolutions() else {
            compatibleApplications = []
            compatibleBundleIdentifiersByType = [:]
            previewPlan = nil
            return
        }

        let contentTypes: [FileContentType] = selectedResolutions
            .map(\.contentType)
            .uniqued(on: \.identifier)
        var applicationsByType: [String: [ApplicationIdentity]] = [:]

        do {
            for contentType: FileContentType in contentTypes {
                applicationsByType[contentType.identifier] = try workspace.compatibleApplications(
                    for: contentType
                )
            }
        } catch {
            compatibleApplications = []
            compatibleBundleIdentifiersByType = [:]
            previewPlan = nil
            notice = FileAssociationNotice(tone: .error, message: message(for: error))
            return
        }

        compatibleBundleIdentifiersByType = applicationsByType.mapValues { applications in
            Set(applications.map(\.bundleIdentifier))
        }
        compatibleApplications = Self.intersection(of: applicationsByType, orderedBy: contentTypes)

        if let selectedApplication,
           !FileManager.default.fileExists(atPath: selectedApplication.applicationURL.path) {
            self.selectedApplication = nil
        }
        rebuildPreview()
    }

    private func rebuildPreview() {
        guard selectedApplication != nil else {
            previewPlan = nil
            return
        }

        do {
            previewPlan = try makePlan()
            notice = nil
        } catch {
            previewPlan = nil
            notice = FileAssociationNotice(tone: .error, message: message(for: error))
        }
    }

    private func makePlan() throws -> FileAssociationTransactionPlan {
        guard let selectedApplication else {
            throw AssociationManagerError.noApplicationSelected
        }
        let selectedResolutions: [ResolvedFileExtension] = try selectedResolutions()
        let contentTypes: [FileContentType] = selectedResolutions
            .map(\.contentType)
            .uniqued(on: \.identifier)
        let currentStates: [FileAssociationCurrentState] = try contentTypes.map {
            try workspace.currentState(for: $0)
        }

        return try FileAssociationPlanner.makePlan(
            resolutions: selectedResolutions,
            targetHandler: selectedApplication,
            currentStates: currentStates
        )
    }

    private func selectedResolutions() throws -> [ResolvedFileExtension] {
        guard !resolutions.isEmpty, !hasUnresolvedAmbiguities else {
            throw AssociationManagerError.unresolvedContentTypes
        }

        return try resolutions.map { resolution in
            guard let identifier: String = selectedContentTypeIdentifiers[resolution.requestedExtension],
                  let contentType: FileContentType = resolution.candidates.first(where: {
                      $0.identifier == identifier
                  }) else {
                throw AssociationManagerError.unresolvedContentTypes
            }
            return ResolvedFileExtension(
                requestedExtension: resolution.requestedExtension,
                contentType: contentType
            )
        }
    }

    private func runHistoryOperation(
        _ operation: @escaping @MainActor () async throws -> StoredAssociationTransaction?
    ) {
        guard !isWorking else { return }
        operationTask?.cancel()
        isWorking = true

        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isWorking = false
                self.operationTask = nil
            }
            do {
                let transaction: StoredAssociationTransaction? = try await operation()
                self.history = try await self.coordinator.history()
                if let transaction {
                    self.notice = FileAssociationNotice(
                        tone: transaction.state == .restored ? .success : .warning,
                        message: transaction.state == .restored
                            ? "The previous application was restored."
                            : "FinderFix restored the available previous applications and left conflicts unchanged."
                    )
                } else {
                    self.notice = FileAssociationNotice(
                        tone: .information,
                        message: "The history entry was removed. macOS file associations were not changed."
                    )
                }
            } catch {
                self.notice = FileAssociationNotice(
                    tone: .error,
                    message: self.message(for: error)
                )
                await self.reloadHistoryAfterOperation()
            }
        }
    }

    private func reloadHistoryAfterOperation() async {
        if let currentHistory: [StoredAssociationTransaction] = try? await coordinator.history() {
            history = currentHistory
        }
    }

    private func message(for error: any Error) -> String {
        if let parseError: ExtensionListParseError = error as? ExtensionListParseError {
            switch parseError {
            case .emptyInput:
                return "Enter at least one filename extension."
            case .invalidToken(let token, let reason):
                return "\(token) is not a valid filename extension: \(message(for: reason))"
            }
        }
        if let planError: FileAssociationPlanError = error as? FileAssociationPlanError {
            switch planError {
            case .emptySelection:
                return "Choose at least one filename extension."
            case .emptyContentTypeIdentifier:
                return "macOS returned an empty content type identifier."
            case .duplicateCurrentState(let identifier):
                return "macOS returned duplicate state for \(identifier)."
            case .missingCurrentState(let identifier):
                return "FinderFix could not read the current app for \(identifier)."
            case .conflictingTypeMetadata(let identifier):
                return "macOS returned conflicting definitions for \(identifier)."
            }
        }
        return error.localizedDescription
    }

    private func message(for error: FileExtension.ValidationError) -> String {
        switch error {
        case .empty:
            return "the value is empty"
        case .tooLong(let maximumLength):
            return "use no more than \(maximumLength) characters"
        case .containsInvalidCharacter(let character):
            return "the character “\(character)” is not allowed"
        }
    }

    private static func intersection(
        of applicationsByType: [String: [ApplicationIdentity]],
        orderedBy contentTypes: [FileContentType]
    ) -> [ApplicationIdentity] {
        guard let firstType: FileContentType = contentTypes.first,
              let firstApplications: [ApplicationIdentity] = applicationsByType[firstType.identifier] else {
            return []
        }

        let remainingBundleIdentifiers: [Set<String>] = contentTypes.dropFirst().map { contentType in
            Set((applicationsByType[contentType.identifier] ?? []).map(\.bundleIdentifier))
        }

        return firstApplications.filter { application in
            remainingBundleIdentifiers.allSatisfy { $0.contains(application.bundleIdentifier) }
        }
        .uniqued(on: \.stableIdentifier)
    }

    private static func notice(for transaction: StoredAssociationTransaction) -> FileAssociationNotice {
        switch transaction.state {
        case .applied:
            return FileAssociationNotice(
                tone: .success,
                message: "The selected default applications were updated."
            )
        case .rolledBackAfterFailure:
            return FileAssociationNotice(
                tone: .warning,
                message: "A change failed. FinderFix restored every item it had already changed."
            )
        case .rollbackIncomplete:
            return FileAssociationNotice(
                tone: .error,
                message: "A change failed, and at least one completed item could not be restored. Review the history below."
            )
        case .failed:
            return FileAssociationNotice(
                tone: .error,
                message: "macOS rejected the association change."
            )
        case .applying:
            return FileAssociationNotice(
                tone: .information,
                message: "The association change is still running."
            )
        case .restored:
            return FileAssociationNotice(
                tone: .success,
                message: "The previous applications were restored."
            )
        }
    }
}
