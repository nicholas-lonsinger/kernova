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
    }

    /// The items, in the order they are offered.
    public let items: [OfferedItem]
    /// The content is confidential: `org.nspasteboard.ConcealedType`.
    public let concealed: Bool

    private let origins: [[Origin]]
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
    /// representation's bytes read now and held in memory, each sized by what was read, and every FILE and
    /// FOLDER kept as the reference it is, read when pulled.
    ///
    /// A representation whose bytes can no longer be read is left out, and an item left with none is dropped.
    /// Nil when the pasteboard moved on from what was offered, or nothing remains.
    public func snapshot() async -> ClipboardOfferSource? {
        var frozenItems: [OfferedItem] = []
        var frozenOrigins: [[Origin]] = []
        for (index, item) in items.enumerated() {
            var frozen = OfferedItem()
            var itemOrigins: [Origin] = []
            for (position, representation) in item.representations.enumerated() {
                let origin = origins[index][position]
                let held: Origin?
                switch origin {
                case .pasteboard(let pasteboardItem, let type):
                    guard let pasteboard, pasteboard.changeCount == changeCount else { return nil }
                    let pasteboardItems = pasteboard.items
                    held = pasteboardItems.indices.contains(pasteboardItem)
                        ? pasteboardItems[pasteboardItem].data(forType: NSPasteboard.PasteboardType(type)).map(Origin.bytes)
                        : nil
                case .fileContents(let url):
                    held = await Task.detached { try? Data(contentsOf: url) }.value.map(Origin.bytes)
                case .bytes, .file, .folder, .promise, .landing:
                    held = origin
                }
                guard let held else { continue }
                var kept = representation
                if case .bytes(let data) = held { kept.sizeEstimate = UInt64(data.count) }
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
            promises: promises, promiseDestination: promiseDestination)
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
