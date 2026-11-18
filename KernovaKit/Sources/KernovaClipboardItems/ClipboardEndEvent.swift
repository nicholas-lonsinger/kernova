import KernovaAgentCore
import KernovaKit

/// When a side offers its clipboard to the other: the one thing the clipboard setting gates. Everything after an
/// offer is the same either way, and so is its end: a later copy on the side that offered withdraws it.
public enum ClipboardOfferGate: Sendable, Equatable {
    /// At each copy made while the ends are connected: passthrough.
    case everyCopy
    /// Only at a command: the host's "Copy to …" commands, which offer the Mac's clipboard and ask the guest to
    /// offer its own.
    case onCommand
}

/// Which end a ``ClipboardEnd`` is, and the link a connection gives it, fixed by its type.
public protocol ClipboardEndRole {
    /// The calls of the connection this end runs over.
    associatedtype Link: Sendable
    /// The end its exchange is.
    static var side: ClipboardItemExchange.Side { get }
    /// `link`'s item calls, the ones every end makes.
    static func itemCalls(_ link: Link) -> any ClipboardItemLink
}

/// The host's end, whose user's commands offer the Mac's clipboard and ask for the guest's.
public enum ClipboardHost: ClipboardEndRole {
    /// A link that can ask the guest for its clipboard.
    public typealias Link = any ClipboardHostItemLink
    /// ``ClipboardItemExchange/Side/host``.
    public static var side: ClipboardItemExchange.Side { .host }
    /// `link` itself.
    public static func itemCalls(_ link: any ClipboardHostItemLink) -> any ClipboardItemLink { link }
}

/// A guest agent's end, which has no command of its own: it answers the host's request for its clipboard.
public enum ClipboardGuest: ClipboardEndRole {
    /// A link of the item calls alone.
    public typealias Link = any ClipboardItemLink
    /// ``ClipboardItemExchange/Side/guest``.
    public static var side: ClipboardItemExchange.Side { .guest }
    /// `link` itself.
    public static func itemCalls(_ link: any ClipboardItemLink) -> any ClipboardItemLink { link }
}

/// What started a read of a side's pasteboard to offer it.
public enum ClipboardOfferTrigger: Sendable, Equatable {
    /// The poll saw a copy.
    case copy
    /// This side's user gave the command.
    case command
    /// The host asked for this side's clipboard.
    case request
}

/// What a read of a side's pasteboard came to.
public enum ClipboardReadOutcome: Sendable, Equatable {
    /// It is offered, but for `skipped` of its items, each naming a file that is gone or could not be read.
    case offered(skipped: Int)
    /// The pasteboard is empty, or marked transient or auto-generated.
    case nothingToCopy
    /// The pasteboard holds items, none of them anything a pasteboard carries, and none naming a file that is
    /// gone or could not be read.
    case nothingCarriable
    /// The pasteboard's items name files, none of which could be read, and hold nothing else.
    case unreadable
    /// The pasteboard holds this end's write of the far side's offer, which the far side holds already.
    case heldByFarSide
    /// Nothing was offered: the pasteboard moved on before the read landed, a newer read replaced it, or what it
    /// would answer — the connection, the setting, this side's right to offer, the request — ended first.
    case superseded
}

/// What a ``ClipboardEnd`` did that its owner reports or shows.
public enum ClipboardEndEvent: Sendable, Equatable {
    /// A read of this side's pasteboard began; its ``readEnded(_:_:)`` follows once.
    case readBegan(ClipboardOfferTrigger)
    /// A read of this side's pasteboard ended.
    case readEnded(ClipboardOfferTrigger, ClipboardReadOutcome)
    /// The trigger offers nothing, and nothing is read: the gate does not admit it, or this side may not offer.
    case notAdmitted(ClipboardOfferTrigger)
    /// The far side's offer was written to this side's pasteboard, or not, as the outcome says.
    case published(ClipboardOfferPublishOutcome)
    /// This side's write of the far side's offer was withdrawn, leaving what the retraction says, because the
    /// offer ended so.
    case retracted(ClipboardRetraction, ClipboardItemExchange.RemoteEnding)
    /// The host: nothing the guest offered for its request was taken, and why.
    case requestRefused(ClipboardItemExchange.RequestRefusal)
    /// A pull of this side's offer was served.
    case served
    /// A pull of the far side's offer landed here.
    case landed
    /// A pull of the far side's offer failed a paste: `TOO_LARGE` over the paste ceiling.
    case pullFailed(WireError)
    /// The pasteboard refused a paste's bytes of this side's write of the far side's offer.
    case pasteRefused
}
