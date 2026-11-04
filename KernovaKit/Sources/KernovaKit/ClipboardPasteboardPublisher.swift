import AppKit
import Foundation
import KernovaSynchronization

// MARK: - Seams

/// The write half of an `NSPasteboard`.
///
/// The seam a test writes through in place of `.general`, so no test touches
/// the user's clipboard, and whose write a test can make fail to exercise the
/// failure path.
public protocol ClipboardWritePasteboard: AnyObject {
    /// Monotonically increasing count of pasteboard changes — the value right
    /// after a write identifies that write to anything polling the same
    /// pasteboard.
    var changeCount: Int { get }

    /// Clears the pasteboard and applies `options` to the contents about to be
    /// written.
    @discardableResult
    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int

    /// Writes one pasteboard item per entry: its data now, and its promised
    /// types served lazily by its own provider when the OS asks for one.
    @discardableResult
    func writeItems(_ items: [ClipboardWriteItem]) -> Bool

    /// Empties the pasteboard.
    @discardableResult func clearContents() -> Int
}

/// One pasteboard item a write places: the types written as data now, and the
/// types its provider serves when a paste asks.
public struct ClipboardWriteItem: Sendable {
    /// Each type written now, with its bytes.
    public let data: [(type: NSPasteboard.PasteboardType, bytes: Data)]
    /// The types `provider` serves.
    public let promised: [NSPasteboard.PasteboardType]
    /// Serves `promised`; nil when the item promises nothing.
    public let provider: (any NSPasteboardItemDataProvider & Sendable)?

    /// An item of `data` now and `promised` served by `provider`.
    public init(
        data: [(type: NSPasteboard.PasteboardType, bytes: Data)] = [], promised: [NSPasteboard.PasteboardType],
        provider: (any NSPasteboardItemDataProvider & Sendable)?
    ) {
        self.data = data
        self.promised = promised
        self.provider = provider
    }
}

extension NSPasteboard: ClipboardWritePasteboard {
    /// Writes one `NSPasteboardItem` per entry, its data set now and its
    /// promised types served by the entry's own data provider.
    public func writeItems(_ items: [ClipboardWriteItem]) -> Bool {
        writeObjects(
            items.map { entry in
                let item = NSPasteboardItem()
                for (type, bytes) in entry.data { item.setData(bytes, forType: type) }
                if let provider = entry.provider, !entry.promised.isEmpty {
                    item.setDataProvider(provider, forTypes: entry.promised)
                }
                return item
            })
    }
}

/// Serves a promised representation's bytes when a paste asks for it.
///
/// Both calls run inside the pasteboard server's `provideData` callback, on
/// whichever thread it fires on.
public protocol ClipboardPromiseServing: AnyObject, Sendable {
    /// Resolves the pasteboard `.fileURL` for a promised rep, or `nil` when
    /// nothing can be served. Safe to call on the main thread even though it
    /// blocks.
    func serveFileURL(generation: UInt64, repIndex: Int) -> URL?

    /// Resolves an inline pasteboard flavor's bytes for a promised rep, or `nil`
    /// when nothing can be served. Safe to call on the main thread even though
    /// it blocks.
    func serveData(generation: UInt64, repIndex: Int, uti: String) -> Data?
}

/// What withdrawing a write's promises left on the pasteboard.
public enum ClipboardRetraction: Equatable, Sendable {
    /// Nothing: the write held nothing but promises.
    case cleared
    /// What the write held as data, written again alone.
    case keptData
}

// MARK: - Publisher

/// The one place a clipboard publication reaches a pasteboard, on either side of
/// the wire.
///
/// Every item is promised through a ``LazyClipboardDataProvider`` handed to a
/// provider registry on a successful write, so a paste can land long after the
/// connection — or the window, or the VM — that offered it is gone.
@MainActor
public final class ClipboardPasteboardPublisher {
    /// One pasteboard item to write: the types written as data now, the types
    /// it promises, by uniform type identifier, and a closure that lazily
    /// serves the bytes for each promised type.
    public struct ItemSpec: Sendable {
        /// The type identifier an item promises a file URL under.
        public static let fileURLType = NSPasteboard.PasteboardType.fileURL.rawValue

