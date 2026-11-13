import Foundation
import KernovaAgentCore
import KernovaKit
import KernovaLogging
import KernovaSynchronization
import KernovaTransferProgress
import KernovaWire

/// The far side's clipboard offer as this side received it, its items read whole, and the pulls that land its
/// representations here: each in a fresh directory of this side's clipboard staging, a FILE or FOLDER under the
/// name the offer gives it, an INLINE one as a file of its bytes, served mapped — but a concealed offer's INLINE
/// one in memory, within the paste ceiling, since staging persists and a password must reach no disk.
///
/// A representation is pulled once and kept for every later ask whose limit admits it, so a paste served before
/// the offer ended still serves after. Its pulls together land no more than the paste ceiling as it stood at
/// the first of them: one budget the sink charges each landed byte to. Ending the offer
/// here cancels every pull still running and fails everyone waiting on one.
///
/// Its pulls report on one readout while they run, each pull a unit its landing feeds; the readout ends once no
/// pull has run for its idle gap, since nothing says a paste is done asking, or once a copy's pulls have all
/// landed (``finishReadout()``). Its Cancel spends the offer: every pull in flight stops and the offer closes, so
/// no later ask of any write of it pulls anything, and pasting again takes a fresh copy on the far side.
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
    /// The connection the offer arrived on.
    public let connection: ClipboardConnectionID
    /// A copy's: how many items of the far side's clipboard it does not carry whole.
    public let leftOut: Int
    /// The offer as a write of it serves it.
    public var serving: ClipboardWriteSource.Serving { .init(token: token, connection: connection) }

    private let link: any ClipboardItemLink
    private let staging: ClipboardFileStaging
    private let generation: UInt64
    private let ceiling: @Sendable () -> UInt64
    private let registry: ClipboardPullRegistry
    private let logger: KernovaLogger
    private let landed: @Sendable () -> Void
    private let failed: @Sendable (WireError) -> Void
    private let progress: Progress
    private let state = Locked(State())

    /// What the offer's readout reports: the gesture its pulls serve, the side's reporter, the far side's name,
    /// and the clock the readout is measured on.
    struct Progress: Sendable {
        var gesture: ClipboardTransferGesture
        var transfers: ClipboardTransferReporter
        var peerName: String
        var clock: any EngineClock
    }

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

    /// What an ask of a representation hears.
    private enum Answer: Sendable {
        case content(Content)
        /// The readout's Cancel stopped the pull it waited on.
        case cancelled
        /// Nothing it takes landed, and the error the pull failed with when its end said.
        case missing(WireError?)

        /// What landed, nil when nothing did.
        var content: Content? {
            if case .content(let content) = self { content } else { nil }
        }
    }

    /// One ask of a representation: the most bytes it takes, nil for a FILE or FOLDER ask, and its completion.
    private struct Ask {
        var ceiling: UInt64?
        var completion: @Sendable (Answer) -> Void
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
        /// What it reports on the readout.
        var unit: ClipboardTransferOperation.Unit?
        /// The readout's Cancel stopped it, so its end is no failure.
        var cancelled = false
    }

    private struct State {
        var landed: [Key: Landed] = [:]
        var pulling: [Key: Pulling] = [:]
        var opened: [ItemPullID: Opened] = [:]
        /// What every pull of the offer lands against, from the first of them.
        var budget: ByteBudget?
        var nextAttempt: UInt64 = 0
        /// No more pulls: released, the far side ended the offer, or a readout's Cancel spent it.
        var closed = false
        /// Hear the offer close.
        var endHandlers: [@Sendable () -> Void] = []
        /// The readout the pulls report on, from the first pull after the last one ended.
        var readout: ClipboardTransferOperation?
    }

    init(
        header: ItemSetHeaderValue, items: [OfferedItem], link: any ClipboardItemLink,
        connection: ClipboardConnectionID, staging: ClipboardFileStaging, generation: UInt64,
        ceiling: @escaping @Sendable () -> UInt64,
        registry: ClipboardPullRegistry, logger: KernovaLogger, progress: Progress,
        landed: @escaping @Sendable () -> Void, failed: @escaping @Sendable (WireError) -> Void
    ) {
        token = header.token
        concealed = header.concealed
        leftOut = header.leftOut
        self.items = items
        self.link = link
        self.connection = connection
        self.staging = staging
        self.generation = generation
        self.ceiling = ceiling
        self.registry = registry
        self.logger = logger
        self.landed = landed
        self.failed = failed
        self.progress = progress
    }

    // MARK: ClipboardItemPulling

    /// The bytes of INLINE representation `representation` of item `item`, under the paste ceiling.
    public func pullBytes(item: Int, representation: Int, completion: @escaping @Sendable (Data?) -> Void) {
        ask(Key(item: item, representation: representation), ceiling: ceiling()) { completion($0.content?.bytes) }
    }

    /// The file or folder FILE or FOLDER representation `representation` of item `item` landed at, its bytes
    /// charged to the offer's budget.
    public func pullFile(item: Int, representation: Int, completion: @escaping @Sendable (URL?) -> Void) {
        ask(Key(item: item, representation: representation), ceiling: nil) { completion($0.content?.url) }
    }

    /// Runs `handler` once the offer closes — released, ended by the far side, its connection gone, or spent by its
    /// readout's Cancel — at once when it has.
    public func whenEnded(_ handler: @escaping @Sendable () -> Void) {
        let closed = state.withLock { state -> Bool in
            if !state.closed { state.endHandlers.append(handler) }
            return state.closed
        }
        if closed { handler() }
    }

    /// How landing a copy's INLINE representations ended (``landInline()``).
    public enum InlineLanding: Sendable, Equatable {
        /// Every one landed.
        case landed
        /// The readout's Cancel stopped a pull of one.
        case cancelled
        /// A pull of one failed with this error.
        case failed(WireError)
    }

    /// Pulls every kept INLINE representation now, all at once, and waits for each: landed once all landed, or
    /// how the first not to land ended. What a copy is written from.
    public func landInline() async -> InlineLanding {
        var keys: [Key] = []
        for (item, offered) in items.enumerated() {
            for (index, representation) in offered.representations.enumerated()
            where representation.storage == .inline && !representation.hasReference
                && ClipboardPromisePolicy.keeps(representation)
            {
                keys.append(Key(item: item, representation: index))
            }
        }
        return await withTaskGroup(of: InlineLanding.self) { group in
            for key in keys { group.addTask { await self.land(key) } }
            for await landing in group where landing != .landed {
                group.cancelAll()
                return landing
            }
            return .landed
        }
    }

    /// What this side holds of representation `representation` of item `item` now: an INLINE one's bytes, or
    /// the file or folder a FILE or FOLDER one landed at or was filled with; nil until it has either.
    public func held(item: Int, representation: Int) -> ClipboardWriteSource.Held? {
        guard let landed = state.withLock({ $0.landed[Key(item: item, representation: representation)] }) else {
            return nil
        }
        if landed.byteCount != nil { return landed.content.bytes.map(ClipboardWriteSource.Held.bytes) }
        return landed.content.url.map(ClipboardWriteSource.Held.file)
    }

    /// Deletes every INLINE representation that landed in staging: a copy's end wrote it as data, or chose not
    /// to write it, so nothing reads it from staging again. A write holding its bytes mapped keeps them readable
    /// until it lets them go; the disk they take is freed then.
    public func discardStagedInline() {
        let staged = state.withLock { state -> [URL] in
            var staged: [URL] = []
            for (key, landed) in state.landed where landed.byteCount != nil {
                guard case .staged(let url) = landed.content else { continue }
                staged.append(url)
                state.landed[key] = nil
            }
            return staged
        }
        // Each INLINE pull lands alone in a directory reserved for it.
        for url in staged { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    /// Every representation that names this side's own offer by reference, which nothing pulls.
    public var references: [(item: Int, representation: Int, reference: RepresentationReference)] {
        items.enumerated().flatMap { index, item in
            item.representations.enumerated().compactMap { position, representation in
                representation.hasReference ? (index, position, representation.reference) : nil
            }
        }
    }

    /// Whether every representation of the copy names this side's own offer by reference.
    public var isOnlyReferences: Bool {
        !items.isEmpty
            && items.allSatisfy { !$0.representations.isEmpty && $0.representations.allSatisfy(\.hasReference) }
    }

    /// Fills reference `representation` of item `item` with what this side's own offer gives: bytes, or a file
    /// or folder, which a FILE or FOLDER that lives in staging of that offer's own is first cloned into this
    /// offer's, since that staging goes with the offer. Returns whether it was filled.
    public func fill(item: Int, representation: Int, with served: ClipboardServedRepresentation, copying: Bool)
        async -> Bool
    {
        let key = Key(item: item, representation: representation)
        guard items.indices.contains(item), items[item].representations.indices.contains(representation),
            items[item].representations[representation].hasReference
        else { return false }
        let landed: Landed
        switch served {
        case .bytes(let data):
            landed = Landed(content: .memory(data), byteCount: UInt64(data.count))
        case .file(let url), .folder(let url):
            guard copying else {
                landed = Landed(content: .staged(url))
                break
            }
            let staging = staging
            let generation = generation
            let clone = await Task.detached { () -> URL? in
                guard let directory = try? staging.reserveScratchDirectory(generation: generation) else { return nil }
                let destination = directory.appendingPathComponent(url.lastPathComponent)
                // On APFS a copy is a clone: no bytes are copied.
                return (try? FileManager.default.copyItem(at: url, to: destination)).map { destination }
            }.value
            guard let clone else { return false }
            landed = Landed(content: .staged(clone))
        }
        state.withLock { $0.landed[key] = landed }
        return true
    }

    private func land(_ key: Key) async -> InlineLanding {
        let answer = await withCheckedContinuation { continuation in
            ask(key, ceiling: ceiling()) { continuation.resume(returning: $0) }
        }
        switch answer {
        case .content: return .landed
        case .cancelled: return .cancelled
        case .missing(let error):
            return .failed(error ?? WireError(.readFailed, debugDetail: "the representation did not land"))
        }
    }

    // MARK: Lifecycle

    /// Ends the offer here: what landed stays servable, nothing more is pulled, every pull in flight is
    /// cancelled, everyone waiting on one hears nil now, and a readout still measuring goes without a finish.
    func close() {
        end(.closed)
    }

    /// The readout's Cancel: the offer ends as ``close()`` ends it, except that its pulls in flight end as
    /// cancelled rather than failed, everyone waiting on one hears it cancelled — a paste hears nil — and the
    /// readout finishes cancelled if a pull was in flight, completed if not.
    private func spend() {
        end(.cancelled)
    }

    private enum Ending {
        case closed
        case cancelled
    }

    private func end(_ ending: Ending) {
        let (ids, asks, ended, readout) = state.withLock {
            state -> ([ItemPullID], [Ask], [@Sendable () -> Void], ClipboardTransferOperation?) in
            state.closed = true
            let pulling = state.pulling.values
            state.pulling = [:]
            let ids = pulling.compactMap(\.id)
            if ending == .cancelled { for id in ids { state.opened[id]?.cancelled = true } }
            defer {
                state.endHandlers = []
                state.readout = nil
            }
            return (ids, pulling.flatMap(\.asks), state.endHandlers, state.readout)
        }
        switch ending {
        case .closed: readout?.abandon()
        case .cancelled: readout?.finishCancelled()
        }
        for id in ids { link.cancelPull(id) }
        for ask in asks { ask.completion(ending == .cancelled ? .cancelled : .missing(nil)) }
        for handler in ended { handler() }
    }

    /// Ends the readout now, by its pulls' outcome, rather than at its idle gap: for an owner that knows no more
    /// asks follow — a copy whose pulls have all landed. A later ask pulls on a readout of its own.
    func finishReadout() {
        let readout = state.withLock { state -> ClipboardTransferOperation? in
            defer { state.readout = nil }
            return state.readout
        }
        readout?.finish(.completed)
    }

    /// A pull's unit on the readout the offer's pulls report on: the one running, or a new one when the last has
    /// ended.
    private func readoutUnit(name: String?, expectedBytes: UInt64) -> ClipboardTransferOperation.Unit? {
        state.withLock { state in
            if let unit = state.readout?.unit(name: name, expectedBytes: expectedBytes) { return unit }
            let readout = ClipboardTransferOperation(
                gesture: progress.gesture, direction: .inbound, peerName: progress.peerName,
                clock: progress.clock,
                onCancelRequested: { [weak self] in self?.spend() },
                reporter: progress.transfers)
            state.readout = readout
            return readout.unit(name: name, expectedBytes: expectedBytes)
        }
    }

    /// A pull of the offer ended, reporting on `unit`, `failure` saying why when it failed: the readout ends once
    /// no pull has run for its idle gap.
    private func pullEnded(
        _ unit: ClipboardTransferOperation.Unit?, landed: Bool, failure: ClipboardTransferFailure? = nil
    ) {
        if let failure { unit?.failed(failure) }
        unit?.ended(succeeded: landed)
        state.withLock(\.readout)?.finishWhenIdle()
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

    /// Whether the offer is still pullable: the far side's, and no readout's Cancel spent it.
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
            let failure =
                opened.cancelled ? nil : error.map { ClipboardTransferFailure(pullEndedWith: $0, fileCount: nil) }
            // The unit ends before anyone waiting hears, so a landing that acts on the answer finds it ended.
            pullEnded(opened.unit, landed: false, failure: failure)
            return settle(opened.key, opened.attempt, failedWith: error)
        }
        pullEnded(opened.unit, landed: true)
        self.landed()
        let asks = state.withLock { state -> [Ask] in
            state.landed[opened.key] = landed
            guard state.pulling[opened.key]?.attempt == opened.attempt else { return [] }
            return state.pulling.removeValue(forKey: opened.key)?.asks ?? []
        }
        for ask in asks { ask.completion(landed.admitted(by: ask.ceiling) ? .content(landed.content) : .missing(nil)) }
    }

    // MARK: Pulling

    /// Answers `completion` from what landed, or joins or starts the pull of `key`.
    private func ask(_ key: Key, ceiling: UInt64?, _ completion: @escaping @Sendable (Answer) -> Void) {
        enum Next {
            case answer(Answer)
            case joined
            case start(attempt: UInt64, ceiling: UInt64?)
        }
        guard items.indices.contains(key.item), items[key.item].representations.indices.contains(key.representation)
        else { return completion(.missing(nil)) }
        let isReference = items[key.item].representations[key.representation].hasReference
        let isInline = items[key.item].representations[key.representation].storage == .inline
        let ask = Ask(ceiling: isInline ? ceiling ?? 0 : nil, completion: completion)
        let next = state.withLock { state -> Next in
            if let landed = state.landed[key] {
                return .answer(landed.admitted(by: ask.ceiling) ? .content(landed.content) : .missing(nil))
            }
            if state.pulling[key] != nil {
                state.pulling[key]?.asks.append(ask)
                return .joined
            }
            // A reference names this side's own offer: nothing of it crosses the wire.
            guard !state.closed, !isReference else { return .answer(.missing(nil)) }
            let attempt = state.nextAttempt
            state.nextAttempt += 1
            state.pulling[key] = Pulling(attempt: attempt, ceiling: ask.ceiling, asks: [ask])
            return .start(attempt: attempt, ceiling: ask.ceiling)
        }
        switch next {
        case .answer(let answer): completion(answer)
        case .joined: break
        case .start(let attempt, let ceiling): start(key, attempt, ceiling: ceiling)
        }
    }

    /// Opens attempt `attempt` at pulling `key`, an INLINE pull no larger than `ceiling`, or settles it failed. A
    /// concealed offer's INLINE representation lands in memory: a password never reaches staging, which persists.
    private func start(_ key: Key, _ attempt: UInt64, ceiling: UInt64?) {
        let representation = items[key.item].representations[key.representation]
        let isInline = representation.storage == .inline
        let unit = readoutUnit(
            name: representation.name.isEmpty ? nil : String(decoding: representation.name, as: UTF8.self),
            expectedBytes: representation.sizeEstimate)
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
            // Every landing is charged, in memory or staged: the offer's INLINE representations hold no more
            // between them than the paste ceiling, nor its files beside them.
            let budget = offerBudget()
            order = try link.order(
                token: token, item: UInt32(key.item), representation: UInt32(key.representation),
                byteCeiling: min(budget.remaining, ceiling ?? .max), landing: landing,
                budget: budget, progress: unit)
        } catch {
            logger.log(.error, "Cannot land a clipboard pull: \(String(describing: error), privacy: .public)")
            pullEnded(
                unit, landed: false,
                failure: (error as? WireError).map { ClipboardTransferFailure(pullEndedWith: $0, fileCount: nil) }
                    ?? .stagingFailed)
            return settle(key, attempt, failedWith: nil)
        }
        link.pullItem(order) { [self] result in
            switch result {
            case .success(let id):
                let wanted = state.withLock { state -> Bool in
                    guard state.pulling[key]?.attempt == attempt else { return false }
                    state.pulling[key]?.id = id
                    state.opened[id] = Opened(
                        key: key, attempt: attempt, directory: directory, isInline: isInline, unit: unit)
                    return true
                }
                guard wanted else {
                    pullEnded(unit, landed: false)
                    return link.cancelPull(id)
                }
                registry.register(id, self)
            case .failure(let error):
                logger.log(.notice, "A clipboard pull did not open: \(String(describing: error), privacy: .public)")
                pullEnded(unit, landed: false, failure: ClipboardTransferFailure(pullEndedWith: error, fileCount: nil))
                settle(key, attempt, failedWith: error)
            }
        }
    }

    /// What the offer's pulls may still land: the budget's remainder, or the paste ceiling before the first.
    public var pasteRoom: UInt64 {
        state.withLock { $0.budget?.remaining } ?? ceiling()
    }

    /// The budget every pull of the offer lands against: the paste ceiling as it stands at the first of them.
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
        for ask in failing { ask.completion(.missing(error)) }
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
