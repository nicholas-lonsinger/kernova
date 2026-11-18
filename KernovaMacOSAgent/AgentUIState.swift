import Foundation
import KernovaKit

/// Clipboard sharing state for display in the menu.
///
/// `enabled` / `disabled` say whether a connection carries the clipboard; every
/// other case records the most recent flow event, each set at the moment it
/// starts rather than on completion. A flow event overwrites `enabled`, and
/// only the connection's end sets `disabled`.
enum ClipboardActivity: Equatable, Sendable {
    /// A connection carries the clipboard, and nothing has crossed on it yet.
    case enabled
    /// The guest's local clipboard was offered to the host (a local copy).
    case offeredToHost
    /// The host offered its clipboard to the guest (a remote copy); the guest
    /// registered lazy promises but pulled no bytes.
    case offeredFromHost
    /// The host pulled the guest's clipboard bytes (an outbound stream started).
    ///
    /// The host pulls when anything on the Mac reads what the guest's offer
    /// promised there — a paste, or another app reading the clipboard — and the
    /// guest can't tell which.
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
    /// No connection carries the clipboard: the host's policy has it off, or
    /// the connection to the host is down.
    case disabled

    /// Whether the status item announces this activity in a callout by itself
    /// rather than leaving it for the next time the user opens the dropdown.
    ///
    /// True for the outcomes of a gesture made in this guest that produces no
    /// other signal: a paste that yields nothing, a copy that crosses nothing
    /// or only part of itself.
    var isNotice: Bool {
        switch self {
        case .pasteRefused, .copyCarriedNothing, .copyPartlyCarried:
            return true
        case .enabled, .offeredToHost, .offeredFromHost, .sentToHost, .receivedFromHost, .disabled:
            return false
        }
    }
}
