import AppKit
import FinderFixCore
import Foundation
import UniformTypeIdentifiers

struct FileExtensionResolution: Identifiable, Hashable, Sendable {
    let requestedExtension: FileExtension
    let candidates: [FileContentType]

    var id: FileExtension { requestedExtension }
}

enum FileAssociationServiceError: LocalizedError, Equatable, Sendable {
    case invalidContentType(identifier: String)
    case noContentTypes(fileExtension: FileExtension)
    case notApplication(url: URL)
    case applicationHasNoBundleIdentifier(url: URL)
    case verificationFailed(contentTypeIdentifier: String, expectedBundleIdentifier: String, actualBundleIdentifier: String?)

    var errorDescription: String? {
        switch self {
        case .invalidContentType(let identifier):
            return "The content type \(identifier) is no longer registered on this Mac."
        case .noContentTypes(let fileExtension):
            return "macOS could not resolve \(fileExtension.displayValue) to a content type."
        case .notApplication(let url):
            return "\(url.lastPathComponent) is not a macOS application."
        case .applicationHasNoBundleIdentifier(let url):
            return "\(url.lastPathComponent) does not have a bundle identifier."
        case .verificationFailed(let contentTypeIdentifier, let expectedBundleIdentifier, let actualBundleIdentifier):
            let actualDescription: String = actualBundleIdentifier ?? "no application"
            return "macOS reported \(actualDescription) instead of \(expectedBundleIdentifier) for \(contentTypeIdentifier)."
        }
    }
}

protocol FileContentTypeResolving: Sendable {
    func resolve(_ fileExtensions: [FileExtension]) throws -> [FileExtensionResolution]
}

struct UniformFileContentTypeResolver: FileContentTypeResolving {
    func resolve(_ fileExtensions: [FileExtension]) throws -> [FileExtensionResolution] {
        try fileExtensions.map { fileExtension in
            let types: [UTType] = UTType.types(
                tag: fileExtension.rawValue,
                tagClass: .filenameExtension,
                conformingTo: .data
            )

            guard !types.isEmpty else {
                throw FileAssociationServiceError.noContentTypes(fileExtension: fileExtension)
            }

            let candidates: [FileContentType] = types
                .map(Self.contentType(from:))
                .uniqued(on: \.identifier)
                .sorted { lhs, rhs in
                    if lhs.isDynamic != rhs.isDynamic {
                        return !lhs.isDynamic
                    }
                    return lhs.identifier.localizedStandardCompare(rhs.identifier) == .orderedAscending
                }

            return FileExtensionResolution(
                requestedExtension: fileExtension,
                candidates: candidates
            )
        }
    }

    private static func contentType(from type: UTType) -> FileContentType {
        let extensions: [FileExtension] = (type.tags[.filenameExtension] ?? [])
            .compactMap(FileExtension.init(rawValue:))
            .uniqued(on: \.rawValue)
            .sorted()

        return FileContentType(
            identifier: type.identifier,
            isDeclared: type.isDeclared,
            isDynamic: type.isDynamic,
            filenameExtensions: extensions
        )
    }
}

@MainActor
protocol WorkspaceAssociationServicing: AnyObject, Sendable {
    func currentState(for contentType: FileContentType) throws -> FileAssociationCurrentState
    func compatibleApplications(for contentType: FileContentType) throws -> [ApplicationIdentity]
    func application(at url: URL) throws -> ApplicationIdentity
    func setDefaultApplication(_ application: ApplicationIdentity, for contentType: FileContentType) async throws
}

@MainActor
final class NSWorkspaceAssociationService: WorkspaceAssociationServicing {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func currentState(for contentType: FileContentType) throws -> FileAssociationCurrentState {
        let type: UTType = try resolvedType(for: contentType)
        let handlerURL: URL? = workspace.urlForApplication(toOpen: type)
        let handler: ApplicationIdentity?
        if let handlerURL {
            handler = try application(at: handlerURL)
        } else {
            handler = nil
        }
        return FileAssociationCurrentState(
            contentTypeIdentifier: contentType.identifier,
            handler: handler
        )
    }

    func compatibleApplications(for contentType: FileContentType) throws -> [ApplicationIdentity] {
        let type: UTType = try resolvedType(for: contentType)
        return workspace.urlsForApplications(toOpen: type)
            .compactMap { try? application(at: $0) }
            .uniqued(on: \.stableIdentifier)
    }

    func application(at url: URL) throws -> ApplicationIdentity {
        let standardizedURL: URL = url.resolvingSymlinksInPath().standardizedFileURL
        let values: URLResourceValues
        do {
            values = try standardizedURL.resourceValues(forKeys: [.contentTypeKey, .localizedNameKey])
        } catch {
            throw FileAssociationServiceError.notApplication(url: url)
        }

        guard let contentType: UTType = values.contentType,
              contentType.conforms(to: .applicationBundle),
              let bundle: Bundle = Bundle(url: standardizedURL) else {
            throw FileAssociationServiceError.notApplication(url: url)
        }
        guard let bundleIdentifier: String = bundle.bundleIdentifier, !bundleIdentifier.isEmpty else {
            throw FileAssociationServiceError.applicationHasNoBundleIdentifier(url: url)
        }

        let displayName: String = values.localizedName
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? standardizedURL.deletingPathExtension().lastPathComponent

        return ApplicationIdentity(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            applicationURL: standardizedURL
        )
    }

    func setDefaultApplication(_ application: ApplicationIdentity, for contentType: FileContentType) async throws {
        let type: UTType = try resolvedType(for: contentType)
        let availableApplication: ApplicationIdentity
        if FileManager.default.fileExists(atPath: application.applicationURL.path),
           let applicationAtSavedURL: ApplicationIdentity = try? self.application(at: application.applicationURL),
           applicationAtSavedURL.representsSameApplication(as: application) {
            availableApplication = applicationAtSavedURL
        } else if let relocatedURL: URL = workspace.urlForApplication(
            withBundleIdentifier: application.bundleIdentifier
        ) {
            availableApplication = try self.application(at: relocatedURL)
        } else {
            throw FileAssociationServiceError.notApplication(url: application.applicationURL)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            workspace.setDefaultApplication(
                at: availableApplication.applicationURL,
                toOpen: type
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func resolvedType(for contentType: FileContentType) throws -> UTType {
        guard let type: UTType = UTType(contentType.identifier) else {
            throw FileAssociationServiceError.invalidContentType(identifier: contentType.identifier)
        }
        return type
    }
}

extension ApplicationIdentity {
    var stableIdentifier: String {
        "\(bundleIdentifier)|\(applicationURL.resolvingSymlinksInPath().standardizedFileURL.path)"
    }
}

extension FileContentType {
    var associationDisplayName: String {
        UTType(identifier)?.localizedDescription ?? identifier
    }
}

extension Sequence {
    func uniqued<Key: Hashable>(on key: (Element) -> Key) -> [Element] {
        var seen: Set<Key> = []
        return filter { seen.insert(key($0)).inserted }
    }
}
