import CoreServices
import Foundation
import XCTest
@testable import FinderFixApp

@MainActor
final class DSStoreMaintenanceServiceTests: XCTestCase {
    func testFileEventIsForwardedOnlyWithinConfiguredRoot() async throws {
        let root: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderFixMonitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder: DSStoreEventRecorder = DSStoreEventRecorder()
        let service: DSStoreMaintenanceService = DSStoreMaintenanceService {
            files,
            roots in
            await recorder.record(files: files, roots: roots)
            return DSStoreAutomaticCleanupResult(moved: 0, failed: 0)
        }
        service.update(
            configuration: DSStoreMaintenanceConfiguration(
                isEnabled: true,
                roots: [root]
            )
        )
        defer { service.stop() }

        let metadataFile: URL = root.appendingPathComponent(".DS_Store")
        try Self.touchFromAnotherProcess(metadataFile)

        var snapshot: DSStoreEventRecorder.Snapshot = await recorder.snapshot()
        for _ in 0..<40 where snapshot.files.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
            snapshot = await recorder.snapshot()
        }

        XCTAssertTrue(
            snapshot.files.contains(
                metadataFile.standardizedFileURL.resolvingSymlinksInPath()
            )
        )
        XCTAssertEqual(snapshot.roots, [root.standardizedFileURL.resolvingSymlinksInPath()])
    }

    func testSelectedFolderRootsAreNormalizedAndDeduplicated() {
        let temporaryRoot: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderFixRoot", isDirectory: true)
        let paths: [String] = [
            temporaryRoot.path,
            temporaryRoot.appendingPathComponent("..", isDirectory: true)
                .appendingPathComponent(temporaryRoot.lastPathComponent, isDirectory: true)
                .path,
            temporaryRoot.appendingPathComponent("Nested", isDirectory: true).path,
        ]

        let roots: [URL] = DSStoreMaintenanceService.roots(
            for: .selectedFolders,
            selectedFolderPaths: paths
        )

        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(
            roots.first?.path,
            temporaryRoot.standardizedFileURL.resolvingSymlinksInPath().path
        )
    }

    func testSystemWideScopeIsLimitedToHomeAndApplications() {
        let roots: [URL] = DSStoreMaintenanceService.roots(
            for: .systemWide,
            selectedFolderPaths: ["/tmp/ignored"]
        )

        XCTAssertEqual(
            Set(roots.map(\.path)),
            Set([
                FileManager.default.homeDirectoryForCurrentUser
                    .standardizedFileURL.resolvingSymlinksInPath().path,
                URL(fileURLWithPath: "/Applications", isDirectory: true)
                    .standardizedFileURL.resolvingSymlinksInPath().path,
            ])
        )
    }

    func testAutomaticCleanupDefaultsOff() {
        let preferences: FinderFixPreferences = FinderFixPreferences()

        XCTAssertFalse(preferences.automaticDSStoreCleanupEnabled)
        XCTAssertEqual(preferences.dsStoreCleanupScope, .selectedFolders)
        XCTAssertTrue(preferences.dsStoreCleanupFolderPaths.isEmpty)
    }

    func testSelectedAutomaticCleanupCannotNormalizeWithoutFolders() {
        var preferences: FinderFixPreferences = FinderFixPreferences()
        preferences.automaticDSStoreCleanupEnabled = true
        preferences.dsStoreCleanupScope = .selectedFolders
        preferences.dsStoreCleanupFolderPaths = []

        XCTAssertFalse(preferences.normalized().automaticDSStoreCleanupEnabled)
    }

    func testSelectedScopeRejectsBroadAndTrashRoots() {
        let home: URL = FileManager.default.homeDirectoryForCurrentUser

        XCTAssertFalse(
            DSStoreMaintenanceService.selectedRootIsAllowed(
                URL(fileURLWithPath: "/", isDirectory: true)
            )
        )
        XCTAssertFalse(DSStoreMaintenanceService.selectedRootIsAllowed(home))
        XCTAssertFalse(
            DSStoreMaintenanceService.selectedRootIsAllowed(
                URL(fileURLWithPath: "/Applications", isDirectory: true)
            )
        )
        XCTAssertFalse(
            DSStoreMaintenanceService.selectedRootIsAllowed(
                home.appendingPathComponent(".Trash", isDirectory: true)
            )
        )
        XCTAssertTrue(
            DSStoreMaintenanceService.selectedRootIsAllowed(
                home.appendingPathComponent("Desktop", isDirectory: true)
            )
        )
    }

    func testEventClassifierFiltersNoiseAndPreservesRecoveryFlags() throws {
        let metadataPath: String = "/tmp/Folder/.DS_Store"
        let droppedPath: String = "/tmp/Folder"
        let rootPath: String = "/tmp/Folder"
        let batch: DSStoreFileSystemEventBatch = try XCTUnwrap(
            DSStoreEventClassifier.classify(
                paths: [metadataPath, "/tmp/Folder/note.txt", droppedPath, rootPath],
                flags: [
                    FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated),
                    FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified),
                    FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped),
                    FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged),
                ]
            )
        )

        XCTAssertEqual(batch.metadataPaths, [metadataPath])
        XCTAssertTrue(batch.requiresRescan)
        XCTAssertTrue(batch.rootChanged)
    }

    func testOldGenerationCannotClearANewerCleanupTask() async throws {
        let container: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderFixGeneration-\(UUID().uuidString)", isDirectory: true)
        let firstRoot: URL = container.appendingPathComponent("First", isDirectory: true)
        let secondRoot: URL = container.appendingPathComponent("Second", isDirectory: true)
        let nestedRoot: URL = secondRoot.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nestedRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }

        let recorder: BlockingDSStoreCleanupRecorder = BlockingDSStoreCleanupRecorder()
        let service: DSStoreMaintenanceService = DSStoreMaintenanceService {
            files,
            roots in
            await recorder.handle(files: files, roots: roots)
        }
        service.update(
            configuration: .init(isEnabled: true, roots: [firstRoot])
        )
        try Self.touchFromAnotherProcess(firstRoot.appendingPathComponent(".DS_Store"))
        try await Self.waitForInvocationCount(1, recorder: recorder)

        service.update(
            configuration: .init(isEnabled: true, roots: [secondRoot])
        )
        try Self.touchFromAnotherProcess(secondRoot.appendingPathComponent(".DS_Store"))
        try await Self.waitForInvocationCount(2, recorder: recorder)

        await recorder.release(call: 1)
        try Self.touchFromAnotherProcess(nestedRoot.appendingPathComponent(".DS_Store"))
        try await Task.sleep(for: .milliseconds(700))
        let countWhileSecondCallIsPending: Int = await recorder.invocationCount()
        XCTAssertEqual(countWhileSecondCallIsPending, 2)

        await recorder.release(call: 2)
        try await Self.waitForInvocationCount(3, recorder: recorder)
        service.stop()
    }

    private static func touchFromAnotherProcess(_ file: URL) throws {
        let process: Process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
        process.arguments = [file.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private static func waitForInvocationCount(
        _ expectedCount: Int,
        recorder: BlockingDSStoreCleanupRecorder
    ) async throws {
        for _ in 0..<40 {
            if await recorder.invocationCount() >= expectedCount {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Timed out waiting for \(expectedCount) automatic cleanup calls.")
    }
}

private actor DSStoreEventRecorder {
    struct Snapshot: Sendable {
        let files: [URL]
        let roots: [URL]
    }

    private var files: [URL] = []
    private var roots: [URL] = []

    func record(files: [URL], roots: [URL]) {
        self.files.append(contentsOf: files.map { file in
            file.standardizedFileURL.resolvingSymlinksInPath()
        })
        self.roots = roots
    }

    func snapshot() -> Snapshot {
        Snapshot(files: files, roots: roots)
    }
}

private actor BlockingDSStoreCleanupRecorder {
    private var calls: Int = 0
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

    func handle(
        files: [URL],
        roots: [URL]
    ) async -> DSStoreAutomaticCleanupResult {
        _ = files
        _ = roots
        calls += 1
        let call: Int = calls
        if call <= 2 {
            await withCheckedContinuation { continuation in
                continuations[call] = continuation
            }
        }
        return DSStoreAutomaticCleanupResult(moved: 0, failed: 0)
    }

    func invocationCount() -> Int {
        calls
    }

    func release(call: Int) {
        continuations.removeValue(forKey: call)?.resume()
    }
}
