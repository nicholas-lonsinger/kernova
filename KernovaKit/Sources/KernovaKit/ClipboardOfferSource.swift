import AppKit
import Foundation
import KernovaFileTree
import KernovaSynchronization
import KernovaWire
import UniformTypeIdentifiers

/// What a pull of one offered representation is served from: the bytes of an
/// INLINE representation, or the file or folder a FILE or FOLDER one reads.
public enum ClipboardServedRepresentation: Equatable, Sendable {
    /// An INLINE representation's bytes.
    case bytes(Data)
    /// A FILE representation's regular file. Its own name is not the item's:
    /// the offer carries that.
    case file(URL)
    /// A FOLDER representation's directory. Its own name is not the item's.
    case folder(URL)
}

/// Why a representation cannot be served.
public enum ClipboardServeError: Error, Equatable, Sendable {
    /// What the offer was read from is gone: the pasteboard moved on, the
    /// file was removed, or the indexes name nothing. The wire's
    /// `ITEM_REPRESENTATION_UNAVAILABLE`.
    case unavailable
    /// The source is there and could not be read, or a promise's source failed
    /// to write it. The wire's `READ_FAILED`.
    case readFailed
}

/// One local offer: the items it sends, metadata only, and where each
/// representation's bytes come from when a peer pulls it.
///
/// Built by ``ClipboardPasteboardReader/readOffer(from:promises:promiseDestination:sizeOf:)``
/// or ``ClipboardPasteboardReader/readDropOffer(from:promises:sizeOf:)`` from a
/// pasteboard. No byte is read until ``serve(item:representation:)``.
@MainActor
public final class ClipboardOfferSource {
    /// Where one representation's bytes come from.
    enum Origin: Sendable {
        /// A type of a pasteboard item, read while the pasteboard still holds
        /// what was offered.
        case pasteboard(item: Int, type: String)
        /// Bytes already in memory.
        case bytes(Data)
        /// A file's bytes, served INLINE.
        case fileContents(URL)
        /// A regular file.
        case file(URL)
        /// A directory.
        case folder(URL)
        /// A file promise, by its index in ``ClipboardOfferSource/promises``,
        /// called in on its first pull.
        case promise(Int)
        /// A file a promise called in before the offer was read lands.
        case landing(Task<URL, any Error>)
        /// Bytes a copy served once, let go: its receiver pulls each representation once.
        case spent
        /// The receiver's own: what this side held only as its promise, which it fills itself.
        case reference
        /// Another connection's FILE or FOLDER, which a write of this process holds only as that connection's
        /// promise: pulled through `puller` when pulled, for as long as that offer lasts.
        case upstream(any ClipboardItemPulling, item: Int, representation: Int)
    }

    /// The items, in the order they are offered.
    public let items: [OfferedItem]
    /// The content is confidential: `org.nspasteboard.ConcealedType`.
    public let concealed: Bool

    private var origins: [[Origin]]
    private let pasteboard: (any ClipboardReadPasteboard)?
    /// The pasteboard change the offer was read at.
    let changeCount: Int
    private let promises: [any FilePromiseReceiving]
    private let promiseDestination: @MainActor () throws -> URL
    private var calledIn: [Int: Task<URL, any Error>] = [:]
    /// The staging this offer's files live in, which lives as long as the offer.
    private let leases: [ClipboardStagingLease]
    /// The pasteboard the offer was read from, and its change then, whether or not it serves from it.
    private let readFrom: (pasteboard: any ClipboardReadPasteboard, changeCount: Int)?
    /// Why a copy sent of this source is owed a withdrawal, once it is.
    private var owed: Withdrawal?
    /// Hears the first reason a copy sent of this source is owed a withdrawal.
    private var onOwed: (@MainActor (Withdrawal) -> Void)?
    /// Watches the pasteboard a concealed source was read from, while a copy sent of it is withdrawn when it moves
    /// on.
    private var movedOnWatch: ClipboardPasteboardWatch.Observation?
    /// The items, by index, the read left a file out of.
    let incompleteItems: Set<Int>

