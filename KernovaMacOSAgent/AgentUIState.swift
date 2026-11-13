import Foundation
import KernovaKit
import KernovaTransferProgress

/// Clipboard sharing state for display in the menu.
///
/// `enabled` / `disabled` are the host-policy feature state; every other case
/// records the most recent flow event, each set at the moment it starts rather
/// than on completion. A flow event overwrites `enabled`, and withdrawing the
/// offer one left standing returns to it; only host policy sets `disabled`.
enum ClipboardActivity: Equatable, Sendable {
    /// Sharing is on by host policy and no copy of this guest's stands on the
    /// host clipboard: nothing has crossed yet this session, or the guest
    /// clipboard was emptied and the offer it had crossed under withdrawn.
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
    /// A copy left nothing that could be offered to the host at all.
    ///
    /// The copy was made in this guest, so the outcome is reported here.
    case copyCarriedNothing
    /// A copy crossed, with `skipped` of its items not carried whole.
    ///
    /// The host's readout covers only what the offer carried, so the count the
    /// copy lost is named here or nowhere.
    case copyPartlyCarried(skipped: Int)
    /// The host withdrew a copy it sent, the connection still up, so what no
    /// paste had of it was removed from this clipboard: only its files and the
    /// items holding them when `filesOnly`, the rest staying.
    case copyWithdrawn(filesOnly: Bool)
    /// Host policy turned clipboard sharing off.
    case disabled

    /// Whether the status item announces this activity in a callout by itself
    /// rather than leaving it for the next time the user opens the dropdown.
    ///
    /// True for the outcomes of a gesture made in this guest that produces no
    /// other signal — a paste that yields nothing, a copy that crosses nothing
    /// or only part of itself — and for a copy the Mac took back from this
    /// clipboard.
    var isNotice: Bool {
        switch self {
        case .pasteRefused, .copyCarriedNothing, .copyPartlyCarried, .copyWithdrawn:
            return true
        case .enabled, .offeredToHost, .offeredFromHost, .sentToHost, .receivedFromHost, .disabled:
            return false
        }
    }
}
