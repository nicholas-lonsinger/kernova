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

    /// The bytes item `index` holds as `type` now, or nil. Asked only for a type a provider of this process
    /// already provided, which the pasteboard holds as data, so no provider is asked again.
    func data(forType type: NSPasteboard.PasteboardType, itemAt index: Int) -> Data?
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
    /// promised types served by the entry's own data provider. False when the
    /// pasteboard refused any of it: an item's data or provider, or the write.
    /// On macOS 27.2 a write of 300 MB of one type returned false and left the
    /// pasteboard empty, where 260 MB was taken (2026-11-04, a named pasteboard).
    public func writeItems(_ items: [ClipboardWriteItem]) -> Bool {
        var refused = false
        let objects = items.map { entry in
            let item = NSPasteboardItem()
            for (type, bytes) in entry.data where !item.setData(bytes, forType: type) {
                refused = true
            }
            if let provider = entry.provider, !entry.promised.isEmpty,
                !item.setDataProvider(provider, forTypes: entry.promised)
            {
                refused = true
            }
            return item
        }
        return !refused && writeObjects(objects)
    }

    /// The bytes item `index` holds as `type`, or nil when it holds none or there is no such item.
    public func data(forType type: NSPasteboard.PasteboardType, itemAt index: Int) -> Data? {
        guard let items = pasteboardItems, items.indices.contains(index) else { return nil }
        return items[index].data(forType: type)
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

/// Which promises of a write a retraction withdraws. What the write holds as data always stays.
public enum ClipboardWithdrawal: Equatable, Sendable {
    /// Each promised type no reader has had, while what a paste had stays as data: the offer's carriage ended —
    /// passthrough stopped, the link ended, what a copy's files came from ended — and the far side may hold it
    /// still.
    case unread
    /// Every promise, read or not: the far side's clipboard moved on, and nothing of what it promised stays.
    case everyPromise
}

/// What withdrawing a write's promises left on the pasteboard.
public enum ClipboardRetraction: Equatable, Sendable {
    /// Nothing: the write held nothing but promises it withdrew.
    case cleared
    /// What the write held as data, and what a paste had of what it promised, written again alone; the rest of
    /// its promises withdrawn.
    case keptData
    /// Everything: a paste had every type the write promised, so all of it is written again as data, and
    /// nothing was withdrawn.
    case keptEverything
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

    /// The most recent write the pasteboard took that promised something, while it stands: a write, a clear or
    /// a retraction of this publisher's ends it, and so does anything else replacing it, which the write hears
    /// through the pasteboard's watch. Only a write serving an offer can be stranded by that offer's end, and
    /// ``retractWrite(servingOffer:withdrawing:)`` retracts it by naming that offer, so no other offer's end reaches it.
    private weak var standing: ClipboardStandingWrite?

    /// Hears each paste whose promised bytes the pasteboard refused to take, so the paste got nothing.
    public var onPasteRefused: (@MainActor () -> Void)?

    /// Creates a publisher over `pasteboard`, recording each write in `ledger`.
    public init(
        pasteboard: any ClipboardWritePasteboard,
        providerRegistry: LazyClipboardProviderRegistry = .shared,
        ledger: ClipboardWriteLedger = .shared
    ) {
        self.pasteboard = pasteboard
        self.providerRegistry = providerRegistry
        self.ledger = ledger
    }

    /// Writes `specs`, made from `source`, reporting whether the pasteboard took them: each item's data now, its
    /// promised types served lazily.
    ///
    /// The write serves `source`'s offer, the one ``retractWrite(servingOffer:withdrawing:)`` withdraws it for; nil for a
    /// write that serves from what this side holds. Its record (``ClipboardStandingWrite``), `source` with it,
    /// lives as long as the write stands. `onReleased` runs once the write no longer stands, which is when no
    /// paste can be served from the offer any more; a paste of every promised type leaves the write standing, so
    /// it runs nothing. A write that promises nothing, or fails, never runs it.
    @discardableResult
    public func write(
        _ specs: [ItemSpec], source: ClipboardWriteSource, onReleased: (@MainActor @Sendable () -> Void)? = nil
    ) -> Bool {
        // Captures the registry, not `self`, so a provider's lifetime is
        // decoupled from this object.
        let registry = providerRegistry
        var providers: [LazyClipboardDataProvider] = []
        let data = specs.map { spec in
            spec.data.compactMap { type, bytes -> (type: NSPasteboard.PasteboardType, bytes: Data)? in
                Self.screened(bytes, servedAs: type).map { (NSPasteboard.PasteboardType(type), $0) }
            }
        }
        let promised = specs.map { $0.types.map(NSPasteboard.PasteboardType.init(rawValue:)) }
        let record = ClipboardStandingWrite(source: source, data: data, promised: promised, onEnded: onReleased)
        let read = record.read
        let items = zip(specs, data).enumerated().map { index, entry -> ClipboardWriteItem in
            let (spec, data) = entry
            guard !spec.types.isEmpty else { return ClipboardWriteItem(data: data, promised: [], provider: nil) }
            let provide = spec.provide
            let provider = LazyClipboardDataProvider(
                provide: { Self.screened(provide($0.rawValue), servedAs: $0.rawValue) },
                onRefused: { [weak self] _ in MainActorBridge.async { self?.onPasteRefused?() } },
                onProvided: { read.provided($0, item: index) },
                onFinished: { registry.release($0) })
            providers.append(provider)
            return ClipboardWriteItem(data: data, promised: promised[index], provider: provider)
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
        endStanding()
        let written = pasteboard.writeItems(items)
        lastWriteChangeCount = pasteboard.changeCount
        // A failed write put no item on the pasteboard, so its providers are
        // never asked for anything, nothing has to hold them, and the empty
        // pasteboard it left is nobody's write.
        guard written else {
            heldChangeCount = nil
            ledger.record(nil, on: pasteboard)
            return false
        }
        heldChangeCount = pasteboard.changeCount
        let promises = providers.isEmpty ? nil : record
        promises?.stand(on: pasteboard)
        standing = promises
        ledger.record(promises, on: pasteboard)
        providerRegistry.retain(providers)
        return true
    }

    /// The standing write no longer stands: this publisher's next write, clear or retraction replaced it.
    private func endStanding() {
        standing?.end()
        standing = nil
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

    /// Withdraws `withdrawal`'s promises of this publisher's most recent write when the pasteboard still holds
    /// it and it serves the offer `token`: what it wrote as data, and with ``ClipboardWithdrawal/unread`` what a
    /// paste had of what it promised, is written again alone, and the pasteboard is cleared when nothing of that
    /// remains. Nil when the write no longer stands there.
    ///
    /// A pasteboard the user has written over since is theirs and is left untouched, as is a write serving
    /// another offer, or none. What a paste had is read back from the pasteboard, which holds each provided type
    /// as data, so the write keeps no second copy of it while it stands.
    @discardableResult
    public func retractWrite(
        servingOffer token: Data, withdrawing withdrawal: ClipboardWithdrawal
    ) -> ClipboardRetraction? {
        guard let held = standing, held.servingOffer == token, heldChangeCount == pasteboard.changeCount
        else { return nil }
        let read =
            withdrawal == .unread ? held.read.data(on: pasteboard, items: held.data.count) : held.data.map { _ in [] }
        let concealed = NSPasteboard.PasteboardType(ClipboardSnapshotPolicy.concealedMarkerUTI)
        let kept = zip(held.data, read).map { $0 + $1 }.filter { $0.contains { $0.type != concealed } }
        guard !kept.isEmpty else {
            clear()
            return .cleared
        }
        let withdrewNothing = zip(held.promised, read).allSatisfy { $0.count == $1.count }
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        // What is written again is data alone, which the pasteboard serves itself: nothing holds a record of it.
        endStanding()
        let written = pasteboard.writeItems(kept.map { ClipboardWriteItem(data: $0, promised: [], provider: nil) })
        lastWriteChangeCount = pasteboard.changeCount
        ledger.record(nil, on: pasteboard)
        guard written else {
            heldChangeCount = nil
            return .cleared
        }
        heldChangeCount = pasteboard.changeCount
        return withdrewNothing ? .keptEverything : .keptData
    }

    /// Empties the pasteboard, whatever it holds, as this publisher's own write.
    public func clear() {
        pasteboard.clearContents()
        endStanding()
        lastWriteChangeCount = pasteboard.changeCount
        heldChangeCount = nil
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
