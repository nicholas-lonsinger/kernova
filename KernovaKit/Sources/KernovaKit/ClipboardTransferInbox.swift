import Foundation

/// The transfers this side is waiting for, one data connection each.
///
/// A pull registers what it expects with ``awaitTransfer(_:plan:onComplete:onAbort:onProgress:)``
/// before the transfer can arrive, then either opens the connection itself
/// (``open(transferID:generation:maxAcceptByteCount:dial:)``, when this side
/// dials) or adopts one its listener accepted (``adopt(fd:reply:)``). Callbacks
/// fire off the owning actor, on the transfer's own queue, exactly once.
final class ClipboardTransferInbox: @unchecked Sendable {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "ClipboardTransferInbox")

    /// What one awaited transfer expects, and who to tell when it resolves.
    private struct Awaiter {
        let plan: ClipboardTransferReceiver.Plan
        let onComplete: @Sendable (ClipboardContent.Representation) -> Void
        let onAbort: @Sendable (ClipboardStreamAbortInfo) -> Void
        let onProgress: (@Sendable (_ bytesReceived: Int, _ totalBytes: Int) -> Void)?
    }

    private let staging: ClipboardFileStaging
    private let clock: any EngineClock
    private let socketTimeout: TimeInterval
    private let maxResidentInlineBytes: Int
    private let minimumExtractAllowance: Int
    private let extractPacingBytes: Int
    private let onTransferTimed: (@Sendable (ClipboardTransferMetrics) -> Void)?

    private let lock = NSLock()
    private var awaiters: [UInt64: Awaiter] = [:]
    private var live: [UInt64: ClipboardTransferReceiver] = [:]

    #if DEBUG
    /// Fired after a live receiver's terminal has been processed — its
    /// connection already closed — for a test sequencing a peer against the
    /// teardown rather than against the awaiter's own resolution.
    var onReceiverFinishedForTesting: (@Sendable (UInt64) -> Void)? {
        get { lock.withLock { receiverFinishedHook } }
        set { lock.withLock { receiverFinishedHook = newValue } }
    }
    private var receiverFinishedHook: (@Sendable (UInt64) -> Void)?
    #endif

    /// Creates an inbox for one peer.
    ///
    /// - Parameters:
    ///   - staging: where archived payloads are extracted.
    ///   - clock: the timeline stage timings are measured on.
    ///   - socketTimeout: each connection's `SO_RCVTIMEO`/`SO_SNDTIMEO`.
    ///   - maxResidentInlineBytes: the most a raw payload may declare.
    ///   - minimumExtractAllowance: floor on what a streamed folder may
    ///     extract.
    ///   - extractPacingBytes: output granularity of the extract's guard.
    ///   - onTransferTimed: fired once per successful transfer.
    init(
        staging: ClipboardFileStaging,
        clock: any EngineClock = makePlatformEngineClock(),
        socketTimeout: TimeInterval = ClipboardStreamTuning.dataSocketTimeout,
        maxResidentInlineBytes: Int = ClipboardStreamTuning.maxResidentInlineBytes,
        minimumExtractAllowance: Int = ClipboardStreamTuning.minimumExtractAllowance,
        extractPacingBytes: Int = ClipboardStreamTuning.extractPacingBytes,
        onTransferTimed: (@Sendable (ClipboardTransferMetrics) -> Void)? = nil
    ) {
        self.staging = staging
        self.clock = clock
        self.socketTimeout = socketTimeout
        self.maxResidentInlineBytes = maxResidentInlineBytes
        self.minimumExtractAllowance = minimumExtractAllowance
        self.extractPacingBytes = extractPacingBytes
        self.onTransferTimed = onTransferTimed
    }

    /// Registers what a pull expects of one transfer, before it can arrive.
    ///
    /// One live registration per id: callers sharing a `transfer_id` share the
    /// pull that owns it (`LazyPullCoordinator`), so an overwrite here would be
    /// a second pull nobody asked for.
    func awaitTransfer(
        _ transferID: UInt64,
        plan: ClipboardTransferReceiver.Plan,
        onComplete: @escaping @Sendable (ClipboardContent.Representation) -> Void,
        onAbort: @escaping @Sendable (ClipboardStreamAbortInfo) -> Void,
        onProgress: (@Sendable (_ bytesReceived: Int, _ totalBytes: Int) -> Void)? = nil
    ) {
        let displaced: Bool = lock.withLock {
            let prior = awaiters.updateValue(
                Awaiter(
                    plan: plan, onComplete: onComplete, onAbort: onAbort, onProgress: onProgress),
                forKey: transferID)
            return prior != nil
        }
        guard displaced else { return }
        Self.logger.fault(
            "Clipboard transfer \(transferID, privacy: .public) was awaited twice — the earlier awaiter is dropped"
        )
        assertionFailure("Clipboard transfer \(transferID) was awaited twice")
    }

    /// Deregisters a pull's expectation without firing it.
    func cancelAwait(_ transferID: UInt64) {
        let (removed, receiver) = lock.withLock {
            (awaiters.removeValue(forKey: transferID) != nil, live[transferID])
        }
        guard removed else { return }
        receiver?.cancel()
    }

    /// Opens the connection for a transfer this side dials for, writing the
    /// request that names it.
    ///
    /// A no-op when nothing is awaiting `transferID` — there would be nowhere
    /// to deliver what arrived.
    func open(
        transferID: UInt64, generation: UInt64, maxAcceptByteCount: UInt64,
        dial: @escaping @Sendable () throws -> Int32
    ) {
        guard let awaiter = lock.withLock({ awaiters[transferID] }) else { return }
        let request = Kernova_V1_ClipboardTransferRequest.with {
            $0.generation = generation
            $0.transferID = transferID
            $0.uti = awaiter.plan.uti
            $0.maxAcceptByteCount = maxAcceptByteCount
        }
        start(
            transferID: transferID, generation: generation, plan: awaiter.plan,
            source: .dial(dial, request: request))
    }

    /// Takes over a connection this side's listener accepted, matching it to the
    /// pull awaiting `reply.transfer_id`.
    ///
    /// A connection naming a transfer nothing is awaiting — or one this side
    /// cancelled — is closed rather than served, which is the refusal a peer
    /// sees for both.
    func adopt(fd: Int32, reply: Kernova_V1_ClipboardTransferReply) {
        guard let awaiter = lock.withLock({ awaiters[reply.transferID] }) else {
            Self.logger.debug(
                "Closing a data connection for clipboard transfer \(reply.transferID, privacy: .public) — nothing is awaiting it"
            )
            ClipboardDataConnection.end(fd: fd)
            return
        }
        start(
            transferID: reply.transferID,
            generation: ClipboardTransferID.generation(of: reply.transferID),
            plan: awaiter.plan, source: .accepted(fd: fd, reply: reply))
    }

    /// Abandons every transfer of a superseded generation, and wakes any pull
    /// awaiting one that never opened.
    func cancel(generation: UInt64) {
        cancelMatching { ClipboardTransferID.generation(of: $0) == generation }
    }

    /// Abandons one transfer, and wakes a pull awaiting it — the teardown for a
    /// single abandoned pull, leaving every sibling of the same generation
    /// streaming.
    func cancel(transferID: UInt64) {
        cancelMatching { $0 == transferID }
    }

    /// Abandons every transfer and wakes every pull awaiting this peer.
    func cancelAll() {
        cancelMatching { _ in true }
    }

    // MARK: - Private

    private func start(
        transferID: UInt64, generation: UInt64, plan: ClipboardTransferReceiver.Plan,
        source: ClipboardTransferReceiver.Source
    ) {
        let receiver = ClipboardTransferReceiver(
            transferID: transferID, generation: generation, source: source, plan: plan,
            staging: staging, clock: clock, socketTimeout: socketTimeout,
            maxResidentInlineBytes: maxResidentInlineBytes,
            minimumExtractAllowance: minimumExtractAllowance,
            extractPacingBytes: extractPacingBytes, onTransferTimed: onTransferTimed)
        // Ignore a second connection for an id already streaming rather than
        // let it displace the first, which would orphan an open connection.
        let inserted = lock.withLock { () -> Bool in
            guard live[transferID] == nil else { return false }
            live[transferID] = receiver
            return true
        }
        guard inserted else {
            if case .accepted(let fd, _) = source { ClipboardDataConnection.end(fd: fd) }
            return
        }
        receiver.start(
            onComplete: { [weak self] representation in
                self?.finish(transferID) { $0.onComplete(representation) }
            },
            onAbort: { [weak self] info in
                self?.finish(transferID) { $0.onAbort(info) }
            },
            onProgress: { [weak self] received, total in
                self?.progress(transferID, received: received, total: total)
            })
    }

    /// Delivers one transfer's terminal to its awaiter, exactly once.
    private func finish(_ transferID: UInt64, _ deliver: (Awaiter) -> Void) {
        let awaiter = lock.withLock { () -> Awaiter? in
            live[transferID] = nil
            return awaiters.removeValue(forKey: transferID)
        }
        if let awaiter { deliver(awaiter) }
        #if DEBUG
        onReceiverFinishedForTesting?(transferID)
        #endif
    }

    private func progress(_ transferID: UInt64, received: Int, total: Int) {
        let awaiter = lock.withLock { awaiters[transferID] }
        awaiter?.onProgress?(received, total)
    }

    /// Interrupts every live receiver whose id matches `predicate`, and fires
    /// (and removes) every matching awaiter, resolving a blocked pull with a
    /// cancellation.
    ///
    /// The awaiter fails here, synchronously — a blocked pull's wake must not
    /// wait on the receiver's teardown, whose cost scales with what the
    /// transfer already staged. Removing the awaiter under the lock also
    /// guarantees the pull resolves `cancelled`: a receiver completing
    /// concurrently finds no awaiter left to deliver to. The receiver's own
    /// later terminal is idempotent with this — whichever removes the awaiter
    /// first wins.
    private func cancelMatching(_ predicate: (UInt64) -> Bool) {
        let (receivers, matched) = lock.withLock {
            () -> ([ClipboardTransferReceiver], [UInt64: Awaiter]) in
            let receivers = live.filter { predicate($0.key) }.map(\.value)
            var taken: [UInt64: Awaiter] = [:]
            for id in awaiters.keys.filter(predicate) {
                taken[id] = awaiters.removeValue(forKey: id)
            }
            return (receivers, taken)
        }
        for receiver in receivers { receiver.cancel() }
        for (id, awaiter) in matched {
            awaiter.onAbort(
                ClipboardStreamAbortInfo(
                    transferID: id, code: .cancelled,
                    message: "Transfer superseded or connection closed",
                    neededBytes: nil, availableBytes: nil))
        }
    }
}
