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

    /// The notice that stands once `later` follows `standing`: `later` when it
    /// is a notice, `standing` while `later` leaves it standing, else none.
    static func standingNotice(_ standing: ClipboardActivity?, after later: ClipboardActivity) -> ClipboardActivity? {
        if later.isNotice { return later }
        guard let standing, !standing.isEnded(by: later) else { return nil }
        return standing
    }

    /// Whether `later`, an activity after this notice, ends it: the clipboard
    /// content the notice is about is gone, or the gesture it reports was made
    /// again and went through. Anything else leaves the notice standing.
    ///
    /// A copy notice is about the guest's copy; a paste notice about the
    /// host's offer the paste was of.
    func isEnded(by later: ClipboardActivity) -> Bool {
        switch (self, later) {
        // A later notice replaces this one.
        case (_, .pasteRefused), (_, .copyCarriedNothing), (_, .copyPartlyCarried):
            return true
        // The connection ending withdraws the offers on both sides.
        case (_, .disabled):
            return true
        // A new copy on either side replaces both the guest's copy and the
        // host's offer on the guest's pasteboard.
        case (_, .offeredToHost), (_, .offeredFromHost):
            return true
        // A paste that landed is the refused paste made again.
        case (.pasteRefused, .receivedFromHost):
            return true
        // The host reading the guest's copy is the copy being used, short as
        // the notice says; a paste landing says nothing about a copy; a
        // connection coming up follows one that ended.
        case (_, .sentToHost), (_, .receivedFromHost), (_, .enabled):
            return false
        }
    }
}
