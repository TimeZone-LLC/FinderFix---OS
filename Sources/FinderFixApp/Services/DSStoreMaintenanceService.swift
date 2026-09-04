import CoreServices
import Foundation

enum DSStoreCleanupScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case selectedFolders
    case systemWide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .selectedFolders: "Selected Folders"
        case .systemWide: "Home + Applications"
        }
    }
}

struct DSStoreMaintenanceConfiguration: Equatable, Sendable {
    let isEnabled: Bool
    let roots: [URL]
}

struct DSStoreFileSystemEventBatch: Equatable, Sendable {
    let metadataPaths: [String]
    let requiresRescan: Bool
    let rootChanged: Bool
}

enum DSStoreEventClassifier {
    static func classify(
        paths: [String],
        flags: [FSEventStreamEventFlags]
    ) -> DSStoreFileSystemEventBatch? {
        let count: Int = min(paths.count, flags.count)
        var metadataPaths: [String] = []
        var requiresRescan: Bool = false
        var rootChanged: Bool = false

        for index in 0..<count {
            let eventFlags: FSEventStreamEventFlags = flags[index]
            if eventFlags & FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs
            ) != 0
                || eventFlags & FSEventStreamEventFlags(
                    kFSEventStreamEventFlagUserDropped
                ) != 0
                || eventFlags & FSEventStreamEventFlags(
                    kFSEventStreamEventFlagKernelDropped
                ) != 0
                || eventFlags & FSEventStreamEventFlags(
                    kFSEventStreamEventFlagEventIdsWrapped
                ) != 0 {
                requiresRescan = true
            }
            if eventFlags & FSEventStreamEventFlags(
                kFSEventStreamEventFlagRootChanged
            ) != 0 {
                rootChanged = true
            }
            let path: String = paths[index]
            if URL(fileURLWithPath: path).lastPathComponent == ".DS_Store" {
                metadataPaths.append(path)
            }
        }

        guard rootChanged || requiresRescan || !metadataPaths.isEmpty else { return nil }
        return DSStoreFileSystemEventBatch(
            metadataPaths: metadataPaths,
            requiresRescan: requiresRescan,
            rootChanged: rootChanged
        )
    }
}

@MainActor
final class DSStoreMaintenanceService {
    typealias CleanupHandler = @Sendable (
        [URL],
        [URL]
    ) async -> DSStoreAutomaticCleanupResult

    private static let eventLatency: CFTimeInterval = 0.40
    private static let monitorRetryDelay: Duration = .seconds(3)

    private let cleaner: DSStoreCleaner?
    private let cleanupHandler: CleanupHandler
    private var monitor: DSStoreEventMonitor?
    private var configuration: DSStoreMaintenanceConfiguration = .init(
        isEnabled: false,
        roots: []
    )
    private var pendingURLs: Set<URL> = []
    private var pendingRequiresRescan: Bool = false
    private var cleanupTask: Task<Void, Never>?
    private var monitorRetryTask: Task<Void, Never>?
    private var generation: UInt = 0
    private var lastMonitorErrorDescription: String?

    var eventHandler: (@MainActor @Sendable (AppViewModel.ActivityState) -> Void)?

    init(cleaner: DSStoreCleaner = DSStoreCleaner()) {
        self.cleaner = cleaner
        self.cleanupHandler = { files, roots in
            await cleaner.cleanEventFiles(files, permittedRoots: roots)
        }
    }

    init(cleanupHandler: @escaping CleanupHandler) {
        self.cleaner = nil
        self.cleanupHandler = cleanupHandler
    }

    func update(configuration: DSStoreMaintenanceConfiguration) {
        let normalizedConfiguration: DSStoreMaintenanceConfiguration = .init(
            isEnabled: configuration.isEnabled,
            roots: Self.normalizedRoots(configuration.roots)
        )
        let configurationChanged: Bool = normalizedConfiguration != self.configuration
        guard configurationChanged
                || (normalizedConfiguration.isEnabled
                    && !normalizedConfiguration.roots.isEmpty
                    && monitor == nil
                    && monitorRetryTask == nil) else {
            return
        }

        if configurationChanged {
            generation &+= 1
            stopCurrentWork()
            self.configuration = normalizedConfiguration
            lastMonitorErrorDescription = nil
        }
        startMonitorIfNeeded(expectedGeneration: generation)
    }

    func stop() {
        generation &+= 1
        stopCurrentWork()
    }

    nonisolated static func roots(
        for scope: DSStoreCleanupScope,
        selectedFolderPaths: [String]
    ) -> [URL] {
        switch scope {
        case .selectedFolders:
            return normalizedRoots(
                selectedFolderPaths.map { path in
                    URL(fileURLWithPath: path, isDirectory: true)
                }
            )
        case .systemWide:
            return normalizedRoots([
                FileManager.default.homeDirectoryForCurrentUser,
                URL(fileURLWithPath: "/Applications", isDirectory: true),
            ])
        }
    }

