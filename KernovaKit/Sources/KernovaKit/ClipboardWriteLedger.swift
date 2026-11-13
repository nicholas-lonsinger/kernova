import AppKit
import Foundation
import KernovaLogging
import KernovaSynchronization
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

/// A write of this process standing on a pasteboard: what it serves, which types each item holds as data, and,
/// for one that promised something, what it was made from, for as long as the write stands. It ends at the first
/// poll of its pasteboard's watch to find the change count moved, or when ``end()`` comes first: its source goes,
/// and its end runs, for one that is ``withdrawable``. While it stands, its observation of the watch holds it;
/// everything else holds it weakly.
///
/// It keeps types, never bytes: the pasteboard holds each type as data, so the write keeps no second copy of what
/// it wrote while it stands.
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
    /// Whether the end of the offer or copy the write serves withdraws from it: an item promises a type, which
    /// that end can serve no more, or is marked concealed, which lives only while the far side still holds it.
    let withdrawable: Bool
    /// The types each item was written with as data.
    let written: [[NSPasteboard.PasteboardType]]
    /// The types each item promises.
    let promised: [[NSPasteboard.PasteboardType]]
    /// Which promised types a reader has had.
    let read = ClipboardReadPromises()
    /// What the write was made from; nil once the write ended, and for one that promised nothing.
    private(set) var source: ClipboardWriteSource?
    /// The publisher that made the write, held while it stands, so whatever must withdraw from the write can.
    private(set) var publisher: ClipboardPasteboardPublisher?
    /// Runs once, when a ``withdrawable`` write ends.
    private var onEnded: (@MainActor @Sendable () -> Void)?
    private var observation: ClipboardPasteboardWatch.Observation?

    /// A write of `written` and `promised`, made from `source`, which `onEnded` hears end when it is
    /// ``withdrawable``.
    init(
        source: ClipboardWriteSource?, by publisher: ClipboardPasteboardPublisher,
        written: [[NSPasteboard.PasteboardType]], promised: [[NSPasteboard.PasteboardType]],
        onEnded: (@MainActor @Sendable () -> Void)?
    ) {
        let marker = NSPasteboard.PasteboardType(ClipboardSnapshotPolicy.concealedMarkerUTI)
        let promises = promised.contains { !$0.isEmpty }
        withdrawable = promises || written.contains { $0.contains(marker) }
        servingOffer = source?.serving?.token
        self.source = promises ? source : nil
        self.publisher = publisher
        self.written = written
        self.promised = promised
        self.onEnded = withdrawable ? onEnded : nil
    }

    /// Whether any item promises a type.
    var promisesSomething: Bool { promised.contains { !$0.isEmpty } }

    /// Stands on `pasteboard`, which holds the write at its change count now, until that count moves.
    func stand(on pasteboard: any ClipboardWritePasteboard) {
        let changeCount = pasteboard.changeCount
        observation = ClipboardPasteboardWatch.observe(pasteboard, in: .standingWrites) { [self] in
            if pasteboard.changeCount != changeCount { end() }
        }
    }

    /// What each item holds as data on `pasteboard`, which holds the write: its written types, then each promised
    /// type a reader had, in the order read.
    func held(on pasteboard: any ClipboardWritePasteboard) -> [[(type: NSPasteboard.PasteboardType, bytes: Data)]] {
        let read = read.data(on: pasteboard, items: written.count)
        return written.indices.map { item in Self.data(of: written[item], item: item, on: pasteboard) + read[item] }
    }

    /// What of the write stays on `pasteboard`, which holds it, once `withdrawal` withdraws its promises
    /// (``ClipboardWithdrawal``) and every item `goesWhole` picks out by what it holds goes whole: each item's types
    /// to write again as data; and whether that is all of it, nothing withdrawn.
    func remains(
        after withdrawal: ClipboardWithdrawal, on pasteboard: any ClipboardWritePasteboard,
        goesWhole: ([(type: NSPasteboard.PasteboardType, bytes: Data)]) -> Bool = { _ in false }
    ) -> (items: [[(type: NSPasteboard.PasteboardType, bytes: Data)]], whole: Bool) {
        let marker = NSPasteboard.PasteboardType(ClipboardSnapshotPolicy.concealedMarkerUTI)
        let read = read.data(on: pasteboard, items: written.count)
        var whole = true
        let items = written.indices.compactMap { item -> [(type: NSPasteboard.PasteboardType, bytes: Data)]? in
            guard !written[item].contains(marker) else {
                whole = false
                return nil
            }
            let kept = withdrawal == .unread ? read[item] : []
            let withdrawn = promised[item].filter { type in !kept.contains { $0.type == type } }
            whole = whole && withdrawn.isEmpty
            guard !withdrawn.contains(where: { PasteboardTypeIdentity($0.rawValue).isFileReference }) else {
                return nil
            }
            let data = Self.data(of: written[item], item: item, on: pasteboard) + kept
            guard !goesWhole(data) else {
                whole = false
                return nil
            }
            return data.isEmpty ? nil : data
        }
        return (items, whole)
    }

    /// What each item was written with as data, read back from `pasteboard`, which holds the write.
    func written(on pasteboard: any ClipboardWritePasteboard) -> [[(type: NSPasteboard.PasteboardType, bytes: Data)]] {
        written.indices.map { item in Self.data(of: written[item], item: item, on: pasteboard) }
    }

    /// Takes the write's end away for a write of the same promises that replaces it: this write's end then runs
    /// nothing, and the caller hands what it returns to the replacement.
    func handOffEnd() -> (@MainActor @Sendable () -> Void)? {
        defer { onEnded = nil }
        return onEnded
    }

    /// The bytes item `item` holds on `pasteboard` as each of `types`, which it holds as data.
    private static func data(
        of types: [NSPasteboard.PasteboardType], item: Int, on pasteboard: any ClipboardWritePasteboard
    ) -> [(type: NSPasteboard.PasteboardType, bytes: Data)] {
        types.compactMap { type in pasteboard.data(forType: type, itemAt: item).map { (type, $0) } }
    }

    /// The write no longer stands.
    func end() {
        observation?.cancel()
        observation = nil
        source = nil
        publisher = nil
        let ended = onEnded
        onEnded = nil
        ended?()
    }
}

