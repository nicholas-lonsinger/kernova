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
///
/// `NSPasteboard` is a class cluster with no public initializer and cannot be
/// subclassed, so a snapshot can only be staged on a real one by writing to a
/// named board; this is the seam a test substitutes to stage one directly.
public protocol ClipboardReadPasteboard: AnyObject {
    /// Monotonically increasing count of pasteboard changes — what a poll
    /// compares to know a new snapshot is standing.
    var changeCount: Int { get }

    /// Every item currently on the pasteboard, in order; empty when it holds
    /// nothing.
    var items: [any ClipboardPasteboardItemReading] { get }
}

extension NSPasteboard: ClipboardReadPasteboard {
    /// The pasteboard's items, or none when it is empty or cannot vend them.
    public var items: [any ClipboardPasteboardItemReading] { pasteboardItems ?? [] }
}