        /// Each type identifier written as data now, with its bytes.
        public let data: [(type: String, bytes: Data)]

        /// The type identifiers this item promises.
        public let types: [String]

        /// Produces the bytes for a requested type identifier, or `nil` to leave
        /// it empty.
        public let provide: @Sendable (String) -> Data?

        /// Creates one item: `data` written now, and `types` promised.
        public init(
            data: [(type: String, bytes: Data)] = [], types: [String],
            provide: @escaping @Sendable (String) -> Data?
        ) {
            self.data = data
            self.types = types
            self.provide = provide
        }
    }

    /// The pasteboard every write lands on.
    private let pasteboard: any ClipboardWritePasteboard

    /// Process-lifetime owner of the lazy data providers a write promises.
    private let providerRegistry: LazyClipboardProviderRegistry

    /// Where each write records what it was made from, for a snapshot of the pasteboard holding it.
    private let ledger: ClipboardWriteLedger

    /// Whether every item a write places carries ``ClipboardSnapshotPolicy/writeMarkerUTI``.
    private let marksWrites: Bool

    /// The pasteboard's `changeCount` right after the most recent write — a
    /// retraction's clear included — or `nil` before any write.
    ///
    /// Recorded whether or not the write succeeded: a failed one still cleared
    /// the pasteboard and bumped the count, and that change must never read as
    /// the user's own copy to something polling the same pasteboard.
    public private(set) var lastWriteChangeCount: Int?

    /// The pasteboard's change count right after the most recent write it took, retractions included; nil
    /// before one, or after a write that failed, which left the prepare's empty pasteboard behind.
    private var heldChangeCount: Int?

    /// The most recent write the pasteboard took while that write still promises something: held by the
    /// write's providers alone, so it, its source and its data go once the pasteboard has finished with every
    /// one of them. Only a write serving an offer can be stranded by that offer's end, and
    /// ``retractWrite(servingOffer:)`` retracts it by naming that offer, so no other offer's end reaches it.
    private weak var standing: ClipboardStandingWrite?

    /// Creates a publisher over `pasteboard`, recording each write in `ledger`. `marksWrites` marks every item
    /// it writes (``ClipboardSnapshotPolicy/writeMarkerUTI``), for ``holdsMarkedWrite(_:)``.
    public init(
        pasteboard: any ClipboardWritePasteboard,
        providerRegistry: LazyClipboardProviderRegistry = .shared,
        ledger: ClipboardWriteLedger = .shared,
        marksWrites: Bool = false
    ) {
        self.pasteboard = pasteboard
        self.providerRegistry = providerRegistry
        self.ledger = ledger
        self.marksWrites = marksWrites
    }

    /// Whether `pasteboard` holds a write of a publisher that marks its writes — this run's, or an earlier
    /// one's — read from its types alone.
    public static func holdsMarkedWrite(_ pasteboard: any ClipboardReadPasteboard) -> Bool {
        let marker = NSPasteboard.PasteboardType(ClipboardSnapshotPolicy.writeMarkerUTI)
        return pasteboard.items.contains { $0.types.contains(marker) }
    }