    init(
        items: [OfferedItem], origins: [[Origin]], concealed: Bool,
        pasteboard: (any ClipboardReadPasteboard)?, changeCount: Int,
        promises: [any FilePromiseReceiving], promiseDestination: @escaping @MainActor () throws -> URL,
        leases: [ClipboardStagingLease] = [], readFrom: (any ClipboardReadPasteboard, Int)? = nil,
        incompleteItems: Set<Int> = []
    ) {
        self.items = items
        self.origins = origins
        self.concealed = concealed
        self.pasteboard = pasteboard
        self.changeCount = changeCount
        self.promises = promises
        self.promiseDestination = promiseDestination
        self.leases = leases
        self.readFrom = readFrom ?? pasteboard.map { ($0, changeCount) }
        self.incompleteItems = incompleteItems
    }

    /// Whether the pasteboard this offer was read from still holds what it was read from: nothing has changed
    /// it since.
    public var standsOnItsPasteboard: Bool {
        readFrom.map { $0.pasteboard.changeCount == $0.changeCount } ?? false
    }

    /// Why the far side's write of a copy of this snapshot is owed a withdrawal (``whenWithdrawalOwed(_:)``).
    public enum Withdrawal: Sendable, Equatable {
        /// An offer one of the snapshot's files is served from ended: those files can be served no more.
        case upstreamEnded
        /// The snapshot is concealed, and the pasteboard it was read from moved on: the source no longer holds it.
        case movedOn
    }

    /// Runs `handler` once, at the first reason the far side's write of a copy of this snapshot is owed a
    /// withdrawal, at once when one has come already. A snapshot with neither reason never runs it. From then on, a
    /// concealed snapshot watches the pasteboard it was read from, for as long as it lives.
    public func whenWithdrawalOwed(_ handler: @escaping @MainActor (Withdrawal) -> Void) {
        if let owed { return handler(owed) }
        onOwed = handler
        guard concealed, let readFrom else { return }
        guard standsOnItsPasteboard else { return owe(.movedOn) }
        movedOnWatch = ClipboardPasteboardWatch.observe(readFrom.pasteboard, in: .standingWrites) { [weak self] in
            guard let self, !self.standsOnItsPasteboard else { return }
            self.owe(.movedOn)
        }
    }

    private func owe(_ withdrawal: Withdrawal) {
        guard owed == nil else { return }
        owed = withdrawal
        movedOnWatch?.cancel()
        movedOnWatch = nil
        let handler = onOwed
        onOwed = nil
        handler?(withdrawal)
    }

    /// Whether `url` is a file of this offer's own staging, which goes when the offer does.
    public func owns(_ url: URL) -> Bool {
        leases.contains { $0.holds(url) }
    }

    /// The bytes of the file at `url`, read downloading nothing: nil for a file a File Provider evicted.
    public static let contentsDownloadingNothing: @Sendable (URL) -> Data? = { url in
        DatalessMaterialization.off.during { try? Data(contentsOf: url) }
    }

