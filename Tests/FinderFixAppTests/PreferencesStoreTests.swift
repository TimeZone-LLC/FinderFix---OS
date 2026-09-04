import Foundation
import XCTest
@testable import FinderFixApp

@MainActor
final class PreferencesStoreTests: XCTestCase {
    func testDefaultsAndPersistenceUseOnlyTheVersionedSchema() throws {
        let suiteName: String = "FinderFixTests.\(UUID().uuidString)"
        let defaults: UserDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store: PreferencesStore = PreferencesStore(defaults: defaults)
        XCTAssertEqual(store.preferences, FinderFixPreferences())

        store.preferences.windowWidth = 1_280
        store.preferences.moveEligibleFinderDialogs = false

        let persistedData: Data = try XCTUnwrap(defaults.data(forKey: "FinderFix.preferences.v3"))
        let persisted: FinderFixPreferences = try JSONDecoder().decode(
            FinderFixPreferences.self,
            from: persistedData
        )
        XCTAssertEqual(persisted.windowWidth, 1_280)
        XCTAssertFalse(persisted.moveEligibleFinderDialogs)
    }

    func testPriorVersionKeyIsIgnoredWithoutMigration() throws {
        let suiteName: String = "FinderFixTests.\(UUID().uuidString)"
        let defaults: UserDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var priorPreferences: FinderFixPreferences = FinderFixPreferences()
        priorPreferences.windowWidth = 2_000
        priorPreferences.windowFocus.isEnabled = true
        priorPreferences.schemaVersion = 2
        defaults.set(try JSONEncoder().encode(priorPreferences), forKey: "FinderFix.preferences.v2")

        let store: PreferencesStore = PreferencesStore(defaults: defaults)

        XCTAssertEqual(store.preferences, FinderFixPreferences())
        XCTAssertNil(defaults.data(forKey: "FinderFix.preferences.v3"))
    }

    func testUnknownCurrentSchemaFallsBackWithoutMigration() throws {
        let suiteName: String = "FinderFixTests.\(UUID().uuidString)"
        let defaults: UserDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var incompatible: FinderFixPreferences = FinderFixPreferences()
        incompatible.schemaVersion = FinderFixPreferences.currentVersion + 1
        defaults.set(try JSONEncoder().encode(incompatible), forKey: "FinderFix.preferences.v3")

        let store: PreferencesStore = PreferencesStore(defaults: defaults)

        XCTAssertEqual(store.preferences, FinderFixPreferences())
    }

    func testDecodedNumericValuesAreNormalized() throws {
        let suiteName: String = "FinderFixTests.\(UUID().uuidString)"
        let defaults: UserDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var unsafe: FinderFixPreferences = FinderFixPreferences()
        unsafe.windowWidth = 1e300
        unsafe.finderChrome.sidebarWidth = -1e300
        defaults.set(try JSONEncoder().encode(unsafe), forKey: "FinderFix.preferences.v3")

        let store: PreferencesStore = PreferencesStore(defaults: defaults)

        XCTAssertEqual(store.preferences.windowWidth, 10_000)
        XCTAssertEqual(store.preferences.finderChrome.sidebarWidth, 120)
    }

    func testDecodedWindowFocusDelayIsClampedAtBothBounds() throws {
        let cases: [(input: Int, expected: Int)] = [
            (-1, 0),
            (1_001, 1_000),
        ]

        for testCase in cases {
            let suiteName: String = "FinderFixTests.\(UUID().uuidString)"
            let defaults: UserDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defaults.removePersistentDomain(forName: suiteName)
            defer { defaults.removePersistentDomain(forName: suiteName) }

            var preferences: FinderFixPreferences = FinderFixPreferences()
            preferences.windowFocus.activationDelayMilliseconds = testCase.input
            defaults.set(try JSONEncoder().encode(preferences), forKey: "FinderFix.preferences.v3")

            let store: PreferencesStore = PreferencesStore(defaults: defaults)

            XCTAssertEqual(
                store.preferences.windowFocus.activationDelayMilliseconds,
                testCase.expected,
                "Input \(testCase.input) should normalize to \(testCase.expected)."
            )
        }
    }

    func testDecodedWindowFocusExclusionsAreTrimmedAndDeduplicatedCaseInsensitively() throws {
        let suiteName: String = "FinderFixTests.\(UUID().uuidString)"
        let defaults: UserDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var preferences: FinderFixPreferences = FinderFixPreferences()
        preferences.windowFocus.excludedApplicationBundleIdentifiers = [
            "  com.Example.Editor  ",
            "COM.example.editor",
            "\n",
            "org.example.Viewer\n",
            "ORG.EXAMPLE.VIEWER",
        ]
        defaults.set(try JSONEncoder().encode(preferences), forKey: "FinderFix.preferences.v3")

        let store: PreferencesStore = PreferencesStore(defaults: defaults)

        XCTAssertEqual(
            store.preferences.windowFocus.excludedApplicationBundleIdentifiers,
            ["com.Example.Editor", "org.example.Viewer"]
        )
    }
}
