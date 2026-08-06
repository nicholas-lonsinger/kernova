import Foundation
import KernovaKit

/// Connection state of the always-on control channel to the host.
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
/// `enabled` / `disabled` are the host-policy feature state; the other five
/// record the most recent flow event, each set at the moment it starts rather
/// than on completion. A flow event overwrites `enabled`; only host policy sets
/// `disabled`.
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
    /// Any host fetch counts — a clipboard-window preview or an explicit "Copy
    /// to Mac" — not necessarily a paste; the guest can't tell them apart.
    case sentToHost
    /// An inbound paste from the host was materialized on the guest pasteboard.
    case receivedFromHost
    /// A paste of the host's offer did not happen, for the reason the associated
    /// code names.
    ///
    /// The gesture was made in this guest, so the reason is reported here as well
    /// as to the host.
    /// `pasteLimitBytes` is the ceiling that was in force at the refusal, carried
    /// here rather than read when the menu is built: the menu rebuilds on every
    /// open, so a ceiling raised after the refusal would otherwise rewrite the
    /// figure a past refusal names. `nil` for reasons no ceiling explains.
    case pasteRefused(ClipboardErrorCode, pasteLimitBytes: Int?)
    /// Host policy turned clipboard sharing off.
    case disabled
}