    nonisolated static func selectedRootIsAllowed(_ root: URL) -> Bool {
        let candidate: URL = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidateComponents: [String] = candidate.pathComponents
        guard candidate.path != "/",
              !candidateComponents.contains(where: Self.isTrashDirectoryName) else {
            return false
        }

        let broadTargets: [URL] = [
            FileManager.default.homeDirectoryForCurrentUser
                .standardizedFileURL.resolvingSymlinksInPath(),
            URL(fileURLWithPath: "/Applications", isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath(),
        ]
        return !broadTargets.contains { target in
            Self.containsOrEquals(target, in: candidate)
        }
    }

    private func stopCurrentWork() {
        monitor?.stop()
        monitor = nil
        monitorRetryTask?.cancel()
        monitorRetryTask = nil
        cleanupTask?.cancel()
        cleanupTask = nil
        pendingURLs.removeAll()
        pendingRequiresRescan = false
    }

    private func startMonitorIfNeeded(expectedGeneration: UInt) {
        guard expectedGeneration == generation,
              configuration.isEnabled,
              !configuration.roots.isEmpty,
              monitor == nil else {
            return
        }

        do {
            let newMonitor: DSStoreEventMonitor = try DSStoreEventMonitor(
                roots: configuration.roots,
                latency: Self.eventLatency
            ) { [weak self] batch in
                Task { @MainActor [weak self] in
                    self?.receive(batch: batch)
                }
            }
            try newMonitor.start()
            guard expectedGeneration == generation else {
                newMonitor.stop()
                return
            }
            monitor = newMonitor
            monitorRetryTask?.cancel()
            monitorRetryTask = nil
            lastMonitorErrorDescription = nil
        } catch {
            reportMonitorFailureIfNeeded(error.localizedDescription)
            scheduleMonitorRetry(expectedGeneration: expectedGeneration)
        }
    }

    private func scheduleMonitorRetry(expectedGeneration: UInt) {
        guard monitorRetryTask == nil,
              expectedGeneration == generation,
              configuration.isEnabled,
              !configuration.roots.isEmpty else {
            return
        }
        monitorRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.monitorRetryDelay)
            } catch {
                return
            }
            guard let self, expectedGeneration == generation else { return }
            monitorRetryTask = nil
            startMonitorIfNeeded(expectedGeneration: expectedGeneration)
        }
    }

    private func reportMonitorFailureIfNeeded(_ description: String) {
        guard lastMonitorErrorDescription != description else { return }
        lastMonitorErrorDescription = description
        eventHandler?(.failure(description))
    }

    private func receive(batch: DSStoreFileSystemEventBatch) {
        guard configuration.isEnabled else { return }
        if batch.rootChanged {
            eventHandler?(
                .warning(
                    "A watched folder moved or changed. FinderFix is reconnecting its .DS_Store monitor."
                )
            )
            generation &+= 1
            stopCurrentWork()
            startMonitorIfNeeded(expectedGeneration: generation)
            pendingRequiresRescan = true
            scheduleCleanupIfNeeded()
            return
        }

        for path in batch.metadataPaths {
            pendingURLs.insert(URL(fileURLWithPath: path))
        }
        pendingRequiresRescan = pendingRequiresRescan || batch.requiresRescan
        scheduleCleanupIfNeeded()
    }

    private func scheduleCleanupIfNeeded() {
        guard cleanupTask == nil,
              pendingRequiresRescan || !pendingURLs.isEmpty else {
            return
        }

        let taskGeneration: UInt = generation
        cleanupTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard let self, taskGeneration == generation else { return }

            let urls: [URL] = Array(pendingURLs)
            let roots: [URL] = configuration.roots
            let requiresRescan: Bool = pendingRequiresRescan
            pendingURLs.removeAll()
            pendingRequiresRescan = false

            do {
                let result: DSStoreAutomaticCleanupResult
                if requiresRescan, let cleaner {
                    let scans: [DSStoreScan] = try await cleaner.scan(folders: roots)
                    let movedCount: Int = try await cleaner.moveToTrash(scans: scans)
                    result = DSStoreAutomaticCleanupResult(moved: movedCount, failed: 0)
                } else {
                    result = await cleanupHandler(urls, roots)
                }
                guard taskGeneration == generation else { return }
                finishCleanup(result: result, expectedGeneration: taskGeneration)
            } catch let error as DSStoreCleaner.CleanerError {
                guard taskGeneration == generation else { return }
                finishCleanup(
                    failureDescription: error.localizedDescription,
                    expectedGeneration: taskGeneration
                )
            } catch is CancellationError {
                guard taskGeneration == generation else { return }
                finishCleanup(
                    result: .init(moved: 0, failed: 0, wasCancelled: true),
                    expectedGeneration: taskGeneration
                )
            } catch {
                guard taskGeneration == generation else { return }
                finishCleanup(
                    failureDescription: error.localizedDescription,
                    expectedGeneration: taskGeneration
                )
            }
        }
    }

    private func finishCleanup(
        result: DSStoreAutomaticCleanupResult,
        expectedGeneration: UInt
    ) {
        guard expectedGeneration == generation else { return }
        cleanupTask = nil
        if !result.wasCancelled, result.failed > 0 {
            eventHandler?(
                .warning(
                    "Automatically moved \(result.moved) .DS_Store files to the Trash; \(result.failed) could not be moved."
                )
            )
        }
        scheduleCleanupIfNeeded()
    }

    private func finishCleanup(
        failureDescription: String,
        expectedGeneration: UInt
    ) {
        guard expectedGeneration == generation else { return }
        cleanupTask = nil
        eventHandler?(.warning(failureDescription))
        scheduleCleanupIfNeeded()
    }

    nonisolated private static func normalizedRoots(_ roots: [URL]) -> [URL] {
        var seenPaths: Set<String> = []
        var candidates: [URL] = []
        for root in roots {
            let normalizedRoot: URL = root.standardizedFileURL.resolvingSymlinksInPath()
            let path: String = normalizedRoot.path
            guard !path.isEmpty, seenPaths.insert(path).inserted else { continue }
            candidates.append(normalizedRoot)
        }
        candidates.sort { first, second in
            if first.pathComponents.count != second.pathComponents.count {
                return first.pathComponents.count < second.pathComponents.count
            }
            return first.path < second.path
        }

        var rootsWithoutDescendants: [URL] = []
        for candidate in candidates {
            let isAlreadyCovered: Bool = rootsWithoutDescendants.contains { existingRoot in
                containsOrEquals(candidate, in: existingRoot)
            }
            if !isAlreadyCovered {
                rootsWithoutDescendants.append(candidate)
            }
        }
        return rootsWithoutDescendants.sorted { $0.path < $1.path }
    }

    nonisolated private static func containsOrEquals(_ file: URL, in root: URL) -> Bool {
        let fileComponents: [String] = file.pathComponents
        let rootComponents: [String] = root.pathComponents
        return fileComponents.count >= rootComponents.count
            && Array(fileComponents.prefix(rootComponents.count)) == rootComponents
    }

    nonisolated private static func isTrashDirectoryName(_ name: String) -> Bool {
        name == ".Trash" || name == ".Trashes"
    }
}

