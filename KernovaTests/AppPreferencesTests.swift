import Testing
import Foundation
@testable import Kernova

// A fixed suite name (rather than a fresh UUID per call) bounds the on-disk
// footprint to a single tombstone plist regardless of how many times the
// suite runs; `.serialized` below keeps the two tests from racing over that
// shared domain. See #449.
@Suite("AppPreferences", .serialized)
struct AppPreferencesTests {
    private static let suiteName = "test.kernova.appprefs"

    /// Runs `body` with a fresh `AppPreferences` over an isolated defaults
    /// suite, then tears the suite down so tests never touch the real
    /// `.standard` domain, each other's state, or leak a persisted plist.
    private func withEphemeralPreferences(
        _ body: (AppPreferences, UserDefaults) throws -> Void
    ) throws {
        let suiteName = Self.suiteName
        let defaults = makeEphemeralDefaults(suiteName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            // cfprefsd leaves an empty tombstone plist behind even after
            // removePersistentDomain empties the in-memory domain; delete it
            // so repeated test runs don't accumulate files (#449).
            if let plistURL = FileManager.default.urls(
                for: .libraryDirectory, in: .userDomainMask
            ).first?.appending(path: "Preferences/\(suiteName).plist") {
                try? FileManager.default.removeItem(at: plistURL)
            }
        }
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
