import Foundation

/// Structural coupling between the two servicing-connect timing budgets.
///
/// The owner's reconnect budget (`maxConnectAttempts × connectRetryDelay`) must
/// span the extension's wait for it (`connectWait`), so a slow-relaunching owner
/// is still caught inside the window the paste is waiting rather than giving up
/// first. `maxConnectAttempts` derives from the two constants below to keep that
/// true.
enum FileProviderServicingTiming {
    /// Extension-side bounded wait for the owner to connect after the doorbell is
    /// rung, kept well under Finder's ~60 s paste deadline so a missing owner
    /// fails cleanly.
    static let connectWait: TimeInterval = 30

    /// Owner-side delay between transient connect retries, in seconds.
    static let connectRetryDelaySeconds: TimeInterval = 2

    /// `connectRetryDelaySeconds` as a `DispatchTimeInterval`, for the connector.
    static var connectRetryDelay: DispatchTimeInterval {
        .seconds(Int(connectRetryDelaySeconds))
    }

    /// Upper bound on the owner's transient connect retries: the fewest
    /// attempts whose cumulative *inter-attempt delay* spans `connectWait`.
    ///
    /// The first attempt fires immediately, so N attempts span only
    /// `(N - 1) × connectRetryDelaySeconds` of real time — the `+ 1` corrects for
    /// that missing delay.
    static var maxConnectAttempts: Int {
        max(1, Int((connectWait / connectRetryDelaySeconds).rounded(.up)) + 1)
    }

    /// Extension-side bounded wait for the owner's byte-pull reply once a
    /// connection is live (`FileProviderServiceSource.fetchReplyTimeout`).
    ///
    /// A test wanting the full production reply timeout references this rather
    /// than re-hardcoding it (see docs/TESTING.md, "Async waits in tests").
    static let fetchReplyWait: TimeInterval = 120
}