    /// This offer as a snapshot of the pasteboard now, independent of what it holds later: every INLINE
    /// representation's bytes read now and held in memory, each sized by what was read, every FILE and FOLDER
    /// kept as the reference it is, read when pulled, and every file promise called in now, where the source's
    /// `promiseDestination` puts it, and kept as the file it landed. The snapshot holds `lease`, the staging
    /// those files land in, for as long as it lives.
    ///
    /// A representation whose bytes can no longer be read, or whose promise lands nothing, is left out, and an
    /// item left with none is dropped: an image file's INLINE bytes are read downloading nothing
    /// (``DatalessMaterialization/off``, or `contentsOf`), so a dataless one crosses as its file alone, which
    /// leaves nothing out. Nil when the pasteboard moved on from what was offered, or nothing remains.
    ///
    /// - Returns: the snapshot, and how many of the offer's items it does not carry whole: those the read left a
    ///   file out of, and those it left a representation of out, or dropped.
    ///
    /// - Throws: ``ClipboardSnapshotTooLarge`` once the INLINE bytes read come to more than `inlineCeiling`, or an
    ///   image file's size would take them there, reading nothing more.
    public func snapshot(
        inlineCeiling: Int, holding lease: ClipboardStagingLease,
        contentsOf: @escaping @Sendable (URL) -> Data? = ClipboardOfferSource.contentsDownloadingNothing
    ) async throws(ClipboardSnapshotTooLarge) -> (ClipboardOfferSource, leftOut: Int)? {
        var tally = ClipboardSnapshotTooLarge.Tally(ceiling: inlineCeiling)
        var frozenItems: [OfferedItem] = []
        var frozenOrigins: [[Origin]] = []
        var incomplete = incompleteItems
        for (index, item) in items.enumerated() {
            var frozen = OfferedItem()
            var itemOrigins: [Origin] = []
            for (position, representation) in item.representations.enumerated() {
                var kept = representation
                let held: Origin?
                switch origins[index][position] {
                case .pasteboard(let pasteboardItem, let type):
                    guard let pasteboard, pasteboard.changeCount == changeCount else { return nil }
                    let pasteboardItems = pasteboard.items
                    held =
                        pasteboardItems.indices.contains(pasteboardItem)
                        ? pasteboardItems[pasteboardItem].data(forType: NSPasteboard.PasteboardType(type)).map(
                            Origin.bytes)
                        : nil
                case .fileContents(let url):
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    try tally.check(fits: UInt64(max(size, 0)))
                    held = await Task.detached { contentsOf(url) }.value.map(Origin.bytes)
                case .promise(let promise):
                    held = await Self.landed(callIn(promise), as: &kept)
                case .landing(let file):
                    held = await Self.landed(file, as: &kept)
                case .bytes, .file, .folder, .spent, .reference, .upstream:
                    held = origins[index][position]
                }
                guard let held else {
                    if case .fileContents = origins[index][position] {} else { incomplete.insert(index) }
                    continue
                }
                if case .bytes(let data) = held {
                    switch origins[index][position] {
                    case .pasteboard, .fileContents: try tally.add(UInt64(data.count))
                    default: break
                    }
                    kept.sizeEstimate = UInt64(data.count)
                }
                frozen.representations.append(kept)
                itemOrigins.append(held)
            }
            guard !frozen.representations.isEmpty else { continue }
            frozenItems.append(frozen)
            frozenOrigins.append(itemOrigins)
        }
        if let pasteboard, pasteboard.changeCount != changeCount { return nil }
        guard !frozenItems.isEmpty else { return nil }
        let snapshot = ClipboardOfferSource(
            items: frozenItems, origins: frozenOrigins, concealed: concealed, pasteboard: nil, changeCount: 0,
            promises: [], promiseDestination: { throw ClipboardServeError.unavailable },
            leases: leases + [lease], readFrom: readFrom)
        return (snapshot, incomplete.count)
    }

    /// The file or folder `landing` lands, once it has, `kept` taking what landed: its storage, its size, and
    /// its name when it is one path component. Nil when it lands nothing.
    private static func landed(_ landing: Task<URL, any Error>, as kept: inout Representation) async -> Origin? {
        guard let url = try? await value(of: landing),
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        else { return nil }
        let isFolder = values.isDirectory == true
        kept.storage = isFolder ? .folder : .file
        kept.sizeEstimate = UInt64(
            max(
                isFolder
                    ? await Task.detached { ClipboardDirectory.estimatedByteCount(at: url) }.value
                    : values.fileSize ?? 0, 0))
        let name = Data(url.lastPathComponent.utf8)
        if PathComponent.isValid(name) { kept.name = name }
        kept.promised = false
        return isFolder ? .folder(url) : .file(url)
    }

