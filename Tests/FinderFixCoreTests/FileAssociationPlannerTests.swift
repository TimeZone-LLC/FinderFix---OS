import Foundation
import XCTest
@testable import FinderFixCore

final class FileAssociationPlannerTests: XCTestCase {
    func testPlanGroupsExtensionsByContentTypeAndPreservesOrder() throws {
        let jpg: FileExtension = try fileExtension("jpg")
        let jpeg: FileExtension = try fileExtension("jpeg")
        let png: FileExtension = try fileExtension("png")
        let jpegTypeA: FileContentType = FileContentType(
            identifier: "public.jpeg",
            isDeclared: true,
            isDynamic: false,
            filenameExtensions: [jpg]
        )
        let jpegTypeB: FileContentType = FileContentType(
            identifier: "public.jpeg",
            isDeclared: true,
            isDynamic: false,
            filenameExtensions: [jpeg, jpg]
        )
        let pngType: FileContentType = FileContentType(
            identifier: "public.png",
            isDeclared: true,
            isDynamic: false,
            filenameExtensions: [png]
        )
        let previous: ApplicationIdentity = application("com.apple.Preview", name: "Preview")
        let target: ApplicationIdentity = application("com.example.ImageApp", name: "Image App")
        let transactionID: UUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let timestamp: Date = Date(timeIntervalSince1970: 100)

        let plan: FileAssociationTransactionPlan = try FileAssociationPlanner.makePlan(
            resolutions: [
                ResolvedFileExtension(requestedExtension: jpg, contentType: jpegTypeA),
                ResolvedFileExtension(requestedExtension: png, contentType: pngType),
                ResolvedFileExtension(requestedExtension: jpeg, contentType: jpegTypeB),
                ResolvedFileExtension(requestedExtension: jpg, contentType: jpegTypeA),
            ],
            targetHandler: target,
            currentStates: [
                FileAssociationCurrentState(contentTypeIdentifier: "public.jpeg", handler: previous),
                FileAssociationCurrentState(contentTypeIdentifier: "public.png", handler: previous),
            ],
            id: transactionID,
            createdAt: timestamp
        )

        XCTAssertEqual(plan.id, transactionID)
        XCTAssertEqual(plan.createdAt, timestamp)
        XCTAssertEqual(plan.entries.map(\.id), ["public.jpeg", "public.png"])
        XCTAssertEqual(plan.entries[0].requestedExtensions, [jpg, jpeg])
        XCTAssertEqual(plan.entries[0].contentType.filenameExtensions, [jpg, jpeg])
        XCTAssertEqual(plan.entries[0].previousHandler, previous)
        XCTAssertEqual(plan.entries[0].targetHandler, target)
    }

    func testPlanRequiresAnExplicitCurrentStateEvenWhenHandlerIsNil() throws {
        let text: FileExtension = try fileExtension("txt")
        let type: FileContentType = contentType("public.plain-text", extensions: [text])
        let resolution: ResolvedFileExtension = ResolvedFileExtension(
            requestedExtension: text,
            contentType: type
        )

        XCTAssertThrowsError(
            try FileAssociationPlanner.makePlan(
                resolutions: [resolution],
                targetHandler: application("com.example.Editor", name: "Editor"),
                currentStates: []
            )
        ) { error in
            XCTAssertEqual(
                error as? FileAssociationPlanError,
                .missingCurrentState(contentTypeIdentifier: "public.plain-text")
            )
        }

        let plan: FileAssociationTransactionPlan = try FileAssociationPlanner.makePlan(
            resolutions: [resolution],
            targetHandler: application("com.example.Editor", name: "Editor"),
            currentStates: [
                FileAssociationCurrentState(contentTypeIdentifier: "public.plain-text", handler: nil),
            ]
        )
        XCTAssertNil(plan.entries[0].previousHandler)
    }

