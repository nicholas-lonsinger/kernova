import AppKit
import Foundation
import KernovaKit

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
    private let onRead: (@Sendable (NSPasteboard.PasteboardType) -> Void)?

    /// Creates an item holding `representations`, in the order given, telling
    /// `onRead` of every read of one.
    public init(
        _ representations: [(type: NSPasteboard.PasteboardType, data: Data)],
        onRead: (@Sendable (NSPasteboard.PasteboardType) -> Void)? = nil
    ) {
        self.types = representations.map(\.type)
        self.bytes = Dictionary(
            representations.map { ($0.type, $0.data) }, uniquingKeysWith: { _, latest in latest })
        self.onRead = onRead
    }

    /// Creates an item declaring `types` while serving only what `bytes` holds.
    public init(types: [NSPasteboard.PasteboardType], bytes: [NSPasteboard.PasteboardType: Data]) {
        self.types = types
        self.bytes = bytes
        onRead = nil
    }

    /// The bytes staged for `type`, or `nil` when the item vends none.
    public func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        onRead?(type)
        return bytes[type]
    }

    /// The bytes staged for `type` read as UTF-8, or `nil` when there are none.
    public func string(forType type: NSPasteboard.PasteboardType) -> String? {
        onRead?(type)
        return bytes[type].flatMap { String(data: $0, encoding: .utf8) }
    }
}