    /// Lets go of representation `representation` of item `item` once a copy served its bytes: the receiver
    /// pulls each once, so the copy holds no bytes for the rest of its life.
    public func spend(item: Int, representation: Int) {
        guard origins.indices.contains(item), origins[item].indices.contains(representation),
            case .bytes = origins[item][representation]
        else { return }
        origins[item][representation] = .spent
    }

    /// A snapshot of what a write of this process placed, built from what it was made from, so nothing the
    /// pasteboard does later reaches it: what `source` holds, as data, and what it holds only as the far side's
    /// promise named by reference to the far side's offer (``Origin/reference``), which the far side fills itself,
    /// when the snapshot's copy goes over `destination`, the connection that offer arrived on. Otherwise that
    /// promise is the write's own source's: an INLINE representation is pulled through the part's puller now
    /// and held as data, and a FILE or FOLDER kept as a placeholder pulled through it when pulled
    /// (``Origin/upstream``), for as long as that offer lasts (``whenWithdrawalOwed(_:)``). Only the
    /// representations the write placed are kept; one that cannot be pulled is left out, and an item left with
    /// none is dropped. Nil when nothing remains. `pasteboard` holds the write now.
    ///
    /// - Returns: the snapshot, and how many of the write's items it does not carry whole: those it left a
    ///   representation of out, or dropped.
    static func snapshot(
        of source: ClipboardWriteSource, on pasteboard: any ClipboardReadPasteboard,
        copyingTo destination: ClipboardConnectionID, inlineCeiling: Int
    ) async throws(ClipboardSnapshotTooLarge) -> (ClipboardOfferSource, lost: Int)? {
        let readFrom = (pasteboard: pasteboard, changeCount: pasteboard.changeCount)
        let referenced = source.serving.flatMap { $0.connection == destination ? $0.token : nil }
        var tally = ClipboardSnapshotTooLarge.Tally(ceiling: inlineCeiling)
        var frozenItems: [OfferedItem] = []
        var frozenOrigins: [[Origin]] = []
        var upstreams: [any ClipboardItemPulling] = []
        var lost = 0
        for part in source.parts {
            var servesUpstream = false
            for (index, item) in part.items.enumerated() {
                var frozen = OfferedItem()
                var itemOrigins: [Origin] = []
                var whole = true
                for promised in ClipboardPromisePolicy.promisedTypes(for: item, servingFileURLs: part.servingFileURLs) {
                    var kept = item.representations[promised.representation]
                    kept.promised = false
                    let origin: Origin
                    switch part.held(index, promised.representation) {
                    case .bytes(let data):
                        try tally.add(UInt64(data.count))
                        kept.sizeEstimate = UInt64(data.count)
                        origin = .bytes(data)
                    case .file(let url):
                        origin = kept.storage == .folder ? .folder(url) : .file(url)
                    case nil:
                        if let offer = referenced {
                            var reference = RepresentationReference()
                            reference.offer = offer
                            reference.item = UInt32(index)
                            reference.representation = UInt32(promised.representation)
                            kept.reference = reference
                            kept.sizeEstimate = 0
                            origin = .reference
                            break
                        }
                        guard let puller = part.puller else {
                            whole = false
                            continue
                        }
                        guard kept.storage == .inline else {
                            kept.promised = true
                            servesUpstream = true
                            origin = .upstream(puller, item: index, representation: promised.representation)
                            break
                        }
                        let bytes = await withCheckedContinuation { continuation in
                            puller.pullBytes(item: index, representation: promised.representation) {
                                continuation.resume(returning: $0)
                            }
                        }
                        guard let bytes else {
                            whole = false
                            continue
                        }
                        try tally.add(UInt64(bytes.count))
                        kept.sizeEstimate = UInt64(bytes.count)
                        origin = .bytes(bytes)
                    }
                    frozen.representations.append(kept)
                    itemOrigins.append(origin)
                }
                if !whole { lost += 1 }
                guard !frozen.representations.isEmpty else { continue }
                frozenItems.append(frozen)
                frozenOrigins.append(itemOrigins)
            }
            if servesUpstream, let puller = part.puller { upstreams.append(puller) }
        }
        guard !frozenItems.isEmpty else { return nil }
        let snapshot = ClipboardOfferSource(
            items: frozenItems, origins: frozenOrigins, concealed: source.parts.contains(where: \.concealed),
            pasteboard: nil, changeCount: 0, promises: [],
            promiseDestination: { throw ClipboardServeError.unavailable }, readFrom: readFrom)
        for upstream in upstreams {
            upstream.whenEnded { [weak snapshot] in MainActorBridge.async { snapshot?.owe(.upstreamEnded) } }
        }
        return (snapshot, lost)
    }

