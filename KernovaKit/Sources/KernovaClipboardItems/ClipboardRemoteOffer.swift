import Foundation
import KernovaAgentCore
import KernovaKit
import KernovaLogging
import KernovaSynchronization
import KernovaWire

/// The far side's clipboard offer as this side received it, its items read whole, and the pulls that land its
/// representations here: an INLINE one as its bytes, a FILE or FOLDER in a fresh directory of this side's
/// clipboard staging under the name the offer gives it.
///
/// A representation is pulled once and kept for every later paste that asks for it, so a paste served before
/// the offer ended still serves after. Safe from any thread: a paste asks on whatever thread the pasteboard
/// fires its provider on, and a pull ends on the connection's queue, so neither waits for the main actor.
public final class ClipboardRemoteOffer: ClipboardItemPulling, Sendable {
    /// The 16 bytes naming the offer.
    public let token: Data
    /// The far side marked the content concealed.
    public let concealed: Bool
    /// The items, in the order the offer sent them.
    public let items: [OfferedItem]

    private let link: any ClipboardItemLink
    private let staging: ClipboardFileStaging
    private let generation: UInt64
    private let ceiling: @Sendable () -> UInt64
    private let registry: ClipboardPullRegistry
    private let logger: KernovaLogger
    private let landed: @Sendable () -> Void
    private let state = Locked(State())

    /// One representation of one item.
    struct Key: Hashable, Sendable {
        var item: Int
        var representation: Int
    }

    /// What a pull landed.
    enum Landed: Sendable, Equatable {
        case bytes(Data)
        case file(URL)
    }

    /// A pull in flight, under the byte ceiling it was opened with, and everyone waiting on it.
    private struct Pulling {
        var directory: URL?
        var waiters: [@Sendable (Landed?) -> Void]
    }

    private struct State {
        var landed: [Key: Landed] = [:]
        var pulling: [PullingKey: Pulling] = [:]
        var pulls: [ItemPullID: PullingKey] = [:]
        /// No more pulls: released, or the far side ended the offer.
        var closed = false
    }

    private struct PullingKey: Hashable {
        var key: Key
        var ceiling: UInt64
    }

    init(
        header: ItemSetHeaderValue, items: [OfferedItem], link: any ClipboardItemLink,
        staging: ClipboardFileStaging, generation: UInt64, ceiling: @escaping @Sendable () -> UInt64,
        registry: ClipboardPullRegistry, logger: KernovaLogger, landed: @escaping @Sendable () -> Void
    ) {
        token = header.token
        concealed = header.concealed
        self.items = items
        self.link = link
        self.staging = staging
        self.generation = generation
        self.ceiling = ceiling
        self.registry = registry
        self.logger = logger
        self.landed = landed
    }

    // MARK: ClipboardItemPulling

    /// The bytes of INLINE representation `representation` of item `item`, under the paste ceiling.
    public func pullBytes(item: Int, representation: Int, completion: @escaping @Sendable (Data?) -> Void) {
        pull(Key(item: item, representation: representation), byteCeiling: ceiling()) { landed in
            if case .bytes(let data) = landed { completion(data) } else { completion(nil) }
        }
    }

    /// The file or folder FILE or FOLDER representation `representation` of item `item` landed at, under the
    /// paste ceiling.
    public func pullFile(item: Int, representation: Int, completion: @escaping @Sendable (URL?) -> Void) {
        pull(Key(item: item, representation: representation), byteCeiling: ceiling()) { landed in
            if case .file(let url) = landed { completion(url) } else { completion(nil) }
        }
    }

