import AppKit
import Foundation

// MARK: - Seams

/// The write half of an `NSPasteboard`.
///
/// `NSPasteboard` is a class cluster with no public initializer and cannot be
/// subclassed, so a real one's write can never be made to fail; this is the seam
/// a test substitutes to exercise the failure path.
public protocol ClipboardWritePasteboard: AnyObject {
    /// Monotonically increasing count of pasteboard changes — the value right
    /// after a write identifies that write to anything polling the same
    /// pasteboard.
    var changeCount: Int { get }

    /// Clears the pasteboard and applies `options` to the contents about to be
    /// written.
    @discardableResult
    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int

    /// Writes one pasteboard item per entry, each **promising** its types lazily
    /// served by its own `provider` when the OS asks for one.
    @discardableResult
    func writeItems(
        _ items: [(types: [NSPasteboard.PasteboardType], provider: NSPasteboardItemDataProvider)]
    ) -> Bool

    /// Empties the pasteboard.
    @discardableResult func clearContents() -> Int
}

extension NSPasteboard: ClipboardWritePasteboard {
    /// Writes one `NSPasteboardItem` per entry, its types promised by the
    /// entry's own data provider.
    public func writeItems(
        _ items: [(types: [NSPasteboard.PasteboardType], provider: NSPasteboardItemDataProvider)]
    ) -> Bool {
        writeObjects(
            items.map { entry in
                let item = NSPasteboardItem()
                item.setDataProvider(entry.provider, forTypes: entry.types)
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

// MARK: - Publisher

/// The one place a clipboard publication reaches a pasteboard, on either side of
/// the wire.
///
/// Every item is promised through a ``LazyClipboardDataProvider`` handed to a
/// provider registry on a successful write, so a paste can land long after the
/// connection — or the window, or the VM — that offered it is gone.
@MainActor
public final class ClipboardPasteboardPublisher {
    /// One pasteboard item to write: the types it promises and a closure that
    /// lazily serves the bytes for each requested type.
    public struct ItemSpec: Sendable {
        /// The types this item promises.
        public let types: [NSPasteboard.PasteboardType]

        /// Produces the bytes for a requested type, or `nil` to leave it empty.
        public let provide: @Sendable (NSPasteboard.PasteboardType) -> Data?

        /// Creates one item's promise.
        public init(
            types: [NSPasteboard.PasteboardType],
            provide: @escaping @Sendable (NSPasteboard.PasteboardType) -> Data?
        ) {
            self.types = types
            self.provide = provide
        }
    }

    /// The pasteboard every write lands on.
    ///
    /// `nonisolated(unsafe)` only so an owner built off the main actor can
    /// construct one, as the guest agent does; every use of it below is
    /// main-actor isolated.
    nonisolated(unsafe) private let pasteboard: any ClipboardWritePasteboard

    /// Process-lifetime owner of the lazy data providers a write promises.
    nonisolated private let providerRegistry: LazyClipboardProviderRegistry

    /// The pasteboard's `changeCount` right after the most recent write, or `nil`
    /// before any write and after a retraction.
    ///
    /// Recorded whether or not the write succeeded: a failed one still cleared
    /// the pasteboard and bumped the count, and that change must never read as
    /// the user's own copy to something polling the same pasteboard.
    public private(set) var lastWriteChangeCount: Int?

    /// Whether the most recent write carried promised (offer-addressed) items.
    ///
    /// Those are the only kind a supersession can strand, and so the only kind
    /// ``retractPromisedWrite()`` retracts — a fully resolved write serves from
    /// local staging and survives the offer behind it moving on.
    private var lastWriteWasPromised = false

    /// Creates a publisher over `pasteboard`.
    ///
    /// `nonisolated` so an owner built off the main actor can create one; every
    /// method on it is still main-actor isolated.
    nonisolated public init(
        pasteboard: any ClipboardWritePasteboard,
        providerRegistry: LazyClipboardProviderRegistry = .shared
    ) {
        self.pasteboard = pasteboard
        self.providerRegistry = providerRegistry
    }

    /// Writes `specs` as lazily promised pasteboard items, reporting whether the
    /// pasteboard took them.
    ///
    /// `promised` marks a publication addressed by offer coordinates — the only
    /// kind ``retractPromisedWrite()`` can withdraw.
    @discardableResult
    public func write(_ specs: [ItemSpec], promised: Bool) -> Bool {
        // Captures the registry, not `self`, so a provider's lifetime is
        // decoupled from this object.
        let registry = providerRegistry
        var providers: [LazyClipboardDataProvider] = []
        let items = specs.map {
            spec -> (types: [NSPasteboard.PasteboardType], provider: NSPasteboardItemDataProvider) in
            let provider = LazyClipboardDataProvider(
                provide: spec.provide,
                onFinished: { provider in registry.release(provider) })
            providers.append(provider)
            return (types: spec.types, provider: provider)
        }

        // `.currentHostOnly` (docs/CLIPBOARD.md §3, §10) is per-write state, reset
        // by every `prepareForNewContents`/`clearContents`, so it is applied at
        // this single publication choke point rather than once at init.
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        let written = pasteboard.writeItems(items)
        lastWriteChangeCount = pasteboard.changeCount
        lastWriteWasPromised = promised
        // A failed write put no item on the pasteboard, so its providers are
        // never asked for anything and nothing has to hold them.
        guard written else { return false }
        providerRegistry.retain(providers)
        return true
    }

    /// `true` while the pasteboard still holds this publisher's most recent write
    /// — nothing (the user included) has replaced it since.
    public var holdsLastWrite: Bool {
        lastWriteChangeCount != nil && lastWriteChangeCount == pasteboard.changeCount
    }

    /// Clears the pasteboard when it still holds this publisher's most recent
    /// *promised* write, reporting whether it did.
    ///
    /// A pasteboard the user has written over since is theirs and is left
    /// untouched, as is a fully resolved write — it keeps serving from local
    /// staging.
    @discardableResult
    public func retractPromisedWrite() -> Bool {
        guard lastWriteWasPromised, holdsLastWrite else { return false }
        pasteboard.clearContents()
        lastWriteChangeCount = nil
        lastWriteWasPromised = false
        return true
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
            var types: [NSPasteboard.PasteboardType] = []
            var routes: [NSPasteboard.PasteboardType: Route] = [:]
            for promised in item.types {
                guard let coordinate = source(promised) else { continue }
                let type: NSPasteboard.PasteboardType =
                    promised.isFileURL ? .fileURL : .init(promised.uti)
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