    /// Writes `specs`, made from `source`, reporting whether the pasteboard took them: each item's data now, its
    /// promised types served lazily.
    ///
    /// The write serves `source`'s offer, the one ``retractWrite(servingOffer:)`` withdraws it for; nil for a
    /// write that serves from what this side holds. `source` and what the write holds as data live exactly as
    /// long as the pasteboard needs the write's providers: they hold them, and nothing else does. `onReleased`
    /// runs once the pasteboard has finished with every provider the write promised through, which is when
    /// nothing can ask the offer for more; a write that promises nothing, or fails, never runs it.
    @discardableResult
    public func write(
        _ specs: [ItemSpec], source: ClipboardWriteSource, onReleased: (@MainActor @Sendable () -> Void)? = nil
    ) -> Bool {
        // Captures the registry, not `self`, so a provider's lifetime is
        // decoupled from this object.
        let registry = providerRegistry
        let promising = specs.filter { !$0.types.isEmpty }.count
        let unfinished = Locked(promising)
        var providers: [LazyClipboardDataProvider] = []
        let marker = marksWrites ? [(type: ClipboardSnapshotPolicy.writeMarkerUTI, bytes: Data())] : []
        let data = specs.map { spec in
            (spec.data + marker).compactMap { type, bytes -> (type: NSPasteboard.PasteboardType, bytes: Data)? in
                Self.screened(bytes, servedAs: type).map { (NSPasteboard.PasteboardType(type), $0) }
            }
        }
        let record = ClipboardStandingWrite(source: source, data: data)
        let items = zip(specs, data).map { spec, data -> ClipboardWriteItem in
            guard !spec.types.isEmpty else { return ClipboardWriteItem(data: data, promised: [], provider: nil) }
            let provide = spec.provide
            let provider = LazyClipboardDataProvider(
                provide: { Self.screened(provide($0.rawValue), servedAs: $0.rawValue) },
                onFinished: { provider in
                    // The providers are the record's only owners.
                    withExtendedLifetime(record) {}
                    registry.release(provider)
                    let last = unfinished.withLock { left -> Bool in
                        left -= 1
                        return left == 0
                    }
                    guard last, let onReleased else { return }
                    MainActorBridge.async { onReleased() }
                })
            providers.append(provider)
            return ClipboardWriteItem(
                data: data, promised: spec.types.map(NSPasteboard.PasteboardType.init(rawValue:)), provider: provider)
        }

        // `.currentHostOnly` keeps the write off the continuity advertiser,
        // which otherwise fetches a promised flavor ~100 ms after the write with
        // no paste and no Apple Account signed in
        // (docs/research/2026-08-17-promised-flavor-advertiser-fetch.md), so
        // nothing reads the bytes until a destination consumes them —
        // docs/CLIPBOARD.md, "Pay on consume". It is per-write state, reset by
        // every `prepareForNewContents`/`clearContents`, so it is applied at
        // this single publication choke point rather than once at init.
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        let written = pasteboard.writeItems(items)
        lastWriteChangeCount = pasteboard.changeCount
        // A failed write put no item on the pasteboard, so its providers are
        // never asked for anything, nothing has to hold them, and the empty
        // pasteboard it left is nobody's write.
        guard written else {
            heldChangeCount = nil
            standing = nil
            ledger.record(nil, on: pasteboard)
            return false
        }
        heldChangeCount = pasteboard.changeCount
        standing = record
        ledger.record(record, on: pasteboard)
        providerRegistry.retain(providers)
        return true
    }

    /// `data` when the pasteboard may serve it as `type`, else nil.
    ///
    /// Every write's bytes pass here, so a URL flavor naming a file on this
    /// machine is never served whichever path built the spec
    /// (``ClipboardSnapshotPolicy/admits(_:servedAs:)``). `ItemSpec.fileURLType`
    /// is exempt: it serves only the URL of a file this side landed, since the
    /// identity gate keeps every spelling of it off a peer's inline types.
    nonisolated private static func screened(_ data: Data?, servedAs type: String) -> Data? {
        guard let data, type != ItemSpec.fileURLType else { return data }
        return ClipboardSnapshotPolicy.admits(data, servedAs: type) ? data : nil
    }

    /// `true` while the pasteboard still holds this publisher's most recent
    /// successful write — nothing (the user included) has replaced it since.
    public var holdsLastWrite: Bool {
        heldChangeCount == pasteboard.changeCount
    }

