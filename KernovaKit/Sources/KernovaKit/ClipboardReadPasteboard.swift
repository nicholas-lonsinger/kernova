import AppKit
import Foundation

/// The reads one pasteboard item answers, item-scoped rather than resolved
/// across the pasteboard: an intake decides a file copy from *every* item's own
/// URLs while taking its inline snapshot from item 0 alone, which
/// `NSPasteboard`'s own "first item that contains the type" reads cannot
/// express.
public protocol ClipboardPasteboardItemReading {
    /// This item's types, in fidelity order.
    var types: [NSPasteboard.PasteboardType] { get }

    /// This item's bytes for `type`, or `nil` when it vends none.
    func data(forType type: NSPasteboard.PasteboardType) -> Data?

    /// This item's `type` read as a string, or `nil` when it vends none.
    func string(forType type: NSPasteboard.PasteboardType) -> String?
}

extension NSPasteboardItem: ClipboardPasteboardItemReading {}

/// The read half of an `NSPasteboard`, paired with ``ClipboardWritePasteboard``.
public protocol ClipboardReadPasteboard: AnyObject {
    /// Monotonically increasing count of pasteboard changes — what a poll
    /// compares to know a new snapshot is standing.
    var changeCount: Int { get }

    /// Every item currently on the pasteboard, in order; empty when it holds
    /// nothing.
    var items: [any ClipboardPasteboardItemReading] { get }

    /// The file promises the pasteboard holds, as
    /// `readObjects(forClasses: [NSFilePromiseReceiver.self])` returns them:
    /// the receivers `ClipboardPasteboardReader.readOffer` takes.
    @MainActor var filePromiseReceivers: [any FilePromiseReceiving] { get }
}

extension NSPasteboard: ClipboardReadPasteboard {
    /// The pasteboard's items, or none when it is empty or cannot vend them.
    public var items: [any ClipboardPasteboardItemReading] { pasteboardItems ?? [] }

    /// The pasteboard's file promises, as `readObjects` returns them.
    @MainActor public var filePromiseReceivers: [any FilePromiseReceiving] {
        readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
    }
}

extension ClipboardReadPasteboard {
    /// Whether what the pasteboard holds may offer something, read from its
    /// types alone so nothing is fetched: it is not empty, and not marked
    /// transient.
    public var mayOfferSomething: Bool {
        let types = items.flatMap(\.types)
        let transient = NSPasteboard.PasteboardType(ClipboardSnapshotPolicy.transientMarkerUTI)
        return !types.isEmpty && !types.contains(transient)
    }
}

/// Both halves of a pasteboard: the one a clipboard end polls for the user's
/// copies and writes its peer's offers to.
public protocol ClipboardPasteboard: ClipboardReadPasteboard, ClipboardWritePasteboard {}

extension NSPasteboard: ClipboardPasteboard {}
