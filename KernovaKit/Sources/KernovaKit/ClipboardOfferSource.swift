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

/// A served representation, and the grant its file or folder is read under: whatever reads it holds the grant
/// until it has, which for a pull's FILE or FOLDER is until its serve ends.
public struct ClipboardServed: Sendable {
    /// What is served.
    public let representation: ClipboardServedRepresentation
    /// The grant the file or folder is read under; nil when the offer holds what reaches it, or for bytes.
    public let access: SandboxFileGrants.Grant?

    init(_ representation: ClipboardServedRepresentation, access: SandboxFileGrants.Grant? = nil) {
        self.representation = representation
        self.access = access
    }
}

/// How an offer reaches a file or folder it offers.
enum ClipboardFileReach: Sendable {
    /// At the URL a read named, through the grant that read took, which the offer holds.
    case granted(URL)
    /// Through a security-scoped bookmark a copy's read made, wherever the file or folder has moved since, under
    /// a grant started for each use (docs/research/2026-11-18-pasteboard-file-grants.md).
    case bookmarked(Data)

    /// The file or folder now, and the grant that reaches it, which the caller holds while it reads; nil when a
    /// bookmark no longer resolves.
    func reached(through grants: SandboxFileGrants) -> (url: URL, grant: SandboxFileGrants.Grant?)? {
        switch self {
        case .granted(let url): (url, nil)
        case .bookmarked(let bookmark): grants.reach(bookmark)
        }
    }
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
/// Built by ``ClipboardPasteboardReader/readOffer(from:publisher:promises:promiseDestination:sizeOf:)``
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
        case fileContents(ClipboardFileReach)
        /// A regular file.
        case file(ClipboardFileReach)
        /// A directory.
        case folder(ClipboardFileReach)
        /// A file promise, by its index in ``ClipboardOfferSource/promises``,
        /// called in on its first pull.
        case promise(Int)
        /// A file a promise called in before the offer was read lands.
        case landing(Task<URL, any Error>)
        /// Another connection's representation, which a write of this process holds only as that connection's
        /// promise: pulled through `puller` when pulled, for as long as that offer lasts.
        case upstream(any ClipboardItemPulling, item: Int, representation: Int)
    }

    /// The items, in the order they are offered.
    public let items: [OfferedItem]
    /// The content is confidential: `org.nspasteboard.ConcealedType`.
    public let concealed: Bool
    /// The grants of access to the files the offer reaches by their paths, held while the offer lives: a drop's
    /// every file, a copy's each it couldn't bookmark.
    public let fileAccess: PasteboardFileAccess?
    /// What starts the grant each pull of a bookmarked file or folder is read under.
    private let fileGrants: SandboxFileGrants

    private let origins: [[Origin]]
    private let pasteboard: (any ClipboardReadPasteboard)?
    /// The pasteboard change the offer was read at.
    private let changeCount: Int
    private let promises: [any FilePromiseReceiving]
    private let promiseDestination: @MainActor () throws -> URL
    private var calledIn: [Int: Task<URL, any Error>] = [:]
    /// The pasteboard the offer was read from, and its change then, whether or not it serves from it.
    private let readFrom: (pasteboard: any ClipboardReadPasteboard, changeCount: Int)?
    /// Watches the pasteboard the source was read from while anything waits for it to move on.
    private var movedOnWatch: ClipboardPasteboardWatch.Observation?
    /// Hear the pasteboard the source was read from move on from it (``whenMovedOn(_:)``).
    private var onMovedOn: [@MainActor () -> Void] = []

    init(
        items: [OfferedItem], origins: [[Origin]], concealed: Bool,
        pasteboard: (any ClipboardReadPasteboard)?, changeCount: Int,
        promises: [any FilePromiseReceiving], promiseDestination: @escaping @MainActor () throws -> URL,
        readFrom: (any ClipboardReadPasteboard, Int)? = nil, fileAccess: PasteboardFileAccess? = nil,
        fileGrants: SandboxFileGrants = .shared
    ) {
        self.items = items
        self.origins = origins
        self.concealed = concealed
        self.fileAccess = fileAccess
        self.fileGrants = fileGrants
        self.pasteboard = pasteboard
        self.changeCount = changeCount
        self.promises = promises
        self.promiseDestination = promiseDestination
        self.readFrom = readFrom ?? pasteboard.map { ($0, changeCount) }
    }

    /// Whether the pasteboard this offer was read from still holds what it was read from: nothing has changed
    /// it since.
    private var standsOnItsPasteboard: Bool {
        readFrom.map { $0.pasteboard.changeCount == $0.changeCount } ?? false
    }

    /// Runs `handler` once, at the first poll of the pasteboard this source was read from to find it no longer
    /// holds what it was read from (``standsOnItsPasteboard``) — in the watch's
    /// ``ClipboardPasteboardWatch/Turn/standingWrites`` turn, so before anything reads what replaced it — or at
    /// once when it already does not. The source watches that pasteboard only while it lives and something waits.
    public func whenMovedOn(_ handler: @escaping @MainActor () -> Void) {
        guard let readFrom else { return }
        guard standsOnItsPasteboard else { return handler() }
        onMovedOn.append(handler)
        guard movedOnWatch == nil else { return }
        movedOnWatch = ClipboardPasteboardWatch.observe(readFrom.pasteboard, in: .standingWrites) { [weak self] in
            guard let self, !self.standsOnItsPasteboard else { return }
            self.movedOnWatch?.cancel()
            self.movedOnWatch = nil
            let handlers = self.onMovedOn
            self.onMovedOn = []
            for handler in handlers { handler() }
        }
    }

    /// An offer of what a write of another publisher of this process placed, built from what it was made from:
    /// the pasteboard holding it is never read, since each read of a promise fires its provider in this process.
    /// Every representation the write placed is offered promised and pulled through its puller when pulled
    /// (``Origin/upstream``), for as long as that offer lasts. Nil when nothing remains. `pasteboard` holds the
    /// write now.
    static func offer(
        of source: ClipboardWriteSource, on pasteboard: any ClipboardReadPasteboard
    ) -> ClipboardOfferSource? {
        var items: [OfferedItem] = []
        var origins: [[Origin]] = []
        for (index, item) in source.items.enumerated() {
            var offered = OfferedItem()
            var itemOrigins: [Origin] = []
            for promised in ClipboardPromisePolicy.promisedTypes(for: item, servingFileURLs: source.servingFileURLs) {
                var representation = item.representations[promised.representation]
                representation.promised = true
                offered.representations.append(representation)
                itemOrigins.append(.upstream(source.puller, item: index, representation: promised.representation))
            }
            guard !offered.representations.isEmpty else { continue }
            items.append(offered)
            origins.append(itemOrigins)
        }
        guard !items.isEmpty else { return nil }
        return ClipboardOfferSource(
            items: items, origins: origins, concealed: source.concealed, pasteboard: nil,
            changeCount: pasteboard.changeCount, promises: [],
            promiseDestination: { throw ClipboardServeError.unavailable },
            readFrom: (pasteboard, pasteboard.changeCount))
    }

    /// Serves one representation for a pull, reading its bytes now.
    ///
    /// A pasteboard type is read only while the pasteboard still holds what
    /// was offered. A drop's promise was called in before its
    /// offer was read, and a clipboard's is called in on its first pull, into
    /// a fresh directory from the reader's `promiseDestination`; every pull of
    /// a promised file serves what its call-in wrote, waiting for it as long as
    /// its source takes, or until the task serving the pull is cancelled. An
    /// image file's INLINE bytes are read off the main actor, downloading the
    /// file when it is dataless (``DatalessMaterialization/on``); a FILE or
    /// FOLDER is read by the item source serving the pull, under the grant
    /// served beside it. A copied file or folder is served from wherever its
    /// bookmark resolves now; one whose bookmark no longer resolves is gone.
    /// What another connection promised is pulled through that connection's
    /// puller now.
    public func serve(item: Int, representation: Int) async throws(ClipboardServeError) -> ClipboardServed {
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
            return ClipboardServed(.bytes(data))
        case .bytes(let data):
            return ClipboardServed(.bytes(data))
        case .fileContents(let reach):
            let grants = fileGrants
            let read = await Task.detached { () -> Result<Data, ClipboardServeError> in
                guard let reached = reach.reached(through: grants),
                    (try? reached.url.checkResourceIsReachable()) == true
                else { return .failure(.unavailable) }
                let data = withExtendedLifetime(reached.grant) {
                    DatalessMaterialization.on.during { try? Data(contentsOf: reached.url, options: .mappedIfSafe) }
                }
                return data.map { .success($0) } ?? .failure(.readFailed)
            }.value
            return ClipboardServed(.bytes(try read.get()))
        case .file(let reach), .folder(let reach):
            let grants = fileGrants
            return try await Task.detached { () -> Result<ClipboardServed, ClipboardServeError> in
                guard let reached = reach.reached(through: grants) else { return .failure(.unavailable) }
                return Result { () throws(ClipboardServeError) in
                    ClipboardServed(try Self.served(reached.url, as: storage), access: reached.grant)
                }
            }.value.get()
        case .promise(let index):
            return ClipboardServed(try await Self.served(landing: callIn(index), as: storage))
        case .landing(let file):
            return ClipboardServed(try await Self.served(landing: file, as: storage))
        case .upstream(let puller, let upstreamItem, let upstreamRepresentation) where storage == .inline:
            let bytes = await withCheckedContinuation { continuation in
                puller.pullBytes(item: upstreamItem, representation: upstreamRepresentation) {
                    continuation.resume(returning: $0)
                }
            }
            guard let bytes else { throw .unavailable }
            return ClipboardServed(.bytes(bytes))
        case .upstream(let puller, let upstreamItem, let upstreamRepresentation):
            let landed = await withCheckedContinuation { continuation in
                puller.pullFile(item: upstreamItem, representation: upstreamRepresentation) {
                    continuation.resume(returning: $0)
                }
            }
            guard let landed else { throw .unavailable }
            return ClipboardServed(try Self.served(landed, as: storage))
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
    nonisolated private static func served(_ url: URL, as storage: Representation.Storage) throws(ClipboardServeError)
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
