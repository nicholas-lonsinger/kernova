import KernovaKit

/// The one wording of the line an end logs when it retracts its write of the far side's clipboard or copy, the
/// same at the host and the guest: each names the far side where the other names it.
public enum ClipboardRetractionLog {
    /// Which write of the far side's a retraction took back.
    public enum Write: Sendable {
        /// Passthrough's write of the far side's clipboard.
        case clipboard
        /// A copy command's write of the far side's copy.
        case copy
    }

    /// The end whose pasteboard a retraction took back from.
    public enum End: Sendable {
        /// The host's, for the VM named `vm`.
        case host(vm: String)
        /// A guest's.
        case guest
    }

    /// Why a retraction took back what it did.
    public enum Cause: Sendable {
        /// This end stopped passthrough.
        case passthroughStopped
        /// The far side's offer or copy ended so.
        case ended(ClipboardItemExchange.RemoteEnding)
    }

    /// The line saying what `retraction` of `write` took back from `end`'s pasteboard, and why; nil when it took
    /// nothing back.
    public static func line(
        _ retraction: ClipboardRetraction?, of write: Write, on end: End, because cause: Cause
    ) -> String? {
        let (far, board, peer) =
            switch end {
            case .host(let vm): ("the guest", "host", " for '\(vm)'")
            case .guest: ("the Mac", "guest", "")
            }
        let (taken, kept): (String, String)
        switch (retraction, write) {
        case (.keptEverything, _), (nil, _): return nil
        case (.cleared, .clipboard): (taken, kept) = ("\(far)'s clipboard", "")
        case (.keptPart, .clipboard): (taken, kept) = ("part of \(far)'s clipboard", ", the rest kept")
        case (.cleared, .copy): (taken, kept) = ("\(far)'s copy", "")
        case (.keptPart, .copy): (taken, kept) = ("\(far)'s copied files", ", the rest of the copy kept")
        }
        let why =
            switch cause {
            case .passthroughStopped: "passthrough stopped"
            case .ended(.linkLost): "clipboard sharing with \(far) stopped"
            case .ended(.passthroughStopped): "\(far) stopped passthrough"
            case .ended(.byFarSide) where write == .copy: "\(far) withdrew the copy"
            case .ended(.byFarSide), .ended(.movedOn): "\(far)'s clipboard moved on"
            case .ended(.superseded): "a copy of this side's replaced it"
            }
        return "Retracted \(taken) from the \(board) pasteboard\(peer)\(kept): \(why)"
    }
}