private enum DSStoreEventMonitorError: LocalizedError {
    case couldNotCreate
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .couldNotCreate:
            "FinderFix could not create the .DS_Store folder monitor."
        case .couldNotStart:
            "FinderFix could not start the .DS_Store folder monitor."
        }
    }
}

private final class DSStoreEventMonitor: @unchecked Sendable {
    private final class CallbackBox: @unchecked Sendable {
        let handler: @Sendable (DSStoreFileSystemEventBatch) -> Void

        init(handler: @escaping @Sendable (DSStoreFileSystemEventBatch) -> Void) {
            self.handler = handler
        }
    }

    private static let callback: FSEventStreamCallback = {
        _, contextInfo, eventCount, eventPaths, eventFlags, _ in
        guard let contextInfo else { return }
        let box: CallbackBox = Unmanaged<CallbackBox>
            .fromOpaque(contextInfo)
            .takeUnretainedValue()
        let paths: NSArray = unsafeBitCast(eventPaths, to: NSArray.self)
        let stringPaths: [String] = paths.compactMap { value in value as? String }
        let count: Int = min(eventCount, stringPaths.count)
        let flags: [FSEventStreamEventFlags] = (0..<count).map { index in
            eventFlags[index]
        }
        guard let batch: DSStoreFileSystemEventBatch = DSStoreEventClassifier.classify(
            paths: Array(stringPaths.prefix(count)),
            flags: flags
        ) else {
            return
        }
        box.handler(batch)
    }

    private static let retainContext: CFAllocatorRetainCallBack = { contextInfo in
        guard let contextInfo else { return nil }
        _ = Unmanaged<CallbackBox>.fromOpaque(contextInfo).retain()
        return contextInfo
    }

    private static let releaseContext: CFAllocatorReleaseCallBack = { contextInfo in
        guard let contextInfo else { return }
        Unmanaged<CallbackBox>.fromOpaque(contextInfo).release()
    }

    private let queue: DispatchQueue
    private let callbackBox: CallbackBox
    private var stream: FSEventStreamRef?
    private var isStarted: Bool = false

    init(
        roots: [URL],
        latency: CFTimeInterval,
        handler: @escaping @Sendable (DSStoreFileSystemEventBatch) -> Void
    ) throws {
        self.queue = DispatchQueue(label: "com.timezonellc.FinderFixOS.dsstore-events")
        self.callbackBox = CallbackBox(handler: handler)

        var context: FSEventStreamContext = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackBox).toOpaque(),
            retain: Self.retainContext,
            release: Self.releaseContext,
            copyDescription: nil
        )
        let paths: CFArray = roots.map(\.path) as CFArray
        let flags: FSEventStreamCreateFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagIgnoreSelf
        )
        guard let newStream: FSEventStreamRef = FSEventStreamCreate(
            nil,
            Self.callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            throw DSStoreEventMonitorError.couldNotCreate
        }
        stream = newStream
    }

    deinit {
        stop()
    }

    func start() throws {
        guard !isStarted, let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            throw DSStoreEventMonitorError.couldNotStart
        }
        isStarted = true
    }

    func stop() {
        guard let stream else { return }
        if isStarted {
            FSEventStreamStop(stream)
        }
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        isStarted = false
    }
}
