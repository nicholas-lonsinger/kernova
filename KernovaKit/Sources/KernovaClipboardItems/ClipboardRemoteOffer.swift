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
/// Its pulls report as a paste on one readout per run of them: the first pull starts a run, and the run ends at
/// its idle gap with nothing in flight (``ClipboardTransferOperation/finishWhenIdle()``), the next pull starting
/// the next one. A pull that fails records its failure there, so the run ends failed. The readout's Cancel spends
/// the offer: no later ask pulls anything, the pulls in flight are cancelled, and the side's exchange lets the
/// offer go (``ClipboardItemExchange/RemoteEnding/cancelledHere``).
///
/// Safe from any thread: a paste asks on whatever thread the pasteboard fires its provider on, and a pull ends
/// on the connection's queue, so neither waits for the main actor.
final class ClipboardRemoteOffer: ClipboardItemPulling, Sendable {
    /// How this side ending the offer leaves a run of pulls it cuts short.
    enum Closing: Sendable {
        /// The link, the clipboard setting or the far side ended it: the run fails, interrupted.
        case interrupted
        /// This side let it go — its clipboard moved on, or a Cancel spent it: the run ends unreported.
        case letGo
    }

    /// The 16 bytes naming the offer.
    let token: Data
    /// The far side marked the content concealed.
    let concealed: Bool
    /// The items, in the order the offer sent them.
    let items: [OfferedItem]

    private let link: any ClipboardItemLink
    private let staging: ClipboardFileStaging
    private let generation: UInt64
    private let ceiling: @Sendable () -> UInt64
    private let registry: ClipboardPullRegistry
    private let logger: KernovaLogger
    private let readouts: ClipboardPasteReadouts.Resolved
    private let landed: @Sendable () -> Void
    private let failed: @Sendable (WireError) -> Void
    private let cancelled: @MainActor @Sendable (ClipboardRemoteOffer) -> Void
    private let state = Locked(State())

    /// One representation of one item.
    private struct Key: Hashable, Sendable {
        var item: Int
        var representation: Int

        /// The unit its pulls report as on the readout, every attempt at it the same one.
        var unit: UInt64 { UInt64(item) << 32 | UInt64(representation) }
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
        /// What every pull of the offer lands against, from the first of them.
        var budget: ByteBudget?
        var nextAttempt: UInt64 = 0
        /// No more pulls: released, or the far side ended the offer.
        var closed = false
        /// The readout of the run of pulls under way, or of the last one; nil once this side let a run in flight go.
        var readout: ClipboardTransferOperation?
    }

    init(
        header: ItemSetHeaderValue, items: [OfferedItem], link: any ClipboardItemLink, staging: ClipboardFileStaging,
        generation: UInt64, ceiling: @escaping @Sendable () -> UInt64, registry: ClipboardPullRegistry,
        logger: KernovaLogger, readouts: ClipboardPasteReadouts.Resolved, landed: @escaping @Sendable () -> Void,
        failed: @escaping @Sendable (WireError) -> Void,
        cancelled: @escaping @MainActor @Sendable (ClipboardRemoteOffer) -> Void
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
        self.readouts = readouts
        self.landed = landed
        self.failed = failed
        self.cancelled = cancelled
    }

    // MARK: ClipboardItemPulling

    /// The bytes of INLINE representation `representation` of item `item`, under the paste ceiling.
    func pullBytes(item: Int, representation: Int, completion: @escaping @Sendable (Data?) -> Void) {
        ask(Key(item: item, representation: representation), ceiling: ceiling()) { completion($0?.bytes) }
    }

    /// The file or folder FILE or FOLDER representation `representation` of item `item` landed at, its bytes
    /// charged to the offer's budget.
    func pullFile(item: Int, representation: Int, completion: @escaping @Sendable (URL?) -> Void) {
        ask(Key(item: item, representation: representation), ceiling: nil) { completion($0?.url) }
    }

    // MARK: Lifecycle

