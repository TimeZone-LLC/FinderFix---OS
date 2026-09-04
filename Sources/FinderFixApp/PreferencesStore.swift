import Combine
import Foundation

@MainActor
final class PreferencesStore: ObservableObject {
    @Published var preferences: FinderFixPreferences

    private static let storageKey: String = "FinderFix.preferences.v3"
    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private var persistenceSubscription: AnyCancellable?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.encoder = JSONEncoder()

        if let data: Data = defaults.data(forKey: Self.storageKey),
           let decoded: FinderFixPreferences = try? JSONDecoder().decode(FinderFixPreferences.self, from: data),
           decoded.schemaVersion == FinderFixPreferences.currentVersion {
            self.preferences = decoded.normalized()
        } else {
            self.preferences = FinderFixPreferences()
        }

        persistenceSubscription = $preferences
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] preferences in
                self?.persist(preferences)
            }
    }

    func resetToDefaults() {
        preferences = FinderFixPreferences()
    }

    func enableRecommendedRules() {
        var updatedPreferences: FinderFixPreferences = preferences
        updatedPreferences.windowRulesEnabled = true
        updatedPreferences.finderChromeEnabled = true
        updatedPreferences.moveEligibleFinderDialogs = true
        preferences = updatedPreferences
    }

    private func persist(_ preferences: FinderFixPreferences) {
        guard let data: Data = try? encoder.encode(preferences.normalized()) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
