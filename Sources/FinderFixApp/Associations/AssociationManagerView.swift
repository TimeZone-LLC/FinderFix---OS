import AppKit
import FinderFixCore
import SwiftUI

private struct PendingAssociationEntryRestore {
    let transactionID: UUID
    let entry: StoredAssociationEntry

    var confirmationMessage: String {
        let planEntry: FileAssociationPlanEntry = entry.planEntry
        let previousApplicationName: String = planEntry.previousHandler?.displayName
            ?? "the captured previous application"
        return "FinderFix will restore \(previousApplicationName) as the default for \(planEntry.contentType.associationDisplayName) (\(planEntry.contentType.identifier)). macOS applies this to the complete content type\(planEntry.contentType.registeredExtensionClause). If another app changed this default after FinderFix, that newer choice will be left alone."
    }
}

struct AssociationManagerView: View {
    @StateObject private var viewModel: AssociationManagerViewModel
    @State private var showingApplyConfirmation: Bool = false
    @State private var entryPendingRestore: PendingAssociationEntryRestore?
    @State private var transactionPendingRestoreAll: StoredAssociationTransaction?
    @State private var transactionPendingForget: StoredAssociationTransaction?

    @MainActor
    init(viewModel: AssociationManagerViewModel = AssociationManagerViewModel()) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ArcaneTokens.sectionSpacing) {
                ArcaneSectionHeader(
                    title: "Default Applications",
                    detail: "Set one application for a list of filename extensions and restore defaults captured before FinderFix changes them."
                )

                ArcaneCard {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("What “Clear” means", systemImage: "arrow.uturn.backward.circle")
                            .font(.headline)
                        Text("Supported public macOS APIs can assign a default application, but they cannot unset a type back to automatic selection or “no handler.” In FinderFix, Clear means restoring the previous app captured before FinderFix made its change. If no previous app was captured, that default cannot be cleared here. Forget removes only FinderFix’s local history and never changes a macOS association.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if let notice: FileAssociationNotice = viewModel.notice {
                    AssociationNoticeView(notice: notice)
                }

                inputCard

                if !viewModel.resolutions.isEmpty {
                    contentTypeCard
                }

                if viewModel.canChooseApplication {
                    applicationCard
                }

                if let plan: FileAssociationTransactionPlan = viewModel.previewPlan {
                    previewCard(plan: plan)
                }

                historySection
            }
            .arcaneSettingsPage()
        }
        .onAppear {
            viewModel.loadHistory()
        }
        .confirmationDialog(
            "Change default applications?",
            isPresented: $showingApplyConfirmation,
            titleVisibility: .visible
        ) {
            Button("Apply Changes") {
                viewModel.applyPreview()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(applyConfirmationMessage)
        }
        .confirmationDialog(
            entryRestoreConfirmationTitle,
            isPresented: entryRestoreConfirmationBinding,
            titleVisibility: .visible,
            presenting: entryPendingRestore
        ) { request in
            Button("Restore Previous App") {
                viewModel.restorePreviousApplication(
                    transactionID: request.transactionID,
                    contentTypeIdentifier: request.entry.planEntry.contentType.identifier
                )
                entryPendingRestore = nil
            }
            Button("Cancel", role: .cancel) {
                entryPendingRestore = nil
            }
        } message: { request in
            Text(request.confirmationMessage)
        }
        .confirmationDialog(
            restoreAllConfirmationTitle,
            isPresented: restoreAllConfirmationBinding,
            titleVisibility: .visible,
            presenting: transactionPendingRestoreAll
        ) { transaction in
            Button("Restore All Captured Defaults") {
                viewModel.restoreAllPreviousApplications(transactionID: transaction.id)
                transactionPendingRestoreAll = nil
            }
            Button("Cancel", role: .cancel) {
                transactionPendingRestoreAll = nil
            }
        } message: { transaction in
            Text(transaction.restoreAllConfirmationMessage)
        }
        .confirmationDialog(
            "Forget this history entry?",
            isPresented: forgetConfirmationBinding,
            titleVisibility: .visible,
            presenting: transactionPendingForget
        ) { transaction in
            Button("Forget from FinderFix", role: .destructive) {
                viewModel.forget(transactionID: transaction.id)
                transactionPendingForget = nil
            }
            Button("Cancel", role: .cancel) {
                transactionPendingForget = nil
            }
        } message: { _ in
            Text("This only removes FinderFix’s saved rollback information. It does not change the current macOS file associations.")
        }
    }

    private var inputCard: some View {
        ArcaneCard {
            VStack(alignment: .leading, spacing: ArcaneTokens.controlSpacing) {
                Text("Filename extensions")
                    .font(.headline)
                Text("Enter extensions separated by commas, spaces, or new lines. Use the final extension only, without wildcards.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                TextEditor(text: $viewModel.extensionInput)
                    .font(.body.monospaced())
                    .frame(minHeight: 58, maxHeight: 92)
                    .padding(6)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.65))
                    .clipShape(RoundedRectangle(cornerRadius: ArcaneTokens.controlRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: ArcaneTokens.controlRadius)
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                    }
                    .accessibilityLabel("Filename extensions")

                HStack {
                    Button("Resolve Extensions") {
                        viewModel.resolveInput()
                    }
                    .buttonStyle(ArcanePrimaryButtonStyle())
                    .disabled(viewModel.isWorking)

                    if viewModel.isWorking {
                        ProgressView()
                            .controlSize(.small)
                        Button("Cancel") {
                            viewModel.cancelCurrentOperation()
                        }
                    }
                }
            }
        }
    }

    private var contentTypeCard: some View {
        ArcaneCard {
            VStack(alignment: .leading, spacing: ArcaneTokens.controlSpacing) {
                Text("Content types")
                    .font(.headline)
                Text("macOS stores defaults by content type, not by extension. Choose the intended type when an extension is ambiguous.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ForEach(viewModel.resolutions) { resolution in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(resolution.requestedExtension.displayValue)
                                .font(.body.monospaced().weight(.semibold))
                                .frame(width: 92, alignment: .leading)

                            if resolution.candidates.count == 1,
                               let candidate: FileContentType = resolution.candidates.first {
                                ContentTypeLabel(contentType: candidate)
                            } else {
                                Menu {
                                    ForEach(resolution.candidates) { candidate in
                                        Button {
                                            viewModel.selectContentType(
                                                identifier: candidate.identifier,
                                                for: resolution.requestedExtension
                                            )
                                        } label: {
                                            Text("\(candidate.associationDisplayName) — \(candidate.identifier)")
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        if let selected: FileContentType = selectedCandidate(for: resolution) {
                                            ContentTypeLabel(contentType: selected)
                                        } else {
                                            Label("Choose a content type", systemImage: "questionmark.diamond")
                                                .foregroundStyle(ArcaneTokens.warning)
                                        }
                                    }
                                }
                                .menuStyle(.borderlessButton)
                            }
                            Spacer(minLength: 0)
                        }

                        if resolution.candidates.count > 1 {
                            Text("\(resolution.candidates.count) registered meanings were found for this extension.")
                                .font(.caption)
                                .foregroundStyle(ArcaneTokens.warning)
                                .padding(.leading, 92)
                        }
                    }

                    if resolution.id != viewModel.resolutions.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private var applicationCard: some View {
        ArcaneCard {
            VStack(alignment: .leading, spacing: ArcaneTokens.controlSpacing) {
                Text("Target application")
                    .font(.headline)

                if let application: ApplicationIdentity = viewModel.selectedApplication {
                    ApplicationLabel(application: application)
                } else {
                    Text("No application selected")
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Menu("Compatible Applications") {
                        if viewModel.compatibleApplications.isEmpty {
                            Text("No app advertises support for every selected type")
                        } else {
                            ForEach(viewModel.compatibleApplications, id: \.stableIdentifier) { application in
                                Button(application.displayName) {
                                    viewModel.selectApplication(application)
                                }
                            }
                        }
                    }
                    .disabled(viewModel.compatibleApplications.isEmpty)

                    Button("Choose Other…") {
                        viewModel.chooseApplication()
                    }
                }

                Text("“Choose Other” permits any application bundle. The preview warns when that app does not advertise support, and macOS may reject the change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func previewCard(plan: FileAssociationTransactionPlan) -> some View {
        ArcaneCard {
            VStack(alignment: .leading, spacing: ArcaneTokens.controlSpacing) {
                HStack {
                    Text("Review changes")
                        .font(.headline)
                    Spacer()
                    if plan.entries.allSatisfy({ !$0.requiresChange }) {
                        ArcaneStatusBadge(text: "Already Set", tone: .positive)
                    }
                }

                ForEach(plan.entries) { entry in
                    AssociationPreviewEntryView(
                        entry: entry,
                        targetAdvertisesSupport: viewModel.targetAdvertisesSupport(
                            for: entry.contentType
                        )
                    )

                    if entry.id != plan.entries.last?.id {
                        Divider()
                    }
                }

                HStack {
                    Button("Apply Changes") {
                        showingApplyConfirmation = true
                    }
                    .buttonStyle(ArcanePrimaryButtonStyle())
                    .disabled(!viewModel.canApply)

                    Text("Changes are applied serially and verified after each item.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: ArcaneTokens.controlSpacing) {
            ArcaneSectionHeader(
                title: "FinderFix History",
                detail: "Restore the app captured before each FinderFix change, or forget only the saved rollback record."
            )

            if viewModel.history.isEmpty {
                ArcaneCard {
                    Text("No file-association changes have been saved yet.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(viewModel.history) { transaction in
                    AssociationHistoryCard(
                        transaction: transaction,
                        isWorking: viewModel.isWorking,
                        restoreEntry: { entry in
                            entryPendingRestore = PendingAssociationEntryRestore(
                                transactionID: transaction.id,
                                entry: entry
                            )
                        },
                        restoreAll: {
                            transactionPendingRestoreAll = transaction
                        },
                        forget: {
                            transactionPendingForget = transaction
                        }
                    )
                }
            }
        }
    }

    private var forgetConfirmationBinding: Binding<Bool> {
        Binding(
            get: { transactionPendingForget != nil },
            set: { isPresented in
                if !isPresented {
                    transactionPendingForget = nil
                }
            }
        )
    }

    private var entryRestoreConfirmationBinding: Binding<Bool> {
        Binding(
            get: { entryPendingRestore != nil },
            set: { isPresented in
                if !isPresented {
                    entryPendingRestore = nil
                }
            }
        )
    }

    private var restoreAllConfirmationBinding: Binding<Bool> {
        Binding(
            get: { transactionPendingRestoreAll != nil },
            set: { isPresented in
                if !isPresented {
                    transactionPendingRestoreAll = nil
                }
            }
        )
    }

    private var entryRestoreConfirmationTitle: String {
        guard let request: PendingAssociationEntryRestore = entryPendingRestore else {
            return "Restore the previous app?"
        }
        return "Restore the previous app for \(request.entry.requestedExtensionSummary)?"
    }

    private var restoreAllConfirmationTitle: String {
        guard let transaction: StoredAssociationTransaction = transactionPendingRestoreAll else {
            return "Restore all captured defaults?"
        }
        let count: Int = transaction.entries.filter(\.canRestore).count
        return "Restore \(count) captured \(count == 1 ? "default" : "defaults")?"
    }

    private var applyConfirmationMessage: String {
        guard let plan: FileAssociationTransactionPlan = viewModel.previewPlan else {
            return "No file-association changes are ready to apply."
        }
        let entries: [FileAssociationPlanEntry] = plan.entries.filter(\.requiresChange)
        let typeIdentifiers: String = entries
            .map { $0.contentType.identifier }
            .joined(separator: ", ")
        return "This changes the default application for \(entries.count) macOS content \(entries.count == 1 ? "type" : "types"): \(typeIdentifiers). A content-type change can affect every filename extension mapped to that type."
    }

    private func selectedCandidate(for resolution: FileExtensionResolution) -> FileContentType? {
        guard let identifier: String = viewModel.selectedContentTypeIdentifier(
            for: resolution.requestedExtension
        ) else {
            return nil
        }
        return resolution.candidates.first { $0.identifier == identifier }
    }
}

private struct ContentTypeLabel: View {
    let contentType: FileContentType

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(contentType.associationDisplayName)
                if contentType.isDynamic {
                    ArcaneStatusBadge(text: "Dynamic", tone: .warning)
                }
            }
            Text(contentType.identifier)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}

private struct ApplicationLabel: View {
    let application: ApplicationIdentity

    var body: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: application.applicationURL.path))
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(application.displayName)
                Text(application.bundleIdentifier)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AssociationPreviewEntryView: View {
    let entry: FileAssociationPlanEntry
    let targetAdvertisesSupport: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.requestedExtensions.map(\.displayValue).joined(separator: ", "))
                    .font(.body.monospaced().weight(.semibold))
                Spacer()
                Text(entry.contentType.identifier)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text(entry.previousHandler?.displayName ?? "No current app")
                    .foregroundStyle(.secondary)
                Image(systemName: entry.requiresChange ? "arrow.right" : "equal")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(entry.targetHandler.displayName)
                    .fontWeight(.medium)
            }

            if !collateralExtensions.isEmpty {
                Label(
                    "Also affects \(collateralExtensions.map(\.displayValue).joined(separator: ", ")) because macOS groups them as one content type.",
                    systemImage: "link"
                )
                .font(.caption)
                .foregroundStyle(ArcaneTokens.information)
            }

            if entry.contentType.isDynamic {
                Label(
                    "This is an undeclared dynamic type. Installed apps may not accept it, and there may be no previous app to restore.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(ArcaneTokens.warning)
            } else if !targetAdvertisesSupport {
                Label(
                    "\(entry.targetHandler.displayName) does not advertise support for this content type.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(ArcaneTokens.warning)
            }

            if entry.previousHandler == nil {
                Label(
                    "No previous app was reported, so this item cannot be restored automatically.",
                    systemImage: "arrow.uturn.backward.circle.badge.exclamationmark"
                )
                .font(.caption)
                .foregroundStyle(ArcaneTokens.warning)
            }
        }
    }

    private var collateralExtensions: [FileExtension] {
        let requested: Set<FileExtension> = Set(entry.requestedExtensions)
        return entry.contentType.filenameExtensions.filter { !requested.contains($0) }
    }
}

private struct AssociationHistoryCard: View {
    let transaction: StoredAssociationTransaction
    let isWorking: Bool
    let restoreEntry: (StoredAssociationEntry) -> Void
    let restoreAll: () -> Void
    let forget: () -> Void

    var body: some View {
        ArcaneCard {
            VStack(alignment: .leading, spacing: ArcaneTokens.controlSpacing) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(transaction.targetApplication?.displayName ?? "Unknown application")
                            .font(.headline)
                        Text(transaction.plan.createdAt, format: .dateTime.month().day().year().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ArcaneStatusBadge(
                        text: transaction.state.displayName,
                        tone: transaction.state.badgeTone
                    )
                }

                ForEach(transaction.entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.planEntry.requestedExtensions.map(\.displayValue).joined(separator: ", "))
                                    .font(.body.monospaced().weight(.medium))
                                Text(entry.planEntry.contentType.identifier)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(entry.outcomeDescription)
                                    .font(.caption)
                                    .foregroundStyle(entry.outcomeColor)
                                if let restorationDetail: String = entry.restorationDetail {
                                    Text(restorationDetail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if entry.canRestore {
                                Button("Restore Previous App") {
                                    restoreEntry(entry)
                                }
                                .disabled(isWorking)
                            }
                        }
                    }

                    if entry.id != transaction.entries.last?.id {
                        Divider()
                    }
                }

                HStack {
                    if transaction.entries.contains(where: \.canRestore) {
                        Button("Restore All Previous Apps") {
                            restoreAll()
                        }
                        .disabled(isWorking)
                    }
                    Spacer()
                    Button("Forget from FinderFix", role: .destructive) {
                        forget()
                    }
                    .disabled(isWorking)
                }
            }
        }
    }
}

private struct AssociationNoticeView: View {
    let notice: FileAssociationNotice

    var body: some View {
        Label(notice.message, systemImage: notice.tone.symbolName)
            .font(.callout)
            .foregroundStyle(notice.tone.color)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                notice.tone.color.opacity(0.10),
                in: RoundedRectangle(cornerRadius: ArcaneTokens.controlRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: ArcaneTokens.controlRadius)
                    .strokeBorder(notice.tone.color.opacity(0.28), lineWidth: 1)
            }
    }
}

private extension FileAssociationNotice.Tone {
    var color: Color {
        switch self {
        case .information: return ArcaneTokens.information
        case .success: return ArcaneTokens.positive
        case .warning: return ArcaneTokens.warning
        case .error: return ArcaneTokens.destructive
        }
    }

    var symbolName: String {
        switch self {
        case .information: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

private extension StoredAssociationTransactionState {
    var displayName: String {
        switch self {
        case .applying: return "Applying"
        case .applied: return "Applied"
        case .failed: return "Failed"
        case .rolledBackAfterFailure: return "Rolled Back"
        case .rollbackIncomplete: return "Needs Review"
        case .restored: return "Restored"
        }
    }

    var badgeTone: ArcaneStatusBadge.Tone {
        switch self {
        case .applied, .restored, .rolledBackAfterFailure: return .positive
        case .applying: return .information
        case .failed, .rollbackIncomplete: return .warning
        }
    }
}

private extension StoredAssociationEntry {
    var requestedExtensionSummary: String {
        planEntry.requestedExtensions.map(\.displayValue).joined(separator: ", ")
    }

    var canRestore: Bool {
        applyOutcome.changedSystemState
            && planEntry.previousHandler != nil
            && restorationState != .restored
    }

    var outcomeDescription: String {
        if let restorationState {
            switch restorationState {
            case .pending: return "Checking whether the previous app was restored"
            case .restored: return "Previous app restored"
            case .skippedNotApplied: return "No FinderFix change to restore"
            case .skippedNoPreviousHandler: return "No previous app available"
            case .skippedCurrentStateUnavailable: return "Current app could not be checked"
            case .skippedCurrentHandlerChanged: return "Newer external choice preserved"
            case .failed: return "Restore failed"
            }
        }

        switch applyOutcome {
        case .notStarted: return "Not started"
        case .applied: return "Changed successfully"
        case .unchanged: return "Already configured"
        case .cancelled: return "Cancelled"
        case .failed(let failure): return failure.message
        }
    }

    var outcomeColor: Color {
        if let restorationState {
            switch restorationState {
            case .pending:
                return ArcaneTokens.information
            case .restored, .skippedNotApplied:
                return ArcaneTokens.positive
            case .skippedNoPreviousHandler,
                 .skippedCurrentStateUnavailable,
                 .skippedCurrentHandlerChanged:
                return ArcaneTokens.warning
            case .failed:
                return ArcaneTokens.destructive
            }
        }
        switch applyOutcome {
        case .applied, .unchanged:
            return ArcaneTokens.positive
        case .notStarted, .cancelled:
            return Color.secondary
        case .failed:
            return ArcaneTokens.destructive
        }
    }
}

private extension StoredAssociationTransaction {
    var restoreAllConfirmationMessage: String {
        let entriesToRestore: [StoredAssociationEntry] = entries.filter(\.canRestore)
        let mappings: String = entriesToRestore.map { entry in
            let contentType: FileContentType = entry.planEntry.contentType
            let previousApplicationName: String = entry.planEntry.previousHandler?.displayName
                ?? "the captured previous application"
            return "\(contentType.associationDisplayName) (\(contentType.identifier)) → \(previousApplicationName)"
        }
        .joined(separator: "; ")

        return "FinderFix will restore captured defaults for these macOS content types: \(mappings). Each change applies to the full content type and all filename extensions mapped to it. Any type changed outside FinderFix since this history entry was created will be left alone."
    }
}

private extension FileContentType {
    var registeredExtensionClause: String {
        guard !filenameExtensions.isEmpty else {
            return ", which has no registered filename extensions"
        }
        let extensionList: String = filenameExtensions.map(\.displayValue).joined(separator: ", ")
        return ", including its registered extensions: \(extensionList)"
    }
}
