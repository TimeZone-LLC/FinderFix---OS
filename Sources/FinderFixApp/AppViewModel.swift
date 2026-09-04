import AppKit
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    enum ActivityState: Equatable {
        case ready
        case working(String)
        case success(String)
        case warning(String)
        case failure(String)
    }

    @Published private(set) var accessibilityTrusted: Bool = false
    @Published private(set) var windowFocusRuntimeState: WindowFocusRuntimeState = .disabled
    @Published private(set) var activity: ActivityState = .ready
    @Published private(set) var isApplyingRules: Bool = false
    @Published private(set) var isCleaningDSStoreFiles: Bool = false

    private let cleaner: DSStoreCleaner
    private var accessibilityStatusHandler: () -> Bool
    private var accessibilityRequestHandler: () -> Void
    private var applyRulesHandler: () async -> ActivityState
    private var openFinderHandler: () -> Void
    private var dsStoreFolderPathsProvider: () -> [String]
    private var dsStoreFolderPathsUpdateHandler: ([String]) -> Void
    private var applyRulesTask: Task<Void, Never>?
    private var dsStoreCleanupTask: Task<Void, Never>?

    init(cleaner: DSStoreCleaner = DSStoreCleaner()) {
        self.cleaner = cleaner
        self.accessibilityStatusHandler = { false }
        self.accessibilityRequestHandler = {}
        self.applyRulesHandler = { .warning("Finder rules are not ready yet.") }
        self.openFinderHandler = {}
        self.dsStoreFolderPathsProvider = { [] }
        self.dsStoreFolderPathsUpdateHandler = { _ in }
    }

    func configure(
        accessibilityStatus: @escaping () -> Bool,
        requestAccessibility: @escaping () -> Void,
        applyRules: @escaping () async -> ActivityState,
        openFinder: @escaping () -> Void
    ) {
        accessibilityStatusHandler = accessibilityStatus
        accessibilityRequestHandler = requestAccessibility
        applyRulesHandler = applyRules
        openFinderHandler = openFinder
        refreshAccessibilityStatus()
    }

    func configureDSStoreMaintenance(
        folderPaths: @escaping () -> [String],
        updateFolderPaths: @escaping ([String]) -> Void
    ) {
        dsStoreFolderPathsProvider = folderPaths
        dsStoreFolderPathsUpdateHandler = updateFolderPaths
    }

    func refreshAccessibilityStatus() {
        accessibilityTrusted = accessibilityStatusHandler()
    }

    func setAccessibilityTrusted(_ trusted: Bool) {
        guard accessibilityTrusted != trusted else { return }
        accessibilityTrusted = trusted
    }

    func setWindowFocusRuntimeState(_ state: WindowFocusRuntimeState) {
        windowFocusRuntimeState = state
    }

    func reportFailure(_ message: String) {
        activity = .failure(message)
    }

    func reportWarning(_ message: String) {
        activity = .warning(message)
    }

    func reportSuccess(_ message: String) {
        activity = .success(message)
    }

    func requestAccessibility() {
        accessibilityRequestHandler()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.refreshAccessibilityStatus()
        }
    }

    func applyRulesNow() {
        guard applyRulesTask == nil else { return }
        isApplyingRules = true
        activity = .working("Applying Finder rules…")
        applyRulesTask = Task { [weak self] in
            guard let self else { return }
            let result: ActivityState = await applyRulesHandler()
            guard !Task.isCancelled else {
                isApplyingRules = false
                applyRulesTask = nil
                return
            }
            activity = result
            isApplyingRules = false
            applyRulesTask = nil
        }
    }

    func openFinder() {
        openFinderHandler()
    }

    func chooseFolderAndCleanDSStoreFiles() {
        guard dsStoreCleanupTask == nil else { return }
        let panel: NSOpenPanel = NSOpenPanel()
        panel.title = "Choose a Folder to Scan"
        panel.prompt = "Scan Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let folder: URL = panel.url else { return }
        startDSStoreCleanup(
            roots: [folder],
            confirmationDetail: "Only .DS_Store files inside \(folder.path) will be moved. Other files are not changed."
        )
    }

    func addDSStoreCleanupFolders() {
        let panel: NSOpenPanel = NSOpenPanel()
        panel.title = "Choose Folders for Automatic Cleanup"
        panel.prompt = "Add Folders"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true

        guard panel.runModal() == .OK else { return }
        let existingPaths: [String] = dsStoreFolderPathsProvider()
        let allowedURLs: [URL] = panel.urls.filter { url in
            DSStoreMaintenanceService.selectedRootIsAllowed(url)
        }
        let selectedPaths: [String] = allowedURLs.map { url in
            url.standardizedFileURL.resolvingSymlinksInPath().path
        }
        let normalizedPaths: [String] = Array(Set(existingPaths + selectedPaths)).sorted()
        dsStoreFolderPathsUpdateHandler(normalizedPaths)
        if allowedURLs.count != panel.urls.count {
            activity = .warning(
                "Use Home + Applications scope for broad locations. The filesystem root and Trash cannot be watched."
            )
        }
    }

    func removeDSStoreCleanupFolder(path: String) {
        let updatedPaths: [String] = dsStoreFolderPathsProvider().filter { existingPath in
            existingPath != path
        }
        dsStoreFolderPathsUpdateHandler(updatedPaths)
    }

    func cleanDSStoreFilesNow(scope: DSStoreCleanupScope) {
        guard dsStoreCleanupTask == nil else { return }
        let roots: [URL] = DSStoreMaintenanceService.roots(
            for: scope,
            selectedFolderPaths: dsStoreFolderPathsProvider()
        )
        guard !roots.isEmpty else {
            activity = .warning("Choose at least one folder to clean.")
            return
        }
        startDSStoreCleanup(
            roots: roots,
            confirmationDetail: Self.dsStoreConfirmationDetail(scope: scope, roots: roots)
        )
    }

    func cancelDSStoreCleanup() {
        guard dsStoreCleanupTask != nil else { return }
        dsStoreCleanupTask?.cancel()
        activity = .working("Stopping .DS_Store cleanup…")
    }

    func clearActivity() {
        activity = .ready
    }

    private func finishDSStoreCleanup() {
        isCleaningDSStoreFiles = false
        dsStoreCleanupTask = nil
    }

    private func startDSStoreCleanup(
        roots: [URL],
        confirmationDetail: String
    ) {
        isCleaningDSStoreFiles = true
        activity = .working("Scanning for .DS_Store files…")
        dsStoreCleanupTask = Task { [weak self] in
            guard let self else { return }
            do {
                let scans: [DSStoreScan] = try await cleaner.scan(folders: roots)
                let filePaths: Set<String> = Set(
                    scans.flatMap { scan in scan.files.map(\.path) }
                )
                guard !filePaths.isEmpty else {
                    activity = .success("No .DS_Store files found in the selected scope.")
                    finishDSStoreCleanup()
                    return
                }

                let alert: NSAlert = NSAlert()
                alert.messageText = "Move \(filePaths.count) .DS_Store files to the Trash?"
                alert.informativeText = confirmationDetail
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Move to Trash")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else {
                    activity = .ready
                    finishDSStoreCleanup()
                    return
                }

                activity = .working("Moving .DS_Store files to the Trash…")
                let movedCount: Int = try await cleaner.moveToTrash(scans: scans)
                activity = .success("Moved \(movedCount) .DS_Store files to the Trash.")
            } catch let error as DSStoreCleaner.CleanerError {
                switch error {
                case let .cancelled(moved):
                    activity = moved == 0
                        ? .ready
                        : .warning("Stopped after moving \(moved) .DS_Store files to the Trash.")
                default:
                    activity = .failure(error.localizedDescription)
                }
            } catch is CancellationError {
                activity = .ready
            } catch {
                activity = .failure(error.localizedDescription)
            }
            finishDSStoreCleanup()
        }
    }

    private static func dsStoreConfirmationDetail(
        scope: DSStoreCleanupScope,
        roots: [URL]
    ) -> String {
        switch scope {
        case .selectedFolders:
            let locations: String = roots.map(\.path).joined(separator: "\n")
            return "Only .DS_Store files inside these folders will be moved:\n\n\(locations)\n\nOther files are not changed."
        case .systemWide:
            return "Only .DS_Store files in your Home folder and /Applications will be moved. Package contents, symbolic links, inaccessible items, and all other files are skipped."
        }
    }
}