    /// Withdraws the promises of this publisher's most recent write when the pasteboard still holds it and it
    /// serves the offer `token`: what it wrote as data is written again alone, and the pasteboard is cleared
    /// when nothing of that remains. Nil when nothing was withdrawn.
    ///
    /// A pasteboard the user has written over since is theirs and is left untouched, as is a write serving
    /// another offer, or none, and one whose every promise the pasteboard has finished with.
    @discardableResult
    public func retractWrite(servingOffer token: Data) -> ClipboardRetraction? {
        guard let held = standing, held.source.servingOffer == token, heldChangeCount == pasteboard.changeCount
        else { return nil }
        let markers: Set<NSPasteboard.PasteboardType> = [
            .init(ClipboardSnapshotPolicy.concealedMarkerUTI), .init(ClipboardSnapshotPolicy.writeMarkerUTI),
        ]
        let kept = held.data.filter { $0.contains { !markers.contains($0.type) } }
        guard !kept.isEmpty else {
            clear()
            return .cleared
        }
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        let written = pasteboard.writeItems(kept.map { ClipboardWriteItem(data: $0, promised: [], provider: nil) })
        lastWriteChangeCount = pasteboard.changeCount
        // What is written again is data alone, which the pasteboard serves itself: nothing holds a record of it.
        standing = nil
        ledger.record(nil, on: pasteboard)
        guard written else {
            heldChangeCount = nil
            return .cleared
        }
        heldChangeCount = pasteboard.changeCount
        return .keptData
    }

    /// Empties the pasteboard, whatever it holds, as this publisher's own write.
    public func clear() {
        pasteboard.clearContents()
        lastWriteChangeCount = pasteboard.changeCount
        heldChangeCount = nil
        standing = nil
        ledger.record(nil, on: pasteboard)
    }

    // MARK: - Planning

    /// The item specs promising `plan`'s types, every one of them backed by
    /// `generation`'s representations.
    nonisolated public static func specs(
        for plan: ClipboardPasteboardItemPlan, generation: UInt64,
        serve: any ClipboardPromiseServing
    ) -> [ItemSpec] {
        specs(for: plan, serve: serve) { promised in
            (generation: generation, repIndex: promised.representationIndex)
        }
    }

    /// The item specs promising `plan`'s types, each addressed to the offer
    /// coordinates `source` resolves it to and served by `serve` at paste time.
    ///
    /// A type `source` maps to `nil` is left off its item, and an item left with
    /// no type at all is dropped — a paste then finds no flavor to fire rather
    /// than firing one that serves nothing. Each closure holds `serve` strongly:
    /// the pasteboard can ask for a promised flavor long after the connection
    /// that offered it is gone, and a representation already pulled is still
    /// pastable then.
    nonisolated public static func specs(
        for plan: ClipboardPasteboardItemPlan, serve: any ClipboardPromiseServing,
        source: (ClipboardPasteboardItemPlan.PromisedType) -> (generation: UInt64, repIndex: Int)?
    ) -> [ItemSpec] {
        plan.items.compactMap { item -> ItemSpec? in
            var types: [String] = []
            var routes: [String: Route] = [:]
            for promised in item.types {
                guard let coordinate = source(promised) else { continue }
                let type = promised.isFileURL ? ItemSpec.fileURLType : promised.uti
                types.append(type)
                routes[type] = Route(
                    generation: coordinate.generation, repIndex: coordinate.repIndex,
                    uti: promised.uti, isFileURL: promised.isFileURL)
            }
            guard !types.isEmpty else { return nil }
            // Snapshot to a `let` so the @Sendable closure captures an immutable
            // map.
            let itemRoutes = routes
            return ItemSpec(types: types) { type in
                guard let route = itemRoutes[type] else { return nil }
                guard route.isFileURL else {
                    return serve.serveData(
                        generation: route.generation, repIndex: route.repIndex, uti: route.uti)
                }
                return serve.serveFileURL(generation: route.generation, repIndex: route.repIndex)
                    .map { Data($0.absoluteString.utf8) }
            }
        }
    }

    /// Where one promised type's bytes come from.
    private struct Route: Sendable {
        let generation: UInt64
        let repIndex: Int
        let uti: String
        let isFileURL: Bool
    }
}
