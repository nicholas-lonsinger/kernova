import AppKit
import Foundation
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

    init(
        items: [OfferedItem], origins: [[Origin]], concealed: Bool,
        pasteboard: (any ClipboardReadPasteboard)?, changeCount: Int,
        promises: [any FilePromiseReceiving], promiseDestination: @escaping @MainActor () throws -> URL
    ) {
        self.items = items
        self.origins = origins
        self.concealed = concealed
        self.pasteboard = pasteboard
        self.changeCount = changeCount
        self.promises = promises
        self.promiseDestination = promiseDestination
    }

    /// This offer as a snapshot of the pasteboard now, independent of what it holds later: every INLINE
    /// representation's bytes read now and held in memory, each sized by what was read, every FILE and FOLDER
    /// kept as the reference it is, read when pulled, and every file promise called in now, inside the
    /// source's own staging, and kept as the file it landed.
    ///
    /// A representation whose bytes can no longer be read, or whose promise lands nothing, is left out, and an
    /// item left with none is dropped. Nil when the pasteboard moved on from what was offered, or nothing
    /// remains.
    ///
    /// - Throws: ``ClipboardSnapshotTooLarge`` once the INLINE bytes read come to more than `inlineCeiling`,
    ///   reading nothing more.
    public func snapshot(inlineCeiling: Int) async throws(ClipboardSnapshotTooLarge) -> ClipboardOfferSource? {
        var tally = ClipboardSnapshotTooLarge.Tally(ceiling: inlineCeiling)
        var frozenItems: [OfferedItem] = []
        var frozenOrigins: [[Origin]] = []
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
                    try tally.add(UInt64(max(size, 0)))
                    held = await Task.detached { try? Data(contentsOf: url) }.value.map(Origin.bytes)
                case .promise(let promise):
                    held = await Self.landed(callIn(promise), as: &kept)
                case .landing(let file):
                    held = await Self.landed(file, as: &kept)
                case .bytes, .file, .folder, .spent:
                    held = origins[index][position]
                }
                guard let held else { continue }
                if case .bytes(let data) = held {
                    if case .pasteboard = origins[index][position] { try tally.add(UInt64(data.count)) }
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
        return ClipboardOfferSource(
            items: frozenItems, origins: frozenOrigins, concealed: concealed, pasteboard: nil, changeCount: 0,
            promises: [], promiseDestination: { throw ClipboardServeError.unavailable })
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
                    ? await Task.detached { ClipboardArchive.estimatedByteCount(at: url) }.value
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

    /// A snapshot of what a write of this process placed, built from what it was made from — what `source`
    /// holds, and what its puller brings now, each file pulled whole — so nothing the pasteboard or the write's
    /// source does later reaches it. Only the representations the write promised are kept; one that cannot be
    /// brought is left out, and an item left with none is dropped. Nil when nothing remains.
    ///
    /// - Returns: the snapshot, and how many of the write's items it left out.
    static func snapshot(of source: ClipboardWriteSource, inlineCeiling: Int) async throws(ClipboardSnapshotTooLarge)
        -> (ClipboardOfferSource, lost: Int)?
    {
        var tally = ClipboardSnapshotTooLarge.Tally(ceiling: inlineCeiling)
        var frozenItems: [OfferedItem] = []
        var frozenOrigins: [[Origin]] = []
        var lost = 0
        for part in source.parts {
            for (index, item) in part.items.enumerated() {
                var frozen = OfferedItem()
                var itemOrigins: [Origin] = []
                for promised in ClipboardPromisePolicy.promisedTypes(for: item, servingFileURLs: part.servingFileURLs) {
                    var kept = item.representations[promised.representation]
                    guard let origin = await Self.origin(of: kept, item: index, promised.representation, in: part)
                    else { continue }
                    if case .bytes(let data) = origin {
                        try tally.add(UInt64(data.count))
                        kept.sizeEstimate = UInt64(data.count)
                    }
                    kept.promised = false
                    frozen.representations.append(kept)
                    itemOrigins.append(origin)
                }
                guard !frozen.representations.isEmpty else {
                    lost += 1
                    continue
                }
                frozenItems.append(frozen)
                frozenOrigins.append(itemOrigins)
            }
        }
        guard !frozenItems.isEmpty else { return nil }
        let snapshot = ClipboardOfferSource(
            items: frozenItems, origins: frozenOrigins, concealed: source.parts.contains(where: \.concealed),
            pasteboard: nil, changeCount: 0, promises: [], promiseDestination: { throw ClipboardServeError.unavailable }
        )
        return (snapshot, lost)
    }

    /// Representation `representation` of item `item` of `part`, as `part` holds it or its puller brings it now.
    private static func origin(
        of kept: Representation, item: Int, _ representation: Int, in part: ClipboardWriteSource.Part
    ) async -> Origin? {
        switch part.held(item, representation) {
        case .bytes(let data):
            return .bytes(data)
        case .file(let url):
            return kept.storage == .folder ? .folder(url) : .file(url)
        case nil:
            guard let puller = part.puller else { return nil }
            if kept.storage == .inline {
                let data = await withCheckedContinuation { continuation in
                    puller.pullBytes(item: item, representation: representation) { continuation.resume(returning: $0) }
                }
                return data.map(Origin.bytes)
            }
            let url = await withCheckedContinuation { continuation in
                puller.pullFile(item: item, representation: representation) { continuation.resume(returning: $0) }
            }
            return url.map { kept.storage == .folder ? .folder($0) : .file($0) }
        }
    }

    /// Serves one representation for a pull, reading its bytes now.
    ///
    /// A pasteboard type is read only while the pasteboard still holds the
    /// snapshot that was offered. A drop's promise was called in before its
    /// offer was read, and a clipboard's is called in on its first pull, into
    /// a fresh directory from the reader's `promiseDestination`; every pull of
    /// a promised file serves what its call-in wrote, waiting for it as long as
    /// its source takes, or until the task serving the pull is cancelled.
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
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw .readFailed }
            return .bytes(data)
        case .file(let url):
            return try Self.served(url, as: .file)
        case .folder(let url):
            return try Self.served(url, as: .folder)
        case .promise(let index):
            return try await Self.served(landing: callIn(index), as: storage)
        case .landing(let file):
            return try await Self.served(landing: file, as: storage)
        case .spent:
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
            total = total.saturatingAdding(bytes)
            guard total <= UInt64(max(ceiling, 0)) else { throw ClipboardSnapshotTooLarge(limitBytes: ceiling) }
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
