import Testing
import Foundation
@testable import Kernova

@Suite("AppPreferences")
struct AppPreferencesTests {
    /// Runs `body` with a fresh `AppPreferences` over an isolated, ephemeral
    /// defaults suite, then tears the suite down so tests never touch the real
    /// `.standard` domain, each other's state, or leak a persisted plist.
    private func withEphemeralPreferences(
        _ body: (AppPreferences, UserDefaults) throws -> Void
    ) throws {
        let suiteName = "test.kernova.appprefs.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(AppPreferences(defaults: defaults), defaults)
    }

    @Test("alwaysShowAdvancedOptions defaults to false")
    func defaultsToFalse() throws {
        try withEphemeralPreferences { prefs, _ in
            #expect(prefs.alwaysShowAdvancedOptions == false)
        }
    }

    @Test("alwaysShowAdvancedOptions round-trips through UserDefaults")
    func roundTrips() throws {
        try withEphemeralPreferences { prefs, defaults in
            prefs.alwaysShowAdvancedOptions = true
            #expect(prefs.alwaysShowAdvancedOptions == true)
            #expect(defaults.bool(forKey: "alwaysShowAdvancedOptions") == true)

            prefs.alwaysShowAdvancedOptions = false
            #expect(prefs.alwaysShowAdvancedOptions == false)
        }
    }
}