    /// Ends the offer here: what landed stays servable, nothing more is pulled, every pull in flight is
    /// cancelled, and everyone waiting on one hears nil now. A run with pulls in flight ends as `closing` says.
    func close(_ closing: Closing) {
        let (ids, asks, interrupted) = state.withLock { state -> ([ItemPullID], [Ask], ClipboardTransferOperation?) in
            state.closed = true
            let pulling = state.pulling.values
            state.pulling = [:]
            guard !pulling.isEmpty else { return ([], [], nil) }
            let interrupted: ClipboardTransferOperation?
            switch closing {
            case .interrupted: interrupted = state.readout
            case .letGo:
                // Let go, the readout retires unreported (`ClipboardTransferOperation`'s deinit).
                state.readout = nil
                interrupted = nil
            }
            return (pulling.compactMap(\.id), pulling.flatMap(\.asks), interrupted)
        }
        interrupted?.finish(.failed(.interrupted(fileCount: nil)))
        for id in ids { link.cancelPull(id) }
        for ask in asks { ask.completion(nil) }
    }

    /// Ends the offer here as ``close(_:)`` does, and tells the far side, over the connection it arrived on, that
    /// this side pulls nothing more of it.
    func release(_ closing: Closing) {
        close(closing)
        link.releaseOffer(token)
    }

    /// The pull `id` of this offer landed further, as `landing` says.
    func advanced(_ id: ItemPullID, _ landing: ItemLandingProgress) {
        guard let (key, readout) = state.withLock({ state in state.opened[id].map { ($0.key, state.readout) } }),
            let readout
        else { return }
        readout.unitProgressed(id: key.unit, landed: landing.landed, declared: landing.declared)
    }

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
            let error = result.error ?? WireError(.internal, debugDetail: "it landed nothing this side can serve")
            return settle(opened.key, opened.attempt, failedWith: error)
        }
        self.landed()
        let (asks, readout) = state.withLock { state -> ([Ask], ClipboardTransferOperation?) in
            state.landed[opened.key] = landed
            guard state.pulling[opened.key]?.attempt == opened.attempt else { return ([], state.readout) }
            return (state.pulling.removeValue(forKey: opened.key)?.asks ?? [], state.readout)
        }
        readout?.unitEnded(id: opened.key.unit, succeeded: true)
        readout?.finishWhenIdle()
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
            guard !state.closed, began(key, in: &state) else { return .answer(nil) }
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

    /// Begins `key`'s unit on the run's readout, a run whose idle gap ended it giving way to a new one; false when a
    /// Cancel ended it, which spends the offer. Under the lock every pull starts under, so no pull starts once the
    /// Cancel has ended the run, even before its stop closes the offer.
    private func began(_ key: Key, in state: inout State) -> Bool {
        let representation = items[key.item].representations[key.representation]
        let name = representation.storage == .inline ? nil : String(decoding: representation.name, as: UTF8.self)
        if let readout = state.readout {
            if readout.unitBegan(id: key.unit, expectedBytes: representation.sizeEstimate, name: name) { return true }
            if readout.wasCancelled { return false }
        }
        let readout = ClipboardTransferOperation(
            gesture: .paste, direction: .inbound, peerName: readouts.peerName, revealDelay: readouts.revealDelay,
            clock: readouts.clock, onCancelRequested: { [weak self] in self?.cancelledHere() },
            reporter: readouts.reporter)
        state.readout = readout
        let reporter = readouts.reporter
        // A run is a gesture of its own, so a refusal it repeats is news (`ClipboardTransferReporter.gestureBegan`);
        // the hop is queued ahead of every publication of the run's.
        DispatchQueue.main.async { MainActor.assumeIsolated { reporter.gestureBegan() } }
        readout.unitBegan(id: key.unit, expectedBytes: representation.sizeEstimate, name: name)
        return true
    }

    /// The readout's Cancel ended the run: the offer is spent, and the exchange lets it go.
    @MainActor
    private func cancelledHere() {
        close(.letGo)
        cancelled(self)
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
            // Every landing is charged, in memory or staged: the offer's INLINE representations hold no more
            // between them than the paste ceiling, nor its files beside them.
            let budget = offerBudget()
            order = try link.order(
                token: token, item: UInt32(key.item), representation: UInt32(key.representation),
                byteCeiling: min(budget.remaining, ceiling ?? .max), landing: landing,
                budget: budget)
        } catch {
            logger.log(.error, "Cannot land a clipboard pull: \(String(describing: error), privacy: .public)")
            let landingError =
                error as? WireError ?? WireError(.writeFailed, debugDetail: "its staging: \(error)")
            return settle(key, attempt, failedWith: landingError)
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

    /// The budget every pull of the offer lands against: the paste ceiling as it stands at the first of them.
    private func offerBudget() -> ByteBudget {
        state.withLock { state in
            if let budget = state.budget { return budget }
            let budget = ByteBudget(limit: ceiling())
            state.budget = budget
            return budget
        }
    }

    /// Attempt `attempt` at pulling `key` landed nothing, failing with `error`. A TOO_LARGE INLINE pull is pulled
    /// again, its unit starting over, for the asks that take more than it did; every other ask hears nil, and its
    /// owner and the run's readout hear the failure, over the offer's budget for a TOO_LARGE one.
    private func settle(_ key: Key, _ attempt: UInt64, failedWith error: WireError) {
        let (failing, retry, readout) = state.withLock {
            state -> ([Ask], (attempt: UInt64, ceiling: UInt64)?, ClipboardTransferOperation?) in
            guard let pulling = state.pulling[key], pulling.attempt == attempt else { return ([], nil, nil) }
            state.pulling[key] = nil
            let readout = state.readout
            var failing = pulling.asks
            var retry: (attempt: UInt64, ceiling: UInt64)?
            if error.code == .tooLarge, let refused = pulling.ceiling,
                let next = pulling.asks.compactMap(\.ceiling).filter({ $0 > refused }).max()
            {
                // The attempt ends here, and the retry begins its unit again.
                readout?.unitEnded(id: key.unit, succeeded: false)
                if began(key, in: &state) {
                    let attempt = state.nextAttempt
                    state.nextAttempt += 1
                    let larger = pulling.asks.filter { ($0.ceiling ?? 0) > refused }
                    state.pulling[key] = Pulling(attempt: attempt, ceiling: next, asks: larger)
                    retry = (attempt, next)
                    failing = pulling.asks.filter { ($0.ceiling ?? 0) <= refused }
                }
            }
            if !failing.isEmpty {
                readout?.recordShortfall(
                    ClipboardTransferFailure(pullEndedWith: error, fileCount: nil, limitBytes: state.budget?.limit))
            }
            if retry == nil { readout?.unitEnded(id: key.unit, succeeded: false) }
            return (failing, retry, readout)
        }
        if !failing.isEmpty { failed(error) }
        for ask in failing { ask.completion(nil) }
        if let retry {
            start(key, retry.attempt, ceiling: retry.ceiling)
        } else {
            readout?.finishWhenIdle()
        }
    }

    /// The name an INLINE representation's file lands under, in a directory of its own.
    private static let inlineName = Data("content".utf8)
}

