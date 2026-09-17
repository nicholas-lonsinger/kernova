import Foundation

// Ephemeral-`UserDefaults` test helpers for the test bundle that exercises a
// `UserDefaults`-backed preferences wrapper.

// MARK: - makeEphemeralDefaults

/// Opens a pre-cleaned `UserDefaults` suite for a `.serialized` test suite,
/// isolated from every other suite in this process.
///
/// Isolation stops at the process: each concurrent test host shares the
/// `app.kernova` container, so a suite name held past the clear can be written
/// by another run — what a test reads back is trustworthy only where this
/// process wrote it in between.
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

/// Runs `body` with a fresh value of `T` wrapping a pre-cleaned `UserDefaults`
/// suite (via `makeEphemeralDefaults`, whose `///` carries how far the isolation
/// reaches), then tears the suite down — including its cfprefsd tombstone plist
/// — so the suite leaks nothing into another test in this process or into the
/// real `.standard` domain.
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