    func testPlanRejectsDuplicateCurrentStates() throws {
        let text: FileExtension = try fileExtension("txt")
        let type: FileContentType = contentType("public.plain-text", extensions: [text])
        let state: FileAssociationCurrentState = FileAssociationCurrentState(
            contentTypeIdentifier: type.identifier,
            handler: nil
        )

        XCTAssertThrowsError(
            try FileAssociationPlanner.makePlan(
                resolutions: [ResolvedFileExtension(requestedExtension: text, contentType: type)],
                targetHandler: application("com.example.Editor", name: "Editor"),
                currentStates: [state, state]
            )
        ) { error in
            XCTAssertEqual(
                error as? FileAssociationPlanError,
                .duplicateCurrentState(contentTypeIdentifier: type.identifier)
            )
        }
    }

    func testRequiresChangeUsesStableBundleIdentifier() throws {
        let type: FileContentType = contentType(
            "public.plain-text",
            extensions: [try fileExtension("txt")]
        )
        let previous: ApplicationIdentity = ApplicationIdentity(
            bundleIdentifier: "com.example.Editor",
            displayName: "Old Name",
            applicationURL: URL(fileURLWithPath: "/Applications/Old Editor.app")
        )
        let target: ApplicationIdentity = ApplicationIdentity(
            bundleIdentifier: "com.example.Editor",
            displayName: "New Name",
            applicationURL: URL(fileURLWithPath: "/Applications/New Editor.app")
        )
        let entry: FileAssociationPlanEntry = FileAssociationPlanEntry(
            contentType: type,
            requestedExtensions: type.filenameExtensions,
            previousHandler: previous,
            targetHandler: target
        )

        XCTAssertFalse(entry.requiresChange)
    }

    func testRollbackRestoresAppliedEntriesInReverseOrder() throws {
        let previousText: ApplicationIdentity = application("com.apple.TextEdit", name: "TextEdit")
        let previousImage: ApplicationIdentity = application("com.apple.Preview", name: "Preview")
        let target: ApplicationIdentity = application("com.example.Target", name: "Target")
        let textEntry: FileAssociationPlanEntry = try entry(
            identifier: "public.plain-text",
            fileExtension: "txt",
            previous: previousText,
            target: target
        )
        let imageEntry: FileAssociationPlanEntry = try entry(
            identifier: "public.png",
            fileExtension: "png",
            previous: previousImage,
            target: target
        )
        let plan: FileAssociationTransactionPlan = FileAssociationTransactionPlan(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 10),
            entries: [textEntry, imageEntry]
        )
        let result: FileAssociationTransactionResult = FileAssociationTransactionResult(
            plan: plan,
            completedAt: Date(timeIntervalSince1970: 20),
            results: [
                FileAssociationEntryResult(contentTypeIdentifier: textEntry.id, outcome: .applied),
                FileAssociationEntryResult(contentTypeIdentifier: imageEntry.id, outcome: .applied),
            ]
        )

        let rollback: FileAssociationRollbackPlan = FileAssociationPlanner.makeRollbackPlan(
            transaction: result,
            currentStates: [
                FileAssociationCurrentState(contentTypeIdentifier: textEntry.id, handler: target),
                FileAssociationCurrentState(contentTypeIdentifier: imageEntry.id, handler: target),
            ],
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            createdAt: Date(timeIntervalSince1970: 30)
        )

