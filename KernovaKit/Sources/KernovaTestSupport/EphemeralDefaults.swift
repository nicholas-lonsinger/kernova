import Foundation

// Shared ephemeral-`UserDefaults` test helpers for the test bundles that
// exercise a `UserDefaults`-backed preferences wrapper.

// MARK: - makeEphemeralDefaults

/// Opens an isolated, pre-cleaned `UserDefaults` suite for a `.serialized` test suite.
///
/// A run hard-killed mid-test (CI timeout, SIGKILL) skips any `defer`, so
/// clearing *before* use is the load-bearing half. Pass a fixed `suiteName`
/// unique to the calling suite — not a per-call UUID, which would leave one
/// tombstone plist per run.
public func makeEphemeralDefaults(suiteName: String) -> UserDefaults {
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        fatalError("Could not open test UserDefaults suite '\(suiteName)'")
    }
    defaults.removePersistentDomain(forName: suiteName)
    if let plistURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
        .first?.appendingPathComponent("Preferences/\(suiteName).plist")
    {
        try? FileManager.default.removeItem(at: plistURL)
    }
    return defaults
}

// MARK: - withEphemeralDefaults

/// Runs `body` with a fresh value of `T` wrapping an isolated, pre-cleaned
/// `UserDefaults` suite (via `makeEphemeralDefaults`), then tears the suite
/// down — including its cfprefsd tombstone plist — so tests never leak state
/// into another test, another run, or the real `.standard` domain.
public func withEphemeralDefaults<T>(
    suiteName: String,
    wrap: (UserDefaults) -> T,
    body: (T, UserDefaults) throws -> Void
) rethrows {
    let defaults = makeEphemeralDefaults(suiteName: suiteName)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        if let plistURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Preferences/\(suiteName).plist")
        {
            try? FileManager.default.removeItem(at: plistURL)
        }
    }
    try body(wrap(defaults), defaults)
}
