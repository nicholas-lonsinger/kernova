import Foundation

/// State surfaced by the agent's background services to its menu-bar UI.
///
/// These are produced by the always-on control agent and the clipboard agent and
/// consumed by `GuestAgentStatusItemController` (pulled when the menu opens,
/// pushed to update the status-item icon). Kept here, separate from the services
/// that mutate them, so the pure menu-text mappers in `GuestAgentMenuText` and
/// their tests can depend on the state without depending on the services.

/// Connection state of the always-on control channel to the host.
///
/// Derived from the control agent's connect / serve / liveness path: no live
/// channel means `.connecting` (the reconnect loop is trying), a live channel
/// with recent host traffic is `.connected`, and a live channel gone quiet past
/// the unresponsive threshold is `.unresponsive`.
enum HostConnectionState: Equatable, Sendable {
    /// No live control channel — the reconnect loop is attempting to connect.
    case connecting
    /// Control channel is up and the host is responding.
    case connected
    /// Control channel is up but the host has gone silent past the unresponsive
    /// threshold (it may be hung; the watchdog will eventually recycle the channel).
    case unresponsive
}

/// The most recent clipboard activity, for display in the menu.
///
/// This is deliberately a *last-event* signal, not a live "in progress" one: the
/// inbound paste pull runs synchronously on the main thread (the pasteboard
/// server's `provideDataForType` callback), and the status item + its menu are
/// also main-thread, so an in-flight transfer can't be drawn while it blocks
/// main. The achievable, useful signal is therefore what happened most recently,
/// set at quick main-thread boundaries and read when the menu next opens.
enum ClipboardActivity: Equatable, Sendable {
    /// Nothing has crossed the clipboard yet this session.
    case idle
    /// The guest's local clipboard was offered to the host (a local copy).
    case offeredToHost
    /// An inbound paste from the host was materialized on the guest pasteboard.
    case receivedFromHost
}
