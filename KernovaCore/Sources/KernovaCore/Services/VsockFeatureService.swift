import Foundation

/// Why a vsock feature service settled, which decides whether the owner hears
/// about it.
enum VsockSettleReason {
    /// The channel died underneath the service — the peer closed it, the peer
    /// spoke on the wrong port, or a watchdog terminated it.
    case channelLost
    /// The owner asked: a session teardown, a live policy withdrawal, or a
    /// fresh connection replacing this one.
    case ownerRequested
}

/// The settle contract every host-side vsock feature service keeps: one
/// instance serves exactly one accepted channel and settles when that channel
/// dies under it.
@MainActor
protocol VsockFeatureService: AnyObject {
    /// Begins serving the accepted channel. Idempotent, and a no-op once the
    /// service has settled.
    func start()

    /// Owner-requested teardown. Idempotent and terminal — a reconnect is
    /// served by a fresh instance — and never calls back, because the owner
    /// already knows.
    func stop()

    /// Called at most once, on fully-settled state, when the channel ended on
    /// its own rather than by ``stop()``. Wired by the owner at the accept site.
    ///
    /// What the reaction is, and whether the owner drops its reference to the
    /// settled service or keeps it, is the owner's decision per service.
    var onChannelLost: (@MainActor () -> Void)? { get set }
}
