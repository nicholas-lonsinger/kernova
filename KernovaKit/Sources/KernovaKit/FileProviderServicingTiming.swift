import Foundation

/// Structural coupling between the two servicing-connect timing budgets (#466).
///
/// The extension's `FileProviderServiceSource.connectTimeout` (how long the
/// extension waits, after ringing the doorbell, for the owner to connect) and the
/// owner's `FileProviderServicingConnector` reconnect budget
/// (`maxConnectAttempts × connectRetryDelay`) are deliberately sized so the
/// owner's retry budget spans the extension's wait — a slow-relaunching owner is
/// still caught within the window the paste is waiting, rather than the owner
/// giving up while the extension keeps waiting. Before this type, that invariant
/// lived only as a comment matching two independent literals in two different
/// files; editing either in isolation silently misaligned them. `maxConnectAttempts`
/// now *derives* from `connectWait`/`connectRetryDelaySeconds`, so the two sides
/// cannot drift apart.
public enum FileProviderServicingTiming {
    /// Extension-side bounded wait for the owner to connect after the doorbell is
    /// rung, kept well under Finder's ~60 s paste deadline so a missing owner
    /// fails cleanly.
    ///
    /// The source of truth both sides derive from.
    public static let connectWait: TimeInterval = 30

    /// Owner-side delay between transient connect retries, in seconds.
    public static let connectRetryDelaySeconds: TimeInterval = 2

    /// `connectRetryDelaySeconds` as a `DispatchTimeInterval`, for the connector.
    public static var connectRetryDelay: DispatchTimeInterval {
        .seconds(Int(connectRetryDelaySeconds))
    }

    /// Upper bound on the owner's transient connect retries: the fewest
    /// attempts whose cumulative *inter-attempt delay* spans `connectWait`.
    ///
    /// The owner's first connect attempt fires immediately (no preceding
    /// delay) — only the retries after a failure wait `connectRetryDelay` — so
    /// N attempts span only `(N - 1) × connectRetryDelaySeconds` of real time,
    /// one delay short of `N × connectRetryDelaySeconds`. The `+ 1` corrects
    /// for that: derived, not a separately-maintained literal — editing either
    /// constant above re-derives this (16 today: `⌈30 / 2⌉ + 1`, giving 15
    /// actual retry delays = 30s, matching `connectWait` exactly).
    public static var maxConnectAttempts: Int {
        max(1, Int((connectWait / connectRetryDelaySeconds).rounded(.up)) + 1)
    }

    /// Extension-side bounded wait for the owner's byte-pull reply once a
    /// connection is live (`FileProviderServiceSource.fetchReplyTimeout`).
    ///
    /// The single source of truth for that default, so a test that wants "the
    /// full production reply timeout" (see CLAUDE.md's "Async waits in tests")
    /// can reference it instead of independently re-hardcoding `120`, which
    /// would let the two silently drift apart.
    public static let fetchReplyWait: TimeInterval = 120
}
