import AppKit
import Foundation
import KernovaWire

/// One connection of one clipboard exchange, from the exchange's link being set until it is set again: what a
/// write serving the far side's offer arrived on, so a snapshot names by reference only what the destination of
/// its copy can fill.
public struct ClipboardConnectionID: Hashable, Sendable {
    private let raw = UUID()

    /// A connection no other names.
    public init() {}
}

/// What one pasteboard write of this process was made from. A snapshot of the pasteboard holding the write is
/// built from it, never read back through the write's own promises: a promise fired in-process holds the reading
/// thread for as long as its pull takes. What the write holds only as the far side's promise is named by
/// reference to the far side's offer when the snapshot's copy goes over the connection that offer arrived on
/// (``serving``), and otherwise pulled through the part's puller.
public struct ClipboardWriteSource: Sendable {
    /// The far side's offer or copy a write serves, and the connection it arrived on.
    public struct Serving: Sendable, Equatable {
        /// The offer's 16-byte token.
        public let token: Data
        /// The connection the offer arrived on.
        public let connection: ClipboardConnectionID

        /// The offer `token`, which arrived on `connection`.
        public init(token: Data, connection: ClipboardConnectionID) {
            self.token = token
            self.connection = connection
        }
    }

    /// What this side holds already of one representation a write placed.
    public enum Held: Sendable, Equatable {
        case bytes(Data)
        case file(URL)
    }

    /// One offer's items, as the write placed them.
    public struct Part: Sendable {
        /// The items, as the offer sent them.
        public let items: [OfferedItem]
        /// The offer marked its content concealed.
        public let concealed: Bool
        /// False when the write left `public.file-url` off every item.
        public let servingFileURLs: Bool
        /// What this side holds already of representation `representation` of item `item`; nil for one the write
        /// holds only as the far side's promise.
        public let held: @Sendable (_ item: Int, _ representation: Int) -> Held?
        /// Pulls what the write holds only as the far side's promise; nil for a part holding everything.
        public let puller: (any ClipboardItemPulling)?

        /// A part of `items`, its representations held as `held` says and the rest the far side's promise,
        /// pulled through `puller`.
        public init(
            items: [OfferedItem], concealed: Bool, servingFileURLs: Bool, puller: (any ClipboardItemPulling)?,
            held: @escaping @Sendable (_ item: Int, _ representation: Int) -> Held? = { _, _ in nil }
        ) {
            self.items = items
            self.concealed = concealed
            self.servingFileURLs = servingFileURLs
            self.puller = puller
            self.held = held
        }
    }

    /// The far side's offer or copy the write serves, whose promises back what no part holds, and the
    /// connection that made it; nil for one serving nothing of the far side's.
    public let serving: Serving?
    /// What the write placed, offer by offer.
    public let parts: [Part]

    /// A write of `parts`, serving `serving`.
    public init(serving: Serving?, parts: [Part]) {
        self.serving = serving
        self.parts = parts
    }
}

/// A write of this process standing on a pasteboard that promised something: what it serves and holds as data,
/// and what it was made from, for as long as the write stands. It ends at the first poll of its pasteboard's watch
/// to find the change count moved, or when ``end()`` comes first: its source goes, and its end runs. While it
/// stands, its observation of the watch holds it; everything else holds it weakly.
///
/// No provider callback gates the end. AppKit finishes with a provider once a reader has had every type it
/// promised, the write still standing (docs/research/2026-11-04-pasteboard-finished-with-data-provider.md), and
/// tells of another process's replacement only at this process's next use of the pasteboard, however late; a
/// provider fire still running when the write is replaced serves nothing, its bytes refused and the reader given
/// none (docs/research/2026-11-04-pasteboard-replacement-finish-waits-for-next-use.md).
@MainActor
final class ClipboardStandingWrite {
    /// The far side's offer or copy the write serves, which a retraction names.
    let servingOffer: Data?
    let data: [[(type: NSPasteboard.PasteboardType, bytes: Data)]]
    /// What the write was made from; nil once the write ended.
    private(set) var source: ClipboardWriteSource?
    /// Runs once, when the write ends.
    private var onEnded: (@MainActor () -> Void)?
    private var observation: ClipboardPasteboardWatch.Observation?

