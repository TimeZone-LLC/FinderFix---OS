import Darwin
import Foundation

struct DSStoreScan: Sendable {
    let root: URL
    let files: [URL]
}

struct DSStoreAutomaticCleanupResult: Equatable, Sendable {
    let moved: Int
    let failed: Int
    let wasCancelled: Bool

    init(moved: Int, failed: Int, wasCancelled: Bool = false) {
        self.moved = moved
        self.failed = failed
        self.wasCancelled = wasCancelled
    }
}

actor DSStoreCleaner {
    enum CleanerError: LocalizedError {
        case notDirectory
        case cannotEnumerate
        case partialFailure(moved: Int, failed: Int)
        case cancelled(moved: Int)

        var errorDescription: String? {
            switch self {
            case .notDirectory:
                "Choose a folder to scan."
            case .cannotEnumerate:
                "FinderFix could not scan that folder."
            case let .partialFailure(moved, failed):
                "Moved \(moved) files to the Trash; \(failed) could not be moved."
            case let .cancelled(moved):
                moved == 0
                    ? "Cleanup stopped before any files were moved."
                    : "Cleanup stopped after moving \(moved) files to the Trash."
            }
        }
    }

    func scan(folder: URL) throws -> DSStoreScan {
        let values: URLResourceValues = try folder.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw CleanerError.notDirectory }

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isPackageKey,
        ]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        guard let enumerator: FileManager.DirectoryEnumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: options
        ) else {
            throw CleanerError.cannotEnumerate
        }

        var matches: [URL] = []
        while let fileURL: URL = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard let resourceValues: URLResourceValues = try? fileURL.resourceValues(
                forKeys: Set(keys)
            ) else {
                enumerator.skipDescendants()
                continue
            }
            if resourceValues.isSymbolicLink == true || resourceValues.isPackage == true {
                enumerator.skipDescendants()
                continue
            }
            if resourceValues.isDirectory == true,
               Self.isTrashDirectoryName(fileURL.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            if resourceValues.isRegularFile == true, fileURL.lastPathComponent == ".DS_Store" {
                matches.append(fileURL)
            }
        }

        return DSStoreScan(root: folder, files: matches.sorted { $0.path < $1.path })
    }

    func scan(folders: [URL]) throws -> [DSStoreScan] {
        var scans: [DSStoreScan] = []
        for folder in folders {
            try Task.checkCancellation()
            scans.append(try scan(folder: folder))
        }
        return scans
    }

    func moveToTrash(scans: [DSStoreScan]) throws -> Int {
        var movedCount: Int = 0
        var failureCount: Int = 0
        var seenPaths: Set<String> = []

        for scan in scans {
            let normalizedRoot: URL = scan.root.standardizedFileURL.resolvingSymlinksInPath()
            for fileURL in scan.files {
                if Task.isCancelled {
                    throw CleanerError.cancelled(moved: movedCount)
                }
                guard let validatedFile: URL = Self.validatedMetadataFile(
                    fileURL,
                    within: [normalizedRoot]
                ) else {
                    continue
                }
                let path: String = validatedFile.path
                guard seenPaths.insert(path).inserted else { continue }
                do {
                    var resultingURL: NSURL?
                    try FileManager.default.trashItem(
                        at: validatedFile,
                        resultingItemURL: &resultingURL
                    )
                    movedCount += 1
                } catch {
                    failureCount += 1
                }
            }
        }

        if failureCount > 0 {
            throw CleanerError.partialFailure(moved: movedCount, failed: failureCount)
        }
        return movedCount
    }

    func cleanEventFiles(
        _ files: [URL],
        permittedRoots: [URL]
    ) -> DSStoreAutomaticCleanupResult {
        let roots: [URL] = permittedRoots.map { root in
            root.standardizedFileURL.resolvingSymlinksInPath()
        }
        var movedCount: Int = 0
        var failureCount: Int = 0

        for file in Set(files) {
            if Task.isCancelled {
                return DSStoreAutomaticCleanupResult(
                    moved: movedCount,
                    failed: failureCount,
                    wasCancelled: true
                )
            }
            guard let validatedFile: URL = Self.validatedMetadataFile(
                file,
                within: roots
            ) else {
                continue
            }

            do {
                var resultingURL: NSURL?
                try FileManager.default.trashItem(
                    at: validatedFile,
                    resultingItemURL: &resultingURL
                )
                movedCount += 1
            } catch {
                failureCount += 1
            }
        }

        return DSStoreAutomaticCleanupResult(moved: movedCount, failed: failureCount)
    }

    private static func contains(file: URL, in root: URL) -> Bool {
        let fileComponents: [String] = file.pathComponents
        let rootComponents: [String] = root.pathComponents
        guard fileComponents.count > rootComponents.count else { return false }
        return Array(fileComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static func validatedMetadataFile(
        _ file: URL,
        within roots: [URL]
    ) -> URL? {
        let lexicalFile: URL = file.standardizedFileURL
        guard lexicalFile.lastPathComponent == ".DS_Store",
              !lexicalFile.pathComponents.contains(where: isTrashDirectoryName) else {
            return nil
        }

        let resolvedParent: URL = lexicalFile.deletingLastPathComponent()
            .resolvingSymlinksInPath()
        let resolvedEntry: URL = resolvedParent.appendingPathComponent(".DS_Store")
        var fileStatus: stat = stat()
        guard lstat(resolvedEntry.path, &fileStatus) == 0,
              (fileStatus.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }

        guard let root: URL = roots
            .filter({ contains(file: resolvedEntry, in: $0) })
            .max(by: { $0.pathComponents.count < $1.pathComponents.count }) else {
            return nil
        }
        var ancestor: URL = resolvedParent
        while ancestor.pathComponents.count > root.pathComponents.count {
            if isTrashDirectoryName(ancestor.lastPathComponent) {
                return nil
            }
            if let ancestorValues: URLResourceValues = try? ancestor.resourceValues(
                forKeys: [.isPackageKey]
            ), ancestorValues.isPackage == true {
                return nil
            }
            let parent: URL = ancestor.deletingLastPathComponent()
            guard parent != ancestor else { return nil }
            ancestor = parent
        }
        return resolvedEntry
    }

    private static func isTrashDirectoryName(_ name: String) -> Bool {
        name == ".Trash" || name == ".Trashes"
    }
}
