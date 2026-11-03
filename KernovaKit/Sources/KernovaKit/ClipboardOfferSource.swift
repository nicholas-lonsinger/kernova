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
/// pasteboard, or by ``init(content:)`` from content already held. No
/// byte is read until ``serve(item:representation:)``.
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
    }

    /// The items, in the order they are offered.
    public let items: [OfferedItem]
    /// The content is confidential: `org.nspasteboard.ConcealedType`.
    public let concealed: Bool

    private let origins: [[Origin]]
    private let pasteboard: (any ClipboardReadPasteboard)?
    private let changeCount: Int
    private let promises: [any FilePromiseReceiving]
    private let promiseDestination: @MainActor () throws -> URL
    private var calledIn: [Int: Task<URL, any Error>] = [:]

    init(
        items: [OfferedItem], origins: [[Origin]], concealed: Bool,
        pasteboard: (any ClipboardReadPasteboard)?, changeCount: Int,
        promises: [any FilePromiseReceiving], calledIn: [Int: Task<URL, any Error>] = [:],
        promiseDestination: @escaping @MainActor () throws -> URL
    ) {
        self.items = items
        self.origins = origins
        self.concealed = concealed
        self.pasteboard = pasteboard
        self.changeCount = changeCount
        self.promises = promises
        self.calledIn = calledIn
        self.promiseDestination = promiseDestination
    }

    /// An offer of `content`: its inline representations as one item, then
    /// one item per file or folder, an image file also offering its bytes
    /// INLINE so a paste can show it in place.
    ///
    /// A representation whose bytes are not here — a pending remote one, or
    /// a named one held only in memory, which no file backs — is not offered.
    public convenience init(content: ClipboardContent) {
        var inline = OfferedItem()
        var inlineOrigins: [Origin] = []
        var items: [OfferedItem] = []
        var origins: [[Origin]] = []
        for representation in content.representations {
            let type = TypeDescriptor(appleUTI: representation.uti)
            let size = representation.byteCount
            switch representation.source {
            case .inMemory(let data) where representation.filename.isEmpty:
                inline.representations.append(.make(type, .inline, size: size))
                inlineOrigins.append(.bytes(data))
            case .file(let url, _, _) where representation.isDirectory:
                items.append(.with(.make(type, .folder, size: size, name: representation.filename)))
                origins.append([.folder(url)])
            case .file(let url, _, _):
                var item = OfferedItem.with(.make(type, .file, size: size, name: representation.filename))
                var itemOrigins: [Origin] = [.file(url)]
                if representation.shouldInlineOnPasteboard {
                    item.representations.append(.make(type, .inline, size: size))
                    itemOrigins.append(.fileContents(url))
                }
                items.append(item)
                origins.append(itemOrigins)
            case .directory(let url, let estimate):
                items.append(.with(.make(type, .folder, size: estimate, name: representation.filename)))
                origins.append([.folder(url)])
            case .inMemory, .pendingRemote:
                continue
            }
        }
        if !inline.representations.isEmpty {
            items.insert(inline, at: 0)
            origins.insert(inlineOrigins, at: 0)
        }
        self.init(
            items: items, origins: origins, concealed: content.isConcealed,
            pasteboard: nil, changeCount: 0, promises: [],
            promiseDestination: { throw ClipboardServeError.unavailable })
    }

    /// Serves one representation for a pull, reading its bytes now.
    ///
    /// A pasteboard type is read only while the pasteboard still holds the
    /// snapshot that was offered. A drop's promise was called in before its
    /// offer was read, and a clipboard's is called in on its first pull, into
    /// a fresh directory from the reader's `promiseDestination`; every pull of
    /// it serves what that call-in wrote, waiting for it as long as its source
    /// takes.
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
            let landed: URL
            do {
                landed = try await callIn(index).value
            } catch {
                throw .readFailed
            }
            return try Self.served(landed, as: storage)
        }
    }

    /// The call-in of promise `index`: the one made before the offer was read, or else one started on its
    /// first pull.
    private func callIn(_ index: Int) -> Task<URL, any Error> {
        if let task = calledIn[index] { return task }
        let receiver = promises[index]
        let task: Task<URL, any Error>
        do {
            task = CalledInFilePromise.callIn(receiver, into: try promiseDestination()).landed
        } catch {
            task = Task { throw error }
        }
        calledIn[index] = task
        return task
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

/// A file promise called in: its receiver, which names its file once called in, and the file it lands.
@MainActor
public struct CalledInFilePromise {
    /// The promise.
    public let receiver: any FilePromiseReceiving
    /// The file its source writes, its first if it writes several, or why it wrote none. Its source sets no
    /// deadline, so neither does this.
    public let landed: Task<URL, any Error>

    /// Calls `receiver` in now, its file landing in `folder`.
    public static func callIn(_ receiver: any FilePromiseReceiving, into folder: URL) -> CalledInFilePromise {
        let first = FirstFile()
        receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: OperationQueue()) {
            url, error in
            // A receiver writing several files reports each; the item is its first.
            first.resolve(error.map { .failure($0) } ?? .success(url))
        }
        return CalledInFilePromise(receiver: receiver, landed: Task { try await first.value() })
    }

    /// The first file a call-in reports, whether it reports before or after it is awaited.
    private final class FirstFile: Sendable {
        private struct State {
            var result: Result<URL, any Error>?
            var waiter: CheckedContinuation<URL, any Error>?
        }

        private let state = Locked(State())

        func resolve(_ result: Result<URL, any Error>) {
            let waiter = state.withLock { state -> CheckedContinuation<URL, any Error>? in
                guard state.result == nil else { return nil }
                state.result = result
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume(with: result)
        }

        func value() async throws -> URL {
            try await withCheckedThrowingContinuation { continuation in
                let result = state.withLock { state -> Result<URL, any Error>? in
                    if state.result == nil { state.waiter = continuation }
                    return state.result
                }
                if let result { continuation.resume(with: result) }
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
