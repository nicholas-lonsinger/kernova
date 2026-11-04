import Foundation
import KernovaWire

/// What one pasteboard write of this process was made from. A snapshot of the pasteboard holding the write is
/// built from it, never read back through the write's own promises: a promise fired in-process holds the reading
/// thread for as long as its pull takes.
public struct ClipboardWriteSource: Sendable {
    /// What this side holds already of one representation a write placed.
    public enum Held: Sendable {
        case bytes(Data)
        case file(URL)
    }

    /// One offer's items, as the write placed them.
    public struct Part: Sendable {
        public let items: [OfferedItem]
        public let concealed: Bool
        /// False when the write left `public.file-url` off every item.
        public let servingFileURLs: Bool
        /// What this side holds already of representation `representation` of item `item`; nil for one only
        /// `puller` can bring.
        public let held: @Sendable (_ item: Int, _ representation: Int) -> Held?
        /// Pulls what `held` does not hold; nil when it holds everything.
        public let puller: (any ClipboardItemPulling)?

        public init(
            items: [OfferedItem], concealed: Bool, servingFileURLs: Bool,
            held: @escaping @Sendable (_ item: Int, _ representation: Int) -> Held? = { _, _ in nil },
            puller: (any ClipboardItemPulling)?
        ) {
            self.items = items
            self.concealed = concealed
            self.servingFileURLs = servingFileURLs
            self.held = held
            self.puller = puller
        }
    }

    /// The far side's offer or copy the write serves; nil for one serving nothing of the far side's.
    public let servingOffer: Data?
    public let parts: [Part]

    public init(servingOffer: Data?, parts: [Part]) {
        self.servingOffer = servingOffer
        self.parts = parts
    }

    /// A write that placed nothing: a clear.
    public static let nothing = ClipboardWriteSource(servingOffer: nil, parts: [])
}

/// The latest write this process made to each pasteboard, and what it was made from, whichever publisher made
/// it: every publisher of one process records here, so a snapshot of one VM's pasteboard never reads another
/// VM's promise either.
@MainActor
public final class ClipboardWriteLedger {
    /// The process's ledger, matching the one `NSPasteboard.general` every write targets.
    public static let shared = ClipboardWriteLedger()

    private struct Entry {
        weak var pasteboard: AnyObject?
        let changeCount: Int
        let source: ClipboardWriteSource
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    public init() {}

    /// Records that `pasteboard`, at its change count now, holds a write of `source`; nil when it holds no
    /// write of this process.
    func record(_ source: ClipboardWriteSource?, on pasteboard: any ClipboardWritePasteboard) {
        entries = entries.filter { $0.value.pasteboard != nil }
        let key = ObjectIdentifier(pasteboard)
        guard let source else {
            entries[key] = nil
            return
        }
        entries[key] = Entry(pasteboard: pasteboard, changeCount: pasteboard.changeCount, source: source)
    }

    /// What the write `pasteboard` holds was made from, while it holds a write of this process that nothing has
    /// replaced since.
    public func standingWrite(on pasteboard: any ClipboardReadPasteboard) -> ClipboardWriteSource? {
        guard let entry = entries[ObjectIdentifier(pasteboard)], entry.pasteboard === pasteboard,
            entry.changeCount == pasteboard.changeCount
        else { return nil }
        return entry.source
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
            },
            puller: nil)
    }
}
