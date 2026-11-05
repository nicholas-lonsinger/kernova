import AppKit
import Foundation
import KernovaWire

/// What one pasteboard write of this process was made from. A snapshot of the pasteboard holding the write is
/// built from it, never read back through the write's own promises: a promise fired in-process holds the reading
/// thread for as long as its pull takes. What the write holds only as the far side's promise is named by
/// reference to the far side's offer (``servingOffer``), never pulled.
public struct ClipboardWriteSource: Sendable {
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

        /// A part of `items`, its representations held as `held` says and the rest the far side's promise.
        public init(
            items: [OfferedItem], concealed: Bool, servingFileURLs: Bool,
            held: @escaping @Sendable (_ item: Int, _ representation: Int) -> Held? = { _, _ in nil }
        ) {
            self.items = items
            self.concealed = concealed
            self.servingFileURLs = servingFileURLs
            self.held = held
        }
    }

    /// The far side's offer or copy the write serves, whose promises back what no part holds; nil for one
    /// serving nothing of the far side's.
    public let servingOffer: Data?
    /// What the write placed, offer by offer.
    public let parts: [Part]

    /// A write of `parts`, serving `servingOffer`.
    public init(servingOffer: Data?, parts: [Part]) {
        self.servingOffer = servingOffer
        self.parts = parts
    }
}

/// A write of this process standing on a pasteboard that promised something: what it serves and holds as data,
/// for as long as the write stands, and what it was made from, only while a provider of it can still be asked.
/// The publisher that made it owns it until something replaces the write
/// (``ClipboardPasteboardPublisher/write(_:source:onReleased:)``); everything else holds it weakly. AppKit finishes
/// with a provider when anything replaces the write, and also once a reader has had every type that provider
/// promised while the write still stands (docs/research/2026-11-04-pasteboard-finished-with-data-provider.md):
/// once every provider is finished with the write standing, nothing of it is promised any more, so its source goes
/// and a snapshot reads the pasteboard's data, while a retraction still finds the record.
@MainActor
final class ClipboardStandingWrite {
    /// The far side's offer or copy the write serves, which a retraction names.
    let servingOffer: Data?
    let data: [[(type: NSPasteboard.PasteboardType, bytes: Data)]]
    /// What the write was made from; nil once no provider of it can be asked.
    private(set) var source: ClipboardWriteSource?

    init(source: ClipboardWriteSource, data: [[(type: NSPasteboard.PasteboardType, bytes: Data)]]) {
        servingOffer = source.servingOffer
        self.source = source
        self.data = data
    }

    /// Lets the source go: nothing can ask the write's providers for more.
    func dropSource() {
        source = nil
    }
}

/// The latest write this process made to each pasteboard that promised something, and what it was made from
/// while a provider of it can be asked, whichever publisher made it: every publisher of one process records here,
/// so a snapshot of one VM's pasteboard never reads another VM's promise either. A write with nothing left to
/// promise has no promise to read, so a snapshot reads its data from the pasteboard.
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
    /// replaced since and one of whose providers can still be asked.
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
            items: items, concealed: false, servingFileURLs: true,
            held: { item, representation in
                table.indices.contains(item) && table[item].indices.contains(representation)
                    ? table[item][representation] : nil
            })
    }
}