/// Where an end reports the runs of pulls its pastes make of the far side's offers (``ClipboardRemoteOffer``):
/// on `reporter`, under the far side's name as `peerName` gives it when each offer arrives, each readout showing
/// once it has run `revealDelay` and timed on `clock`.
public struct ClipboardPasteReadouts {
    let reporter: ClipboardTransferReporter
    let peerName: @MainActor () -> String
    let revealDelay: TimeInterval
    let clock: any EngineClock

    public init(
        reporter: ClipboardTransferReporter, peerName: @escaping @MainActor () -> String,
        revealDelay: TimeInterval = ClipboardTransferOperation.defaultRevealDelay,
        clock: any EngineClock = makePlatformEngineClock()
    ) {
        self.reporter = reporter
        self.peerName = peerName
        self.revealDelay = revealDelay
        self.clock = clock
    }

    /// What one offer's readouts are built from: these, its far side named as it arrived.
    struct Resolved: Sendable {
        let reporter: ClipboardTransferReporter
        let peerName: String
        let revealDelay: TimeInterval
        let clock: any EngineClock
    }

    @MainActor
    func resolved() -> Resolved {
        Resolved(reporter: reporter, peerName: peerName(), revealDelay: revealDelay, clock: clock)
    }
}

/// Which remote offer each open pull belongs to, so a pull's progress and end reach it from the connection's
/// queue.
final class ClipboardPullRegistry: Sendable {
    private let pulls = Locked<[ItemPullID: ClipboardRemoteOffer]>([:])

    func register(_ id: ItemPullID, _ offer: ClipboardRemoteOffer) {
        pulls.withLock { $0[id] = offer }
    }

    /// Hands pull `id`'s progress to its offer.
    func advanced(_ id: ItemPullID, _ landing: ItemLandingProgress) {
        pulls.withLock { $0[id] }?.advanced(id, landing)
    }

    /// Hands pull `id`'s end to its offer.
    func ended(_ id: ItemPullID, _ result: ItemPullResult) {
        pulls.withLock { $0.removeValue(forKey: id) }?.ended(id, result)
    }
}
