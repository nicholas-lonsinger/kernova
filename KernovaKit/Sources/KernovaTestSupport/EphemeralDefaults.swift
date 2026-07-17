import Foundation

// Shared ephemeral-`UserDefaults` test helpers for the test bundles that
// exercise a `UserDefaults`-backed preferences wrapper (KernovaTests'
// `AppPreferences`, KernovaMacOSAgentTests' `AgentPreferences`). Consolidated
// here so a suite-cleanup fix (or a new wrapper type gaining the same
// ceremony) lands once instead of being re-derived per test bundle.

// MARK: - makeEphemeralDefaults

/// Opens an isolated, pre-cleaned `UserDefaults` suite for a `.serialized` test suite.
///
/// State never bleeds in from another test or a prior run: a run hard-killed
/// mid-test (CI timeout, SIGKILL) skips any `defer`, so clearing *before* use is
/// the load-bearing half. Pass a fixed `suiteName` unique to the calling suite —
/// a fixed name (not a per-call UUID) bounds the on-disk footprint to a single
/// reusable tombstone plist. Shared by every suite (`AppPreferencesTests`,
/// `AgentPreferencesTests`, #449/#506) that needs a test never to read or write
/// the real `.standard` domain.
public func makeEphemeralDefaults(suiteName: String) -> UserDefaults {
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        fatalError("Could not open test UserDefaults suite '\(suiteName)'")
    }
    defaults.removePersistentDomain(forName: suiteName)
    if let plistURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
        .first?.appending(path: "Preferences/\(suiteName).plist")
    {
        try? FileManager.default.removeItem(at: plistURL)
    }
    return defaults
}

// MARK: - withEphemeralDefaults

/// Runs `body` with a fresh value of `T` wrapping an isolated, pre-cleaned
/// `UserDefaults` suite (via `makeEphemeralDefaults`), then tears the suite
/// down — including its cfprefsd tombstone plist (#449) — so tests never leak
/// state into another test, another run, or the real `.standard` domain.
///
/// Generic over the wrapper type so each `UserDefaults`-backed preferences
/// type (`AppPreferences`, `AgentPreferences`, …) gets this create/teardown
/// ceremony once instead of re-deriving it per test file; callers typically
/// wrap this in a thin, locally-named `withEphemeralPreferences` for
/// call-site readability.
public func withEphemeralDefaults<T>(
    suiteName: String,
    wrap: (UserDefaults) -> T,
    body: (T, UserDefaults) throws -> Void
) rethrows {
    let defaults = makeEphemeralDefaults(suiteName: suiteName)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        if let plistURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?.appending(path: "Preferences/\(suiteName).plist")
        {
            try? FileManager.default.removeItem(at: plistURL)
        }
    }
    try body(wrap(defaults), defaults)
}
