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

    /// Creates an item declaring `types` while serving only what `bytes` holds, telling `onRead` of every read
    /// of one.
    public init(
        types: [NSPasteboard.PasteboardType], bytes: [NSPasteboard.PasteboardType: Data],
        onRead: (@Sendable (NSPasteboard.PasteboardType) -> Void)? = nil
    ) {
        self.types = types
        self.bytes = bytes
        self.onRead = onRead
    }

    /// The file URL the item's `public.file-url` names, if it names one.
    var fileURL: URL? {
        bytes[.fileURL].flatMap { URL(string: String(decoding: $0, as: UTF8.self)) }
    }

    /// This item, telling `heard` of every read of one of its types after whatever it told before.
    func alsoTelling(_ heard: @escaping @Sendable (NSPasteboard.PasteboardType) -> Void) -> FakePasteboardItem {
        let told = onRead
        return FakePasteboardItem(types: types, bytes: bytes) { type in
            told?(type)
            heard(type)
        }
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

/// In-memory `ClipboardReadPasteboard` a test stages a snapshot on directly.
public final class FakeReadPasteboard: ClipboardReadPasteboard, Sendable {
    private struct State: Sendable {
        var items: [FakePasteboardItem] = []
        var changeCount = 0
    }

    private let state = Locked(State())

    /// Creates an empty pasteboard double.
    public init() {}

    /// Monotonic change count, bumped by every staging call as a real
    /// pasteboard's is by every write.
    public var changeCount: Int { state.withLock { $0.changeCount } }

    /// The items currently staged, in order, each read of a file URL among them read into ``sandbox``.
    public var items: [any ClipboardPasteboardItemReading] {
        let (items, changeCount) = state.withLock { ($0.items, $0.changeCount) }
        let sandbox = sandbox
        return items.enumerated().map { index, item in
            guard let file = item.fileURL else { return item }
            return item.alsoTelling { type in
                guard type == .fileURL else { return }
                sandbox.read(fileURL: file, ofItem: index, at: changeCount)
            }
        }
    }

    /// None: no snapshot on this double carries a file promise.
    @MainActor public var filePromiseReceivers: [any FilePromiseReceiving] { [] }

    /// The grants reading this double's file URLs takes, as ``FakeSandbox/read(fileURL:ofItem:at:)`` says.
    public let sandbox = FakeSandbox()

    /// The grants ``sandbox`` counts.
    public var fileGrants: SandboxFileGrants { sandbox.fileGrants }

    /// Stages a single item, as one copy does, bumping the change count.
    public func setItem(_ representations: [(type: NSPasteboard.PasteboardType, data: Data)]) {
        setItems([FakePasteboardItem(representations)])
    }

    /// Stages several items, as a multi-select copy does, bumping the change
    /// count.
    public func setItems(_ items: [FakePasteboardItem]) {
        state.withLock { state in
            state.items = items
            state.changeCount += 1
        }
    }
}
