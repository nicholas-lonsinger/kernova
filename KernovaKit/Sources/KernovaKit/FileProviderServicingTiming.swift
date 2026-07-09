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
        .milliseconds(Int(connectRetryDelaySeconds * 1000))
    }

    /// Upper bound on the owner's transient connect retries: the fewest attempts
    /// whose cumulative delay spans `connectWait`.
    ///
    /// Derived, not a separately-maintained literal — editing either constant
    /// above re-derives this (15 today: 30 / 2).
    public static var maxConnectAttempts: Int {
        max(1, Int((connectWait / connectRetryDelaySeconds).rounded(.up)))
    }
}
