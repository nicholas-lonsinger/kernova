import Testing
import Foundation

// A fixed suite name (rather than a fresh UUID per call) bounds the on-disk
// footprint to a single tombstone plist regardless of how many times the
// suite runs; `.serialized` below keeps the two tests from racing over that
// shared domain. Mirrors `KernovaTests/AppPreferencesTests.swift` (#449).
@Suite("AgentPreferences", .serialized)
struct AgentPreferencesTests {
    private static let suiteName = "test.kernova.agentprefs"

    /// Runs `body` with a fresh `AgentPreferences` over an isolated defaults
    /// suite, then tears the suite down so tests never touch the real
    /// `.standard` domain, each other's state, or leak a persisted plist.
    private func withEphemeralPreferences(
        _ body: (AgentPreferences, UserDefaults) throws -> Void
    ) throws {
        let suiteName = Self.suiteName
        let defaults = makeEphemeralDefaults(suiteName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            if let plistURL = FileManager.default.urls(
                for: .libraryDirectory, in: .userDomainMask
            ).first?.appending(path: "Preferences/\(suiteName).plist") {
                try? FileManager.default.removeItem(at: plistURL)
            }
        }
        try body(AgentPreferences(defaults: defaults), defaults)
    }

    @Test("fileProviderReminderDismissed defaults to false")
    func defaultsToFalse() throws {
        try withEphemeralPreferences { prefs, _ in
            #expect(prefs.fileProviderReminderDismissed == false)
        }
    }

    @Test("fileProviderReminderDismissed round-trips through UserDefaults")
    func roundTrips() throws {
        try withEphemeralPreferences { prefs, defaults in
            prefs.fileProviderReminderDismissed = true
            #expect(prefs.fileProviderReminderDismissed == true)
            #expect(defaults.bool(forKey: "fileProviderReminderDismissed") == true)

            prefs.fileProviderReminderDismissed = false
            #expect(prefs.fileProviderReminderDismissed == false)
        }
    }
}
