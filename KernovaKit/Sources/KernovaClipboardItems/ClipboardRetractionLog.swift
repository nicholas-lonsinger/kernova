import KernovaKit

/// The one wording of the line an end logs when it retracts its write of the far side's clipboard, the same at the
/// host and the guest: each names the far side where the other names it.
public enum ClipboardRetractionLog {
    /// The end whose pasteboard a retraction took back from.
    public enum End: Sendable {
        /// The host's, for the VM named `vm`.
        case host(vm: String)
        /// A guest's.
        case guest
    }

    /// The line saying what `retraction` took back from `end`'s pasteboard, because the far side's offer ended
    /// as `ending` says; nil when it took nothing back.
    public static func line(
        _ retraction: ClipboardRetraction?, on end: End, because ending: ClipboardItemExchange.RemoteEnding
    ) -> String? {
        let (far, board, peer) =
            switch end {
            case .host(let vm): ("the guest", "host", " for '\(vm)'")
            case .guest: ("the Mac", "guest", "")
            }
        let (taken, kept): (String, String)
        switch retraction {
        case .keptEverything, nil: return nil
        case .cleared: (taken, kept) = ("\(far)'s clipboard", "")
        case .keptPart: (taken, kept) = ("part of \(far)'s clipboard", ", the rest kept")
        }
        let why =
            switch ending {
            case .linkLost: "clipboard sharing with \(far) stopped"
            case .settingChanged: "the clipboard setting changed"
            case .byFarSide: "\(far) withdrew its offer"
            case .superseded: "a copy of this side's replaced it"
            case .cancelledHere: "a paste of it was cancelled"
            }
        return "Retracted \(taken) from the \(board) pasteboard\(peer)\(kept): \(why)"
    }
}
