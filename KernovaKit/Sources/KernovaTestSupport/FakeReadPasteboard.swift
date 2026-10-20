import AppKit
import Foundation
import KernovaKit
import KernovaSynchronization

/// One in-memory pasteboard item: the types it declares, in fidelity order, and
/// the bytes it hands over for each.
///
/// A type declared with no bytes behind it models a lazy provider that declines
/// to vend — the case a reader must tell apart from one that never declared the
/// type at all.
public struct FakePasteboardItem: ClipboardPasteboardItemReading, Sendable {
    /// The types this item declares, in fidelity order.
    public let types: [NSPasteboard.PasteboardType]

    private let bytes: [NSPasteboard.PasteboardType: Data]

    /// Creates an item holding `representations`, in the order given.
    public init(_ representations: [(type: NSPasteboard.PasteboardType, data: Data)]) {
        self.types = representations.map(\.type)
        self.bytes = Dictionary(
            representations.map { ($0.type, $0.data) }, uniquingKeysWith: { _, latest in latest })
    }

    /// Creates an item declaring `types` while serving only what `bytes` holds.
    public init(types: [NSPasteboard.PasteboardType], bytes: [NSPasteboard.PasteboardType: Data]) {
        self.types = types
        self.bytes = bytes
    }

    /// The bytes staged for `type`, or `nil` when the item vends none.
    public func data(forType type: NSPasteboard.PasteboardType) -> Data? { bytes[type] }

    /// The bytes staged for `type` read as UTF-8, or `nil` when there are none.
    public func string(forType type: NSPasteboard.PasteboardType) -> String? {
        bytes[type].flatMap { String(data: $0, encoding: .utf8) }
    }
}

/// In-memory `ClipboardReadPasteboard` a test stages a snapshot on directly.
public final class FakeReadPasteboard: ClipboardReadPasteboard, Sendable {
    private let staged = Locked<[FakePasteboardItem]>([])

    /// Creates an empty pasteboard double.
    public init() {}

    /// The items currently staged, in order.
    public var items: [any ClipboardPasteboardItemReading] { staged.withLock { $0 } }

    /// Stages a single item, as one copy does.
    public func setItem(_ representations: [(type: NSPasteboard.PasteboardType, data: Data)]) {
        setItems([FakePasteboardItem(representations)])
    }

    /// Stages several items, as a multi-select copy does.
    public func setItems(_ items: [FakePasteboardItem]) {
        staged.withLock { $0 = items }
    }
}
