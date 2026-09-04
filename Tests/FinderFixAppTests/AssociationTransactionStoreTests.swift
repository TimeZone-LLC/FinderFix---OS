import FinderFixCore
import Foundation
import XCTest
@testable import FinderFixApp

final class AssociationTransactionStoreTests: XCTestCase {
    func testUpsertSortAndRemoveUseAnIsolatedDefaultsSuite() async throws {
        let suiteName: String = "FinderFixTests.\(UUID().uuidString)"
        let defaults: UserDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store: UserDefaultsAssociationTransactionStore = UserDefaultsAssociationTransactionStore(
            suiteName: suiteName
        )
        let older: StoredAssociationTransaction = try transaction(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        var newer: StoredAssociationTransaction = try transaction(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            createdAt: Date(timeIntervalSince1970: 20)
        )

        try await store.upsert(older)
        try await store.upsert(newer)
        let initiallyStored: [StoredAssociationTransaction] = try await store.transactions()
        XCTAssertEqual(initiallyStored.map(\.id), [newer.id, older.id])

        newer.state = .applied
        newer.completedAt = Date(timeIntervalSince1970: 30)
        try await store.upsert(newer)
        let updatedTransactions: [StoredAssociationTransaction] = try await store.transactions()
        let replaced: StoredAssociationTransaction = try XCTUnwrap(updatedTransactions.first)
        XCTAssertEqual(replaced.state, .applied)
        XCTAssertEqual(replaced.completedAt, newer.completedAt)

        try await store.remove(id: older.id)
        let remainingTransactions: [StoredAssociationTransaction] = try await store.transactions()
        XCTAssertEqual(remainingTransactions.map(\.id), [newer.id])
    }

    func testCorruptHistoryFailsClosed() async throws {
        let suiteName: String = "FinderFixTests.\(UUID().uuidString)"
        let storageKey: String = "corrupt-history"
        let defaults: UserDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not-json".utf8), forKey: storageKey)
        let store: UserDefaultsAssociationTransactionStore = UserDefaultsAssociationTransactionStore(
            suiteName: suiteName,
            storageKey: storageKey
        )

        do {
            _ = try await store.transactions()
            XCTFail("Expected corrupt transaction history to be rejected.")
        } catch let error as AssociationTransactionStoreError {
            guard case .unreadableData = error else {
                XCTFail("Unexpected store error: \(error)")
                return
            }
        }
    }

    private func transaction(id: UUID, createdAt: Date) throws -> StoredAssociationTransaction {
        let fileExtension: FileExtension = try FileExtension(validating: "txt")
        let type: FileContentType = FileContentType(
            identifier: "public.plain-text",
            isDeclared: true,
            isDynamic: false,
            filenameExtensions: [fileExtension]
        )
        let target: ApplicationIdentity = ApplicationIdentity(
            bundleIdentifier: "com.example.Editor",
            displayName: "Editor",
            applicationURL: URL(fileURLWithPath: "/Applications/Editor.app")
        )
        let plan: FileAssociationTransactionPlan = FileAssociationTransactionPlan(
            id: id,
            createdAt: createdAt,
            entries: [
                FileAssociationPlanEntry(
                    contentType: type,
                    requestedExtensions: [fileExtension],
                    previousHandler: nil,
                    targetHandler: target
                ),
            ]
        )
        return StoredAssociationTransaction(plan: plan)
    }
}
