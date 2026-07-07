import Foundation

/// State surfaced by the agent's background services to its menu-bar UI.
///
/// These are produced by the always-on control agent and the clipboard agent and
/// consumed by `AgentStatusItemController` (pulled when the menu opens,
/// pushed to update the status-item icon). Kept here, separate from the services
/// that mutate them, so the pure menu-text mappers in `AgentMenuText` and
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

/// Clipboard sharing state for display in the menu.
///
/// Two of the cases are feature-states (`enabled` / `disabled`, driven by host
/// policy); the other four are the most recent *flow* event, forming a symmetric
/// 2×2 of offer-vs-fulfillment across both directions:
///
/// |             | offer (someone copied) | fulfillment (someone pasted) |
/// | ----------- | ---------------------- | ---------------------------- |
/// | guest → host | `offeredToHost`        | `sentToHost`                 |
/// | host → guest | `offeredFromHost`      | `receivedFromHost`           |
///
/// A flow event overwrites `enabled`; `disabled` is set only when host policy
/// turns sharing off.
///
/// The four flow cases are deliberately a *last-event* signal, not a live "in
/// progress" one: the inbound paste pull runs synchronously on the main thread
/// (the pasteboard server's `provideDataForType` callback), and the status item +
/// its menu are also main-thread, so an in-flight transfer can't be drawn while
/// it blocks main. The achievable, useful signal is what happened most recently,
/// set at quick main-thread boundaries and read when the menu next opens.
///
/// RATIONALE: `sentToHost` is marked when the outbound stream *starts* (the host's
/// request arrives and `ClipboardStreamSender.startTransfer` is called), not when
/// it completes — the byte stream runs off-main and can't be drawn in flight. This
/// mirrors `offeredToHost`, which is set at offer-*send* time, not on delivery. A
/// transfer that later aborts can therefore briefly read "sent to host", which is
/// acceptable for a best-effort last-event line.
enum ClipboardActivity: Equatable, Sendable {
    /// Sharing is on by host policy and nothing has crossed yet this session.
    case enabled
    /// The guest's local clipboard was offered to the host (a local copy).
    case offeredToHost
    /// The host offered its clipboard to the guest (a remote copy); the guest
    /// registered lazy promises but pulled no bytes.
    case offeredFromHost
    /// The host pulled the guest's clipboard bytes (an outbound stream started).
    ///
    /// "Pull" today is any host fetch of the bytes — a clipboard-window preview
    /// or an explicit "Copy to Mac" — not necessarily a genuine host paste,
    /// because the host materializes eagerly and the guest can't tell the
    /// triggers apart. Once the host writes its pasteboard lazily (a provider
    /// that resolves at paste time — issue #392), this pull coincides with an
    /// actual host paste, which is the intended meaning.
    case sentToHost
    /// An inbound paste from the host was materialized on the guest pasteboard.
    case receivedFromHost
    /// Host policy turned clipboard sharing off.
    case disabled
}
