import Foundation
import KernovaAgentCore
import KernovaKit
import KernovaLogging
import KernovaSynchronization
import KernovaWire

/// The far side's clipboard offer as this side received it, its items read whole, and the pulls that land its
/// representations here: each in a fresh directory of this side's clipboard staging, a FILE or FOLDER under the
/// name the offer gives it, an INLINE one as a file of its bytes, served mapped — but a concealed offer's INLINE
/// one in memory, within the paste ceiling, since staging persists and a password must reach no disk.
///
/// A representation is pulled once and kept for every later ask whose limit admits it, so a paste served before
/// the offer ended still serves after. Its FILE, FOLDER and in-memory pulls together land no more than the paste
/// ceiling as it stood at the first of them: one budget the sink charges each landed byte to. Ending the offer
/// here cancels every pull still running and fails everyone waiting on one.
///
/// Safe from any thread: a paste asks on whatever thread the pasteboard fires its provider on, and a pull ends
/// on the connection's queue, so neither waits for the main actor.
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
    private let failed: @Sendable (WireError) -> Void
    private let state = Locked(State())

    /// One representation of one item.
    private struct Key: Hashable, Sendable {
        var item: Int
        var representation: Int
    }

    /// Where a pull landed a representation: a file or folder in staging, or a concealed offer's INLINE bytes
    /// in memory.
    private enum Content: Sendable {
        case staged(URL)
        case memory(Data)

        /// The file or folder; nil for bytes in memory, which no FILE or FOLDER ask takes.
        var url: URL? {
            if case .staged(let url) = self { url } else { nil }
        }

        /// The bytes, the staged file's mapped.
        var bytes: Data? {
            switch self {
            case .staged(let url): try? Data(contentsOf: url, options: .mappedIfSafe)
            case .memory(let data): data
            }
        }
    }

    /// What a pull landed, and an INLINE representation's byte count.
    private struct Landed {
        var content: Content
        /// Nil for a FILE or FOLDER, which every ask admits: each is charged once to the offer's one budget.
        var byteCount: UInt64?

        /// Whether an ask taking at most `ceiling` bytes — nil for a FILE or FOLDER ask — takes it.
        func admitted(by ceiling: UInt64?) -> Bool {
            guard let ceiling, let byteCount else { return true }
            return byteCount <= ceiling
        }
    }

    /// One ask of a representation: the most bytes it takes, nil for a FILE or FOLDER ask, and its completion.
    private struct Ask {
        var ceiling: UInt64?
        var completion: @Sendable (Content?) -> Void
    }

    /// The pull of a representation in flight, and every ask waiting on it.
    private struct Pulling {
        /// Tells this pull from a later one of the same representation.
        var attempt: UInt64
        /// An INLINE pull's byte ceiling; nil for a FILE or FOLDER pull, which the offer's budget bounds.
        var ceiling: UInt64?
        /// Its id, once the connection opened it.
        var id: ItemPullID?
        var asks: [Ask]
    }

    /// A pull the connection opened, until its end arrives.
    private struct Opened {
        var key: Key
        var attempt: UInt64
        /// Where it lands in staging; nil for a pull landing in memory.
        var directory: URL?
        var isInline: Bool
    }

    private struct State {
        var landed: [Key: Landed] = [:]
        var pulling: [Key: Pulling] = [:]
        var opened: [ItemPullID: Opened] = [:]
        /// What every FILE, FOLDER and in-memory pull of the offer lands against, from the first of them.
        var budget: ByteBudget?
        /// Why each representation's last pull failed, when its end said.
        var failures: [Key: WireError] = [:]
        var nextAttempt: UInt64 = 0
        /// No more pulls: released, or the far side ended the offer.
        var closed = false
    }

    init(
        header: ItemSetHeaderValue, items: [OfferedItem], link: any ClipboardItemLink,
        staging: ClipboardFileStaging, generation: UInt64, ceiling: @escaping @Sendable () -> UInt64,
        registry: ClipboardPullRegistry, logger: KernovaLogger, landed: @escaping @Sendable () -> Void,
        failed: @escaping @Sendable (WireError) -> Void
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
        self.failed = failed
    }

    // MARK: ClipboardItemPulling

    /// The bytes of INLINE representation `representation` of item `item`, under the paste ceiling.
    public func pullBytes(item: Int, representation: Int, completion: @escaping @Sendable (Data?) -> Void) {
        ask(Key(item: item, representation: representation), ceiling: ceiling()) { completion($0?.bytes) }
    }

    /// The file or folder FILE or FOLDER representation `representation` of item `item` landed at, its bytes
    /// charged to the offer's budget.
    public func pullFile(item: Int, representation: Int, completion: @escaping @Sendable (URL?) -> Void) {
        ask(Key(item: item, representation: representation), ceiling: nil) { completion($0?.url) }
    }

    /// Pulls every kept INLINE representation now, all at once, and waits for each: nil once all landed, or
    /// the error the first to fail ended with. What a copy is written from.
    public func landInline() async -> WireError? {
        var keys: [Key] = []
        for (item, offered) in items.enumerated() {
            for (index, representation) in offered.representations.enumerated()
            where representation.storage == .inline && ClipboardPromisePolicy.keeps(representation) {
                keys.append(Key(item: item, representation: index))
            }
        }
        return await withTaskGroup(of: WireError?.self) { group in
            for key in keys { group.addTask { await self.land(key) } }
            for await error in group {
                guard let error else { continue }
                group.cancelAll()
                return error
            }
            return nil
        }
    }

    /// The bytes INLINE representation `representation` of item `item` landed with; nil until it landed.
    public func landedBytes(item: Int, representation: Int) -> Data? {
        state.withLock { $0.landed[Key(item: item, representation: representation)] }?.content.bytes
    }

    private func land(_ key: Key) async -> WireError? {
        let content = await withCheckedContinuation { continuation in
            ask(key, ceiling: ceiling()) { continuation.resume(returning: $0) }
        }
        if case .some = content { return nil }
        return state.withLock { $0.failures[key] }
            ?? WireError(.readFailed, debugDetail: "the representation did not land")
    }

    // MARK: Lifecycle

    /// Ends the offer here: what landed stays servable, nothing more is pulled, every pull in flight is
    /// cancelled, and everyone waiting on one hears nil now.
    func close() {
        let (ids, asks) = state.withLock { state -> ([ItemPullID], [Ask]) in
            state.closed = true
            let pulling = state.pulling.values
            state.pulling = [:]
            return (pulling.compactMap(\.id), pulling.flatMap(\.asks))
        }
        for id in ids { link.cancelPull(id) }
        for ask in asks { ask.completion(nil) }
    }

    /// Ends the offer here and tells the far side, over the connection it arrived on, that this side pulls
    /// nothing more of it.
    func release() {
        close()
        link.releaseOffer(token)
    }

    /// Ends the offer here and tells the far side why this side pulls nothing more of it.
    func refuse(_ error: WireError) {
        close()
        link.refuseOffer(token, error)
    }

    /// Whether the offer is still the far side's, and pullable.
    public var isOpen: Bool { !state.withLock(\.closed) }

    /// The pull `id` of this offer ended with `result`. What it landed is kept even once the offer is closed.
    func ended(_ id: ItemPullID, _ result: ItemPullResult) {
        guard let opened = state.withLock({ $0.opened.removeValue(forKey: id) }) else { return }
        var landed: Landed?
        switch result {
        case .landed(.named(let name)):
            guard let url = opened.directory?.appendingPathComponent(String(decoding: name, as: UTF8.self)) else {
                break
            }
            if !opened.isInline {
                landed = Landed(content: .staged(url))
            } else if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                landed = Landed(content: .staged(url), byteCount: UInt64(size))
            }
        case .landed(.inline(let data)):
            if opened.directory == nil { landed = Landed(content: .memory(data), byteCount: UInt64(data.count)) }
        case .failed, .closed:
            break
        }
        guard let landed else {
            logger.log(
                .notice, "A clipboard pull ended without landing: \(String(describing: result), privacy: .public)")
            let error: WireError? =
                switch result {
                case .failed(let error), .closed(.resetByPeer(let error)): error
                case .landed, .closed: nil
                }
            return settle(opened.key, opened.attempt, failedWith: error)
        }
        self.landed()
        let asks = state.withLock { state -> [Ask] in
            state.landed[opened.key] = landed
            guard state.pulling[opened.key]?.attempt == opened.attempt else { return [] }
            return state.pulling.removeValue(forKey: opened.key)?.asks ?? []
        }
        for ask in asks { ask.completion(landed.admitted(by: ask.ceiling) ? landed.content : nil) }
    }

    // MARK: Pulling

    /// Answers `completion` from what landed, or joins or starts the pull of `key`.
    private func ask(_ key: Key, ceiling: UInt64?, _ completion: @escaping @Sendable (Content?) -> Void) {
        enum Next {
            case answer(Content?)
            case joined
            case start(attempt: UInt64, ceiling: UInt64?)
        }
        guard items.indices.contains(key.item), items[key.item].representations.indices.contains(key.representation)
        else { return completion(nil) }
        let isInline = items[key.item].representations[key.representation].storage == .inline
        let ask = Ask(ceiling: isInline ? ceiling ?? 0 : nil, completion: completion)
        let next = state.withLock { state -> Next in
            if let landed = state.landed[key] {
                return .answer(landed.admitted(by: ask.ceiling) ? landed.content : nil)
            }
            if state.pulling[key] != nil {
                state.pulling[key]?.asks.append(ask)
                return .joined
            }
            guard !state.closed else { return .answer(nil) }
            let attempt = state.nextAttempt
            state.nextAttempt += 1
            state.pulling[key] = Pulling(attempt: attempt, ceiling: ask.ceiling, asks: [ask])
            return .start(attempt: attempt, ceiling: ask.ceiling)
        }
        switch next {
        case .answer(let content): completion(content)
        case .joined: break
        case .start(let attempt, let ceiling): start(key, attempt, ceiling: ceiling)
        }
    }

    /// Opens attempt `attempt` at pulling `key`, an INLINE pull no larger than `ceiling`, or settles it failed. A
    /// concealed offer's INLINE representation lands in memory: a password never reaches staging, which persists.
    private func start(_ key: Key, _ attempt: UInt64, ceiling: UInt64?) {
        let representation = items[key.item].representations[key.representation]
        let isInline = representation.storage == .inline
        let directory: URL?
        let order: ItemPullOrder
        do {
            let landing: ItemLanding
            if isInline, concealed {
                directory = nil
                landing = .memory
            } else {
                let reserved = try staging.reserveScratchDirectory(generation: generation)
                directory = reserved
                landing = .staged(
                    directory: reserved.path, name: .exactly(isInline ? Self.inlineName : representation.name))
            }
            // Memory is charged as files are: a concealed offer's many INLINE representations hold no more
            // between them than the paste ceiling.
            let budget = directory == nil || !isInline ? offerBudget() : nil
            order = try link.order(
                token: token, item: UInt32(key.item), representation: UInt32(key.representation),
                byteCeiling: [budget?.remaining, ceiling].compactMap { $0 }.min() ?? 0, landing: landing,
                budget: budget)
        } catch {
            logger.log(.error, "Cannot land a clipboard pull: \(String(describing: error), privacy: .public)")
            return settle(key, attempt, failedWith: nil)
        }
        link.pullItem(order) { [self] result in
            switch result {
            case .success(let id):
                let wanted = state.withLock { state -> Bool in
                    guard state.pulling[key]?.attempt == attempt else { return false }
                    state.pulling[key]?.id = id
                    state.opened[id] = Opened(key: key, attempt: attempt, directory: directory, isInline: isInline)
                    return true
                }
                guard wanted else { return link.cancelPull(id) }
                registry.register(id, self)
            case .failure(let error):
                logger.log(.notice, "A clipboard pull did not open: \(String(describing: error), privacy: .public)")
                settle(key, attempt, failedWith: error)
            }
        }
    }

    /// The budget every FILE, FOLDER and in-memory pull of the offer lands against: the paste ceiling as it
    /// stands at the first of them.
    private func offerBudget() -> ByteBudget {
        state.withLock { state in
            if let budget = state.budget { return budget }
            let budget = ByteBudget(limit: ceiling())
            state.budget = budget
            return budget
        }
    }

    /// Attempt `attempt` at pulling `key` landed nothing, failing with `error` when it says why. A TOO_LARGE
    /// INLINE pull is pulled again for the asks that take more than it did; every other ask hears nil, and its
    /// owner hears the failure.
    private func settle(_ key: Key, _ attempt: UInt64, failedWith error: WireError?) {
        let (failing, retry) = state.withLock { state -> ([Ask], (attempt: UInt64, ceiling: UInt64)?) in
            guard let pulling = state.pulling[key], pulling.attempt == attempt else { return ([], nil) }
            state.pulling[key] = nil
            state.failures[key] = error
            guard error?.code == .tooLarge, !state.closed, let refused = pulling.ceiling else {
                return (pulling.asks, nil)
            }
            let larger = pulling.asks.filter { ($0.ceiling ?? 0) > refused }
            guard let next = larger.compactMap(\.ceiling).max() else { return (pulling.asks, nil) }
            let retry = state.nextAttempt
            state.nextAttempt += 1
            state.pulling[key] = Pulling(attempt: retry, ceiling: next, asks: larger)
            return (pulling.asks.filter { ($0.ceiling ?? 0) <= refused }, (retry, next))
        }
        if let error, !failing.isEmpty { failed(error) }
        for ask in failing { ask.completion(nil) }
        if let retry { start(key, retry.attempt, ceiling: retry.ceiling) }
    }

    /// The name an INLINE representation's file lands under, in a directory of its own.
    private static let inlineName = Data("content".utf8)
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