    /// The bytes of INLINE representation `representation` of item `item`, pulled no larger than `byteCeiling`:
    /// what a bounded preview reads. Nil when the pull failed or the representation is larger.
    public func previewBytes(item: Int, representation: Int, byteCeiling: UInt64) async -> Data? {
        await withCheckedContinuation { continuation in
            pull(Key(item: item, representation: representation), byteCeiling: byteCeiling) { landed in
                if case .bytes(let data) = landed {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// The bytes or file each representation already landed, keyed by item and representation.
    func landedSnapshot() -> [Key: Landed] {
        state.withLock(\.landed)
    }

    // MARK: Lifecycle

    /// Ends the offer here: what landed stays servable, and nothing more is pulled.
    func close() {
        state.withLock { $0.closed = true }
    }

    /// Ends the offer here and tells the far side, over the connection it arrived on, that this side pulls
    /// nothing more of it.
    func release() {
        close()
        link.releaseOffer(token)
    }

    /// Whether the offer is still the far side's, and pullable.
    public var isOpen: Bool { !state.withLock(\.closed) }

    /// The pull `id` of this offer ended with `result`.
    func ended(_ id: ItemPullID, _ result: ItemPullResult) {
        let (waiters, landed) = state.withLock { state -> ([@Sendable (Landed?) -> Void], Landed?) in
            guard let pullingKey = state.pulls.removeValue(forKey: id),
                let pulling = state.pulling.removeValue(forKey: pullingKey)
            else { return ([], nil) }
            var landed: Landed?
            switch result {
            case .landed(.inline(let data)):
                landed = .bytes(data)
            case .landed(.named(let name)):
                landed = pulling.directory.map {
                    .file($0.appendingPathComponent(String(decoding: name, as: UTF8.self)))
                }
            case .failed, .closed:
                landed = nil
            }
            if let landed { state.landed[pullingKey.key] = landed }
            return (pulling.waiters, landed)
        }
        if landed == nil {
            logger.log(
                .notice, "A clipboard pull ended without landing: \(String(describing: result), privacy: .public)")
        } else {
            self.landed()
        }
        for waiter in waiters { waiter(landed) }
    }

    // MARK: Pulling

    private func pull(_ key: Key, byteCeiling: UInt64, _ completion: @escaping @Sendable (Landed?) -> Void) {
        enum Next {
            case answer(Landed?)
            case joined
            case start(Representation)
        }
        let pullingKey = PullingKey(key: key, ceiling: byteCeiling)
        let next = state.withLock { state -> Next in
            if let landed = state.landed[key] { return .answer(landed) }
            if state.pulling[pullingKey] != nil {
                state.pulling[pullingKey]?.waiters.append(completion)
                return .joined
            }
            guard !state.closed, items.indices.contains(key.item),
                items[key.item].representations.indices.contains(key.representation)
            else { return .answer(nil) }
            state.pulling[pullingKey] = Pulling(directory: nil, waiters: [completion])
            return .start(items[key.item].representations[key.representation])
        }
        switch next {
        case .answer(let landed): completion(landed)
        case .joined: break
        case .start(let representation): start(pullingKey, representation, byteCeiling: byteCeiling)
        }
    }

    /// Opens the pull `pullingKey` names, or fails its waiters.
    private func start(_ pullingKey: PullingKey, _ representation: Representation, byteCeiling: UInt64) {
        let order: ItemPullOrder
        do {
            var landing = ItemLanding.inline
            if representation.storage != .inline {
                let directory = try staging.reserveScratchDirectory(generation: generation)
                state.withLock { $0.pulling[pullingKey]?.directory = directory }
                landing = .tree(directory: directory.path, name: .exactly(representation.name))
            }
            order = try link.order(
                token: token, item: UInt32(pullingKey.key.item), representation: UInt32(pullingKey.key.representation),
                byteCeiling: byteCeiling, landing: landing)
        } catch {
            logger.log(.error, "Cannot land a clipboard pull: \(String(describing: error), privacy: .public)")
            return fail(pullingKey)
        }
        link.pullItem(order) { [self] result in
            switch result {
            case .success(let id):
                state.withLock { $0.pulls[id] = pullingKey }
                registry.register(id, self)
            case .failure(let error):
                logger.log(.notice, "A clipboard pull did not open: \(String(describing: error), privacy: .public)")
                fail(pullingKey)
            }
        }
    }

    private func fail(_ pullingKey: PullingKey) {
        let waiters = state.withLock { $0.pulling.removeValue(forKey: pullingKey)?.waiters ?? [] }
        for waiter in waiters { waiter(nil) }
    }
}

/// Which remote offer each open pull belongs to, so a pull's end reaches it from the connection's queue.
final class ClipboardPullRegistry: Sendable {
    private let pulls = Locked<[ItemPullID: ClipboardRemoteOffer]>([:])

    func register(_ id: ItemPullID, _ offer: ClipboardRemoteOffer) {
        pulls.withLock { $0[id] = offer }
    }

    /// Hands pull `id`'s end to its offer.
    func ended(_ id: ItemPullID, _ result: ItemPullResult) {
        pulls.withLock { $0.removeValue(forKey: id) }?.ended(id, result)
    }
}