    /// Serves one representation for a pull, reading its bytes now.
    ///
    /// A pasteboard type is read only while the pasteboard still holds the
    /// snapshot that was offered. A drop's promise was called in before its
    /// offer was read, and a clipboard's is called in on its first pull, into
    /// a fresh directory from the reader's `promiseDestination`; every pull of
    /// a promised file serves what its call-in wrote, waiting for it as long as
    /// its source takes, or until the task serving the pull is cancelled. An
    /// image file's INLINE bytes are read off the main actor, downloading the
    /// file when it is dataless (``DatalessMaterialization/on``); a FILE or
    /// FOLDER is read by the item source serving the pull.
    public func serve(item: Int, representation: Int) async throws(ClipboardServeError)
        -> ClipboardServedRepresentation
    {
        guard origins.indices.contains(item), origins[item].indices.contains(representation) else {
            throw .unavailable
        }
        let storage = items[item].representations[representation].storage
        switch origins[item][representation] {
        case .pasteboard(let index, let type):
            guard let pasteboard, pasteboard.changeCount == changeCount else { throw .unavailable }
            let pasteboardItems = pasteboard.items
            guard pasteboardItems.indices.contains(index),
                let data = pasteboardItems[index].data(forType: NSPasteboard.PasteboardType(type))
            else { throw .unavailable }
            return .bytes(data)
        case .bytes(let data):
            return .bytes(data)
        case .fileContents(let url):
            guard (try? url.checkResourceIsReachable()) == true else { throw .unavailable }
            let data = await Task.detached {
                DatalessMaterialization.on.during { try? Data(contentsOf: url, options: .mappedIfSafe) }
            }.value
            guard let data else { throw .readFailed }
            return .bytes(data)
        case .file(let url):
            return try Self.served(url, as: .file)
        case .folder(let url):
            return try Self.served(url, as: .folder)
        case .promise(let index):
            return try await Self.served(landing: callIn(index), as: storage)
        case .landing(let file):
            return try await Self.served(landing: file, as: storage)
        case .upstream(let puller, let upstreamItem, let upstreamRepresentation):
            let landed = await withCheckedContinuation { continuation in
                puller.pullFile(item: upstreamItem, representation: upstreamRepresentation) {
                    continuation.resume(returning: $0)
                }
            }
            guard let landed else { throw .unavailable }
            return try Self.served(landed, as: storage)
        case .spent, .reference:
            throw .unavailable
        }
    }

    /// The call-in of promise `index`, started on its first pull: the first file it lands is the item.
    private func callIn(_ index: Int) -> Task<URL, any Error> {
        if let task = calledIn[index] { return task }
        let receiver = promises[index]
        let task: Task<URL, any Error>
        do {
            task = CalledInFilePromise.callIn(receiver, into: try promiseDestination()).files[0].landed
        } catch {
            task = Task { throw error }
        }
        calledIn[index] = task
        return task
    }

    /// The file `landing` lands, once it has, served as `storage` names it: `.readFailed` once the calling task
    /// is cancelled first, which leaves the call-in running for any later pull.
    private static func served(landing: Task<URL, any Error>, as storage: Representation.Storage)
        async throws(ClipboardServeError) -> ClipboardServedRepresentation
    {
        let landed: URL
        do {
            landed = try await value(of: landing)
        } catch {
            throw .readFailed
        }
        return try served(landed, as: storage)
    }