    init(
        source: ClipboardWriteSource, data: [[(type: NSPasteboard.PasteboardType, bytes: Data)]],
        onEnded: (@MainActor () -> Void)?
    ) {
        servingOffer = source.serving?.token
        self.source = source
        self.data = data
        self.onEnded = onEnded
    }

    /// Stands on `pasteboard`, which holds the write at its change count now, until that count moves.
    func stand(on pasteboard: any ClipboardWritePasteboard) {
        let changeCount = pasteboard.changeCount
        observation = ClipboardPasteboardWatch.observe(pasteboard, in: .standingWrites) { [self] in
            if pasteboard.changeCount != changeCount { end() }
        }
    }

    /// The write no longer stands.
    func end() {
        observation?.cancel()
        observation = nil
        source = nil
        let ended = onEnded
        onEnded = nil
        ended?()
    }
}

/// The latest write this process made to each pasteboard that promised something, and what it was made from
/// while it stands, whichever publisher made it: every publisher of one process records here, so a snapshot of
/// one VM's pasteboard never reads another VM's promise either.
@MainActor
public final class ClipboardWriteLedger {
    /// The process's ledger, matching the one `NSPasteboard.general` every write targets.
    public static let shared = ClipboardWriteLedger()

    private struct Entry {
        weak var pasteboard: AnyObject?
        let changeCount: Int
        weak var write: ClipboardStandingWrite?
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    /// An empty ledger; the process's own is ``shared``.
    public init() {}

    /// Records that `pasteboard`, at its change count now, holds `write`; nil when it holds no write of this
    /// process that promises anything.
    func record(_ write: ClipboardStandingWrite?, on pasteboard: any ClipboardWritePasteboard) {
        entries = entries.filter { $0.value.pasteboard != nil && $0.value.write != nil }
        let key = ObjectIdentifier(pasteboard)
        guard let write else {
            entries[key] = nil
            return
        }
        entries[key] = Entry(pasteboard: pasteboard, changeCount: pasteboard.changeCount, write: write)
    }

    /// What the write `pasteboard` holds was made from, while it holds a write of this process that nothing has
    /// replaced since.
    public func standingWrite(on pasteboard: any ClipboardReadPasteboard) -> ClipboardWriteSource? {
        guard let entry = entries[ObjectIdentifier(pasteboard)], entry.pasteboard === pasteboard,
            entry.changeCount == pasteboard.changeCount
        else { return nil }
        return entry.write?.source
    }
}

extension ClipboardWriteSource.Part {
    /// The part a write of `representations`, every one already on this side, is made from: the inline ones as
    /// one item of their bytes, and each file its own item.
    public init(holding representations: [ClipboardContent.Representation]) {
        var inline = OfferedItem()
        var inlineBytes: [Data] = []
        var items: [OfferedItem] = []
        var held: [[ClipboardWriteSource.Held]] = []
        for representation in representations {
            let type = TypeDescriptor(appleUTI: representation.uti)
            if let data = representation.inMemoryData, representation.filename.isEmpty {
                inline.representations.append(.make(type, .inline, size: data.count))
                inlineBytes.append(data)
            } else if case .file(let url, let byteCount, _) = representation.source {
                items.append(.with(.make(type, .file, size: byteCount, name: representation.filename)))
                held.append([.file(url)])
            }
        }
        if !inline.representations.isEmpty {
            items.insert(inline, at: 0)
            held.insert(inlineBytes.map(ClipboardWriteSource.Held.bytes), at: 0)
        }
        let table = held
        self.init(
            items: items, concealed: false, servingFileURLs: true, puller: nil,
            held: { item, representation in
                table.indices.contains(item) && table[item].indices.contains(representation)
                    ? table[item][representation] : nil
            })
    }
}