/// The promised types of one write a reader has had, item by item: once a provider's bytes are taken, the
/// pasteboard holds them as data while the write stands, so a reader has them whatever becomes of the offer.
/// Providers record here on whatever thread they fire.
final class ClipboardReadPromises: Sendable {
    private let types = Locked<[Int: [NSPasteboard.PasteboardType]]>([:])

    /// The pasteboard took a provider's bytes of `type` for item `item`.
    func provided(_ type: NSPasteboard.PasteboardType, item: Int) {
        types.withLock { types in
            if types[item]?.contains(type) != true { types[item, default: []].append(type) }
        }
    }

    /// What `pasteboard` holds of each read type, item by item for `count` items, in the order they were read.
    func data(
        on pasteboard: any ClipboardWritePasteboard, items count: Int
    ) -> [[(type: NSPasteboard.PasteboardType, bytes: Data)]] {
        let read = types.withLock { $0 }
        return (0..<count).map { item in
            (read[item] ?? []).compactMap { type in
                pasteboard.data(forType: type, itemAt: item).map { (type, $0) }
            }
        }
    }
}

/// The latest write this process made to each pasteboard, whichever publisher made it, and — while it stands, for
/// one that promised something — what it was made from: every publisher of one process records here, so a
/// snapshot of one VM's pasteboard never reads another VM's promise either, and a staged file's removal reaches
/// whichever write names it.
@MainActor
public final class ClipboardWriteLedger {
    /// The process's ledger, matching the one `NSPasteboard.general` every write targets.
    public nonisolated static let shared = ClipboardWriteLedger()

    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "ClipboardWriteLedger")

    private struct Entry {
        weak var pasteboard: AnyObject?
        let changeCount: Int
        weak var write: ClipboardStandingWrite?
        weak var publisher: ClipboardPasteboardPublisher?
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    /// An empty ledger; the process's own is ``shared``.
    public nonisolated init() {}

    /// Records that `publisher` wrote `pasteboard` last, which at its change count now holds `write`; nil when
    /// that write promises nothing, or failed.
    func record(
        _ write: ClipboardStandingWrite?, by publisher: ClipboardPasteboardPublisher,
        on pasteboard: any ClipboardWritePasteboard
    ) {
        entries = entries.filter { $0.value.pasteboard != nil && $0.value.publisher != nil }
        entries[ObjectIdentifier(pasteboard)] = Entry(
            pasteboard: pasteboard, changeCount: pasteboard.changeCount, write: write, publisher: publisher)
    }

    /// What the write `pasteboard` holds was made from, while it holds a write of this process that promised
    /// something and that nothing has replaced since.
    public func standingWrite(on pasteboard: any ClipboardReadPasteboard) -> ClipboardWriteSource? {
        guard let entry = entries[ObjectIdentifier(pasteboard)], entry.pasteboard === pasteboard,
            entry.changeCount == pasteboard.changeCount
        else { return nil }
        return entry.write?.source
    }

    /// Whether `pasteboard` still holds the latest write of this process on it.
    func holdsWrite(on pasteboard: AnyObject) -> Bool {
        guard let entry = entries[ObjectIdentifier(pasteboard)], entry.pasteboard === pasteboard else { return false }
        return entry.publisher?.holdsLastWrite == true
    }

    /// Withdraws, whole, every item of a write of this process that a pasteboard still holds and that names a file
    /// under `directories`, each through the publisher that wrote it
    /// (``ClipboardPasteboardPublisher/withdrawItems(namingFilesUnder:)``): those files are going.
    public func withdrawItems(namingFilesUnder directories: [URL]) {
        for publisher in entries.values.compactMap(\.publisher) {
            guard let retraction = publisher.withdrawItems(namingFilesUnder: directories) else { continue }
            Self.logger.log(
                .notice,
                "Withdrew the clipboard items naming staged files about to be removed\(retraction == .keptPart ? ", the rest kept" : "", privacy: .public)"
            )
        }
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