    /// `task`'s value, or `CancellationError` as soon as the calling task is cancelled, `task` running on.
    nonisolated private static func value<Value: Sendable>(of task: Task<Value, any Error>) async throws -> Value {
        let waiter = Locked<(continuation: CheckedContinuation<Value, any Error>?, cancelled: Bool)>((nil, false))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = waiter.withLock { waiter -> Bool in
                    if !waiter.cancelled { waiter.continuation = continuation }
                    return waiter.cancelled
                }
                guard !cancelled else { return continuation.resume(throwing: CancellationError()) }
                Task {
                    let result = await task.result
                    waiter.withLock { waiter in
                        defer { waiter.continuation = nil }
                        return waiter.continuation
                    }?.resume(with: result)
                }
            }
        } onCancel: {
            waiter.withLock { waiter in
                waiter.cancelled = true
                defer { waiter.continuation = nil }
                return waiter.continuation
            }?.resume(throwing: CancellationError())
        }
    }

    /// `url` served as `storage` names it, or why it cannot be.
    private static func served(_ url: URL, as storage: Representation.Storage) throws(ClipboardServeError)
        -> ClipboardServedRepresentation
    {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else {
            throw .unavailable
        }
        switch storage {
        case .file where values.isRegularFile == true: return .file(url)
        case .folder where values.isDirectory == true: return .folder(url)
        default: throw .readFailed
        }
    }
}

/// A snapshot's INLINE bytes came to more than the paste ceiling, so nothing of it is copied.
public struct ClipboardSnapshotTooLarge: Error, Equatable, Sendable {
    /// The ceiling the bytes came to more than.
    public let limitBytes: Int

    /// The INLINE bytes a snapshot read so far, against its ceiling.
    struct Tally {
        let ceiling: Int
        private var total: UInt64 = 0

        init(ceiling: Int) {
            self.ceiling = ceiling
        }

        /// Counts `bytes` more, throwing once the total is over the ceiling.
        mutating func add(_ bytes: UInt64) throws(ClipboardSnapshotTooLarge) {
            try check(fits: bytes)
            total = total.saturatingAdding(bytes)
        }

        /// Throws when `bytes` more would take the total over the ceiling, counting nothing.
        func check(fits bytes: UInt64) throws(ClipboardSnapshotTooLarge) {
            guard total.saturatingAdding(bytes) <= UInt64(max(ceiling, 0)) else {
                throw ClipboardSnapshotTooLarge(limitBytes: ceiling)
            }
        }
    }
}

extension OfferedItem {
    /// An item of one representation.
    static func with(_ representation: Representation) -> OfferedItem {
        var item = OfferedItem()
        item.representations = [representation]
        return item
    }
}

extension Representation {
    /// A representation of `type` stored as `storage`, with its size estimate.
    ///
    /// FILE and FOLDER are named `name` when it is one path component
    /// (``PathComponent/isValid(_:)``), and otherwise `Untitled` with `type`'s
    /// extension; INLINE is unnamed.
    static func make(
        _ type: TypeDescriptor, _ storage: Storage, size: Int, name: String = "", promised: Bool = false
    ) -> Representation {
        var representation = Representation()
        representation.type = type
        representation.storage = storage
        representation.sizeEstimate = UInt64(max(size, 0))
        if storage != .inline {
            let named = Data(name.utf8)
            representation.name = PathComponent.isValid(named) ? named : Data(untitledName(of: type).utf8)
        }
        representation.promised = promised
        return representation
    }

    private static func untitledName(of type: TypeDescriptor) -> String {
        type.appleUTI.flatMap { UTType($0)?.preferredFilenameExtension }.map { "Untitled.\($0)" } ?? "Untitled"
    }
}
