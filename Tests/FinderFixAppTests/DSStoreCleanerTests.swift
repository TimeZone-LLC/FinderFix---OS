import Foundation
import XCTest
@testable import FinderFixApp

final class DSStoreCleanerTests: XCTestCase {
    func testScanFindsOnlyDSStoreFilesAndSkipsPackageContents() async throws {
        let root: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderFixTests-\(UUID().uuidString)", isDirectory: true)
        let nested: URL = root.appendingPathComponent("Nested", isDirectory: true)
        let package: URL = root.appendingPathComponent("Fixture.app", isDirectory: true)
        let linkedMetadata: URL = nested.appendingPathComponent("Linked", isDirectory: true)
        let trash: URL = root.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linkedMetadata, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data().write(to: root.appendingPathComponent(".DS_Store"))
        try Data().write(to: nested.appendingPathComponent(".DS_Store"))
        try Data().write(to: nested.appendingPathComponent("notes.txt"))
        try Data().write(to: package.appendingPathComponent(".DS_Store"))
        try Data().write(to: trash.appendingPathComponent(".DS_Store"))
        try FileManager.default.createSymbolicLink(
            at: linkedMetadata.appendingPathComponent(".DS_Store"),
            withDestinationURL: nested.appendingPathComponent("notes.txt")
        )

        let cleaner: DSStoreCleaner = DSStoreCleaner()
        let scan: DSStoreScan = try await cleaner.scan(folder: root)

        XCTAssertEqual(scan.root, root)
        XCTAssertEqual(
            scan.files.map { $0.resolvingSymlinksInPath().path },
            [
                root.appendingPathComponent(".DS_Store").resolvingSymlinksInPath().path,
                nested.appendingPathComponent(".DS_Store").resolvingSymlinksInPath().path,
            ].sorted()
        )
    }

    func testScanRejectsARegularFile() async throws {
        let file: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderFixTests-\(UUID().uuidString).txt")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let cleaner: DSStoreCleaner = DSStoreCleaner()

        do {
            _ = try await cleaner.scan(folder: file)
            XCTFail("Expected a regular file to be rejected.")
        } catch let error as DSStoreCleaner.CleanerError {
            guard case .notDirectory = error else {
                XCTFail("Unexpected cleaner error: \(error)")
                return
            }
        }
    }

    func testAutomaticCleanupSkipsSymbolicLinkWithoutTrashingItsTarget() async throws {
        let root: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderFixTests-\(UUID().uuidString)", isDirectory: true)
        let targetFolder: URL = root.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let target: URL = targetFolder.appendingPathComponent(".DS_Store")
        let link: URL = root.appendingPathComponent(".DS_Store")
        try Data([1]).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let cleaner: DSStoreCleaner = DSStoreCleaner()
        let result: DSStoreAutomaticCleanupResult = await cleaner.cleanEventFiles(
            [link],
            permittedRoots: [root]
        )

        XCTAssertEqual(result, DSStoreAutomaticCleanupResult(moved: 0, failed: 0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }
}