        XCTAssertEqual(rollback.sourceTransactionID, plan.id)
        XCTAssertEqual(rollback.steps.map(\.id), [imageEntry.id, textEntry.id])
        XCTAssertEqual(rollback.steps[0].action, .restore(previousImage))
        XCTAssertEqual(rollback.steps[1].action, .restore(previousText))
    }

    func testRollbackSkipsUnsafeOrUnnecessaryChanges() throws {
        let previous: ApplicationIdentity = application("com.apple.TextEdit", name: "TextEdit")
        let target: ApplicationIdentity = application("com.example.Target", name: "Target")
        let external: ApplicationIdentity = application("com.example.External", name: "External")
        let notApplied: FileAssociationPlanEntry = try entry(
            identifier: "public.one",
            fileExtension: "one",
            previous: previous,
            target: target
        )
        let noPrevious: FileAssociationPlanEntry = try entry(
            identifier: "public.two",
            fileExtension: "two",
            previous: nil,
            target: target
        )
        let missingState: FileAssociationPlanEntry = try entry(
            identifier: "public.three",
            fileExtension: "three",
            previous: previous,
            target: target
        )
        let drifted: FileAssociationPlanEntry = try entry(
            identifier: "public.four",
            fileExtension: "four",
            previous: previous,
            target: target
        )
        let plan: FileAssociationTransactionPlan = FileAssociationTransactionPlan(
            entries: [notApplied, noPrevious, missingState, drifted]
        )
        let result: FileAssociationTransactionResult = FileAssociationTransactionResult(
            plan: plan,
            results: [
                FileAssociationEntryResult(contentTypeIdentifier: notApplied.id, outcome: .unchanged),
                FileAssociationEntryResult(contentTypeIdentifier: noPrevious.id, outcome: .applied),
                FileAssociationEntryResult(contentTypeIdentifier: missingState.id, outcome: .applied),
                FileAssociationEntryResult(contentTypeIdentifier: drifted.id, outcome: .applied),
            ]
        )

        let rollback: FileAssociationRollbackPlan = FileAssociationPlanner.makeRollbackPlan(
            transaction: result,
            currentStates: [
                FileAssociationCurrentState(contentTypeIdentifier: noPrevious.id, handler: target),
                FileAssociationCurrentState(contentTypeIdentifier: drifted.id, handler: external),
            ]
        )
        let actionsByID: [String: FileAssociationRollbackAction] = Dictionary(
            uniqueKeysWithValues: rollback.steps.map { ($0.id, $0.action) }
        )

        XCTAssertEqual(actionsByID[notApplied.id], .skip(.notApplied))
        XCTAssertEqual(actionsByID[noPrevious.id], .skip(.noPreviousHandler))
        XCTAssertEqual(actionsByID[missingState.id], .skip(.currentStateUnavailable))
        XCTAssertEqual(
            actionsByID[drifted.id],
            .skip(.currentHandlerChanged(expected: target, actual: external))
        )
    }

    func testTransactionModelsRoundTripThroughCodable() throws {
        let target: ApplicationIdentity = application("com.example.Target", name: "Target")
        let plan: FileAssociationTransactionPlan = FileAssociationTransactionPlan(
            entries: [
                try entry(
                    identifier: "public.plain-text",
                    fileExtension: "txt",
                    previous: application("com.apple.TextEdit", name: "TextEdit"),
                    target: target
                ),
            ]
        )
        let result: FileAssociationTransactionResult = FileAssociationTransactionResult(
            plan: plan,
            results: [
                FileAssociationEntryResult(
                    contentTypeIdentifier: "public.plain-text",
                    outcome: .failed(
                        FileAssociationFailure(
                            kind: .consentDenied,
                            code: "userDenied",
                            message: "The user denied the change."
                        )
                    )
                ),
            ]
        )

        let data: Data = try JSONEncoder().encode(result)
        XCTAssertEqual(try JSONDecoder().decode(FileAssociationTransactionResult.self, from: data), result)
    }

    private func fileExtension(_ value: String) throws -> FileExtension {
        try FileExtension(validating: value)
    }

    private func contentType(
        _ identifier: String,
        extensions: [FileExtension]
    ) -> FileContentType {
        FileContentType(
            identifier: identifier,
            isDeclared: true,
            isDynamic: false,
            filenameExtensions: extensions
        )
    }

    private func application(_ bundleIdentifier: String, name: String) -> ApplicationIdentity {
        ApplicationIdentity(
            bundleIdentifier: bundleIdentifier,
            displayName: name,
            applicationURL: URL(fileURLWithPath: "/Applications/\(name).app")
        )
    }

    private func entry(
        identifier: String,
        fileExtension: String,
        previous: ApplicationIdentity?,
        target: ApplicationIdentity
    ) throws -> FileAssociationPlanEntry {
        let parsedExtension: FileExtension = try self.fileExtension(fileExtension)
        return FileAssociationPlanEntry(
            contentType: contentType(identifier, extensions: [parsedExtension]),
            requestedExtensions: [parsedExtension],
            previousHandler: previous,
            targetHandler: target
        )
    }
}
