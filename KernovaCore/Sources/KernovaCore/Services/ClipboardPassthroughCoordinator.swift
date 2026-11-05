import Foundation
import KernovaKit
import KernovaLogging

/// Drives automatic clipboard passthrough for one VM: it polls the host
/// pasteboard and offers copies made while the guest is connected, read as
/// metadata only, and writes inbound guest offers straight to the host
/// pasteboard.
///
/// Echo suppression is change-count based: a content digest can't be the key,
/// since an inbound write places lazy promised items whose digest need not
/// match the offer's.
@MainActor
final class ClipboardPassthroughCoordinator {
    /// The VM whose live clipboard service this drives, weak because `VMInstance`
    /// owns the coordinator.
    private weak var instance: VMInstance?

    /// The per-VM host-pasteboard writer, shared with the VM's clipboard
    /// commands, so the poll recognizes every write it makes (via
    /// `lastWriteChangeCount`) and never forwards one.
    private let publisher: HostClipboardPublisher

    /// The pasteboard polled for outbound changes and written for inbound
    /// offers: the publisher's own, so the poll sees every write it makes.
    private var pasteboard: any ClipboardPasteboard { publisher.pasteboard }

    /// This VM's transfer report, where a forward's lost items are recorded.
    private let reporter: ClipboardTransferReporter

    /// Poll cadence — matches `GuestClipboard.pollingInterval` so both
    /// ends of the boundary sample their pasteboards at the same rate.
    private static let pollInterval: TimeInterval = 0.5

    /// A run-loop timer, not a dispatch timer on `.main`: the poll reads promised
    /// flavors, which fire another VM's provider synchronously, and that fire's
    /// serviced wait can drain the main queue only when it is not itself inside
    /// a main-queue callout (`NestedEventLoopWait`).
    private var pollTimer: Timer?

    /// The outbound side of one guest connection, which forwards only Mac
    /// copies made after it came up
    /// (``ClipboardServicing/connectionStartChangeCount``), or after passthrough
    /// started on it (``start()``): neither a connection's start nor turning
    /// passthrough on sends what the Mac's clipboard already holds.
    ///
    /// A poll that finds a different connected service, or a new connection of
    /// the same one (``ClipboardServicing/connectionEpoch``), starts a new one,
    /// and a read launched for an old one never offers to its successor.
    @MainActor
    private final class OutboundConnection {
        weak var service: (any ClipboardServicing)?
        let epoch: UInt64

        /// The last host-pasteboard change count this connection has *settled* —
        /// the guest holds that copy, it predates the connection or passthrough's
        /// start, or nothing about it can change by offering it again.
        ///
        /// A forward advances this only once the transport gives a delivery
        /// verdict (`ClipboardGrabOutcome`): consuming the count of a copy the
        /// guest never received loses the copy outright, since later polls read
        /// the change count as unchanged and skip.
        var settledChangeCount: Int

        /// The change count of the forward whose read is still running.
        ///
        /// Neither settled nor retryable: polls firing during a multi-second
        /// folder walk must not launch a second walk of the same copy.
        var resolvingChangeCount: Int?

        init(service: any ClipboardServicing, settledChangeCount: Int) {
            self.service = service
            epoch = service.connectionEpoch
            self.settledChangeCount = settledChangeCount
        }

        func serves(_ service: any ClipboardServicing) -> Bool {
            self.service === service && epoch == service.connectionEpoch
        }
    }

    /// The connection the poll forwards to, `nil` while the guest is
    /// disconnected or passthrough is stopped.
    private var outbound: OutboundConnection?

    private var inboundObservation: ObservationLoop?

    /// The inbound publish in flight, held so `stop()` can cancel it and a newer
    /// offer can supersede it. The pasteboard write happens inside the
    /// publisher's await, so a session check after the await runs too late to
    /// stop it; only cancellation reaches the write.
    private var inboundPublishTask: Task<Void, Never>?

    /// The inbound-offer sequence already published to the host pasteboard, so a
    /// re-observation doesn't re-publish.
    private var lastInboundOfferSeq: UInt64 = 0

    /// The offer whose files the paste ceiling withheld.
    ///
    /// Carries the ceiling that withheld them and what the host pasteboard held
    /// once the refusal settled — the state `republishIfCeilingRaised()` acts on.
    ///
    /// The change count is captured here rather than compared against
    /// `outbound`'s settled count: a refusal that serves nothing performs no
    /// write, so that field still holds whatever the poll last absorbed and
    /// would answer a question about the poll's timing, not about the user.
    ///
    /// Cleared by any publish that drops nothing, so only a live refusal is ever
    /// replayed.
    private var budgetRefusedOffer: (seq: UInt64, ceiling: Int, pasteboardChangeCount: Int)?

    private var isRunning = false

    #if DEBUG
    /// Fires after each inbound auto-publish completes.
    var onInboundPublishedForTesting: (@MainActor () -> Void)?

    /// The inbound publish in flight, for a test to await its unwinding.
    var inboundPublishTaskForTesting: Task<Void, Never>? { inboundPublishTask }

    /// Fires once a forward's read has been handled, on every outcome — the
    /// seam a test needs to observe that a forward produced *nothing*, which no
    /// other signal announces.
    var onForwardResolvedForTesting: (@MainActor () -> Void)?

    /// How many forwards' reads have started, for a test to wait until each is
    /// handled.
    private(set) var forwardsStartedForTesting = 0
    #endif

    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "ClipboardPassthroughCoordinator")

    init(
        instance: VMInstance, publisher: HostClipboardPublisher,
        reporter: ClipboardTransferReporter
    ) {
        self.instance = instance
        self.publisher = publisher
        self.reporter = reporter
    }

    // MARK: - Lifecycle

    /// Arms the host-pasteboard poll and the inbound-offer observation, sending
    /// nothing: the Mac's copy and the guest's offer standing now stay where
    /// they are, and only a copy made after crosses.
    ///
    /// Idempotent.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        let service = instance?.clipboardService
        lastInboundOfferSeq = service?.inboundOfferSeq ?? 0
        if let service, service.isConnected {
            outbound = OutboundConnection(service: service, settledChangeCount: pasteboard.changeCount)
        }
        startPolling()
        observeInbound()
        Self.logger.log(
            .notice,
            "Clipboard passthrough started for '\(self.instance?.name ?? "?", privacy: .public)'")
    }

    /// Cancels the poll and observation.
    ///
    /// Idempotent.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        outbound = nil
        pollTimer?.invalidate()
        pollTimer = nil
        inboundObservation?.cancel()
        inboundObservation = nil
        inboundPublishTask?.cancel()
        inboundPublishTask = nil
        Self.logger.log(
            .notice,
            "Clipboard passthrough stopped for '\(self.instance?.name ?? "?", privacy: .public)'")
    }

    // MARK: - Host → guest (poll)

    private func startPolling() {
        // Default mode only: a tick that would land inside a tracking or modal
        // loop waits for the loop to end — the forward is late by that much —
        // rather than parking the main thread on the fire it reaches.
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) {
            [weak self] _ in
            // The main run loop fires this on the main thread.
            MainActor.assumeIsolated { self?.pollHostClipboard() }
        }
    }

    /// Forwards a host copy made while the current guest connection is up,
    /// skipping our own inbound writes.
    func pollHostClipboard() {
        guard let service = instance?.clipboardService, service.isConnected else {
            outbound = nil
            return
        }
        let connection = connection(to: service)
        let current = pasteboard.changeCount
        // Skip the change our own host-write produced, so guest content is never
        // re-forwarded back to the guest.
        if let selfWritten = publisher.lastWriteChangeCount, current == selfWritten {
            connection.settledChangeCount = current
            return
        }
        guard current != connection.settledChangeCount,
            current != connection.resolvingChangeCount
        else { return }
        forwardHostClipboard(current, over: connection, to: service)
    }

    /// The outbound side of `service`'s connection now, made the first time
    /// anything asks for it, settled where the connection started.
    private func connection(to service: any ClipboardServicing) -> OutboundConnection {
        if let outbound, outbound.serves(service) { return outbound }
        let connection = OutboundConnection(
            service: service, settledChangeCount: service.connectionStartChangeCount ?? pasteboard.changeCount)
        outbound = connection
        return connection
    }

    /// Whether the Mac's pasteboard holds a copy of the user's this connection
    /// has not settled — read now, or not read yet — which a guest offer made
    /// meanwhile crosses and loses to.
    var holdsUnsentCopy: Bool {
        guard isRunning, let service = instance?.clipboardService, service.isConnected else { return false }
        guard pasteboardHoldsUserCopy else { return false }
        return pasteboard.changeCount != connection(to: service).settledChangeCount
    }

    /// Whether the Mac's pasteboard holds a copy of the user's that may offer
    /// something: not this publisher's write, not empty, not marked transient.
    /// Read from its types alone, so nothing is fetched.
    private var pasteboardHoldsUserCopy: Bool {
        pasteboard.changeCount != publisher.lastWriteChangeCount && pasteboard.mayOfferSomething
    }

    /// Offers the Mac's copy now rather than at the next poll: a guest offer
    /// that crossed it was refused on the strength of it being on its way.
    func forwardNow() {
        guard isRunning else { return }
        pollHostClipboard()
    }

    /// Reads the host pasteboard's copy, metadata only, and offers it to the guest, settling `changeCount` only
    /// once the copy needs no retry.
    ///
    /// The read stats copied files off the main actor, so it is never synchronous; a poll during it starts no
    /// second read of the same copy.
    private func forwardHostClipboard(
        _ changeCount: Int, over connection: OutboundConnection, to service: any ClipboardServicing
    ) {
        // Each copy is a gesture of its own, so the refusal this one raises is
        // announced even when the copy before it raised the identical one — the
        // offer's own reset doesn't fire for content the guest already holds.
        reporter.gestureBegan()
        connection.resolvingChangeCount = changeCount
        #if DEBUG
        forwardsStartedForTesting += 1
        #endif
        let pasteboard = pasteboard
        let promises = pasteboard.filePromiseReceivers
        Task { @MainActor [weak self, weak service] in
            let read = await ClipboardPasteboardReader.readOffer(
                from: pasteboard, promises: promises,
                promiseDestination: {
                    guard let destination = service?.reservePromiseDestination() else {
                        throw ClipboardServeError.unavailable
                    }
                    return destination
                })
            #if DEBUG
            defer { self?.onForwardResolvedForTesting?() }
            #endif
            // Declared after the test hook so it runs before it (defers unwind in
            // reverse), leaving the connection ready to retry by the time the
            // hook observes it.
            defer {
                if connection.resolvingChangeCount == changeCount {
                    connection.resolvingChangeCount = nil
                }
            }
            guard let self, self.outbound === connection, let service = connection.service
            else { return }
            await self.offer(read, changeCount, over: connection, to: service)
        }
    }

    /// Offers what the read found, unless the host clipboard has moved on since — that copy is nobody's now, and
    /// the next poll takes whatever replaced it — and raises the items it lost once the copy is settled.
    ///
    /// The loss is raised *after* the offer, which clears the issue on a
    /// successful one, and only on `.settled`: an undelivered forward left
    /// nothing behind for the user to act on yet, and reporting each attempt
    /// would file one transfer report per poll until the retry lands.
    private func offer(
        _ read: ClipboardPasteboardReader.OfferOutcome, _ changeCount: Int, over connection: OutboundConnection,
        to service: any ClipboardServicing
    ) async {
        guard pasteboard.changeCount == changeCount else { return }
        // Only files are lost, and a text-only transport carries none.
        let reportsLosses = service.supportsBinaryRepresentations
        switch read {
        case .empty, .suppressed:
            connection.settledChangeCount = changeCount
            service.hostCopyOffersNothing()
        case .nothingOfferable(let lost):
            connection.settledChangeCount = changeCount
            service.hostCopyOffersNothing()
            if lost > 0, reportsLosses { reportUnforwarded(.itemsUnreadable) }
        case .offer(let copy, let lost):
            guard await service.offerHostCopy(copy) == .settled, pasteboard.changeCount == changeCount else {
                return
            }
            connection.settledChangeCount = changeCount
            if lost > 0, reportsLosses { reportUnforwarded(.itemsSkipped(count: lost)) }
        }
    }

    /// Raises a loss the user is owed — a partial copy's lost items, or a copy
    /// none of whose items could be read — as a finished forward.
    ///
    /// This poll has no gesture to answer, so the report is the only surface
    /// they get.
    private func reportUnforwarded(_ failure: ClipboardTransferFailure) {
        let name = instance?.name ?? "?"
        Self.logger.log(
            .warning,
            "Clipboard passthrough could not forward every copied item for '\(name, privacy: .public)': \(String(describing: failure), privacy: .public)"
        )
        reporter.finish(
            ClipboardTransferFinish(gesture: .forward, outcome: .failed(failure), peerName: name))
    }

    // MARK: - Guest → host (inbound)

    private func observeInbound() {
        inboundObservation = observeRecurring(
            track: { [weak self] in
                // Reading `clipboardService` re-arms the loop when it connects;
                // reading `inboundOfferSeq` fires it on each new guest offer.
                _ = self?.instance?.clipboardService?.inboundOfferSeq
            },
            apply: { [weak self] in self?.publishInboundIfAdvanced() }
        )
    }

    /// Publishes the guest's clipboard to the host pasteboard once per new offer.
    private func publishInboundIfAdvanced() {
        guard let service = instance?.clipboardService else { return }
        let seq = service.inboundOfferSeq
        guard seq != lastInboundOfferSeq else { return }
        lastInboundOfferSeq = seq
        publishInbound(from: service, seq: seq)
    }

    /// Writes one inbound offer to the host pasteboard, remembering a refusal the
    /// paste ceiling caused so a later raise can deliver what it withheld.
    private func publishInbound(from service: any ClipboardServicing, seq: UInt64) {
        let ceiling = instance?.effectiveClipboardMaxPasteBytes ?? ClipboardPasteLimit.defaultBytes
        inboundPublishTask?.cancel()
        inboundPublishTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome: HostPublishOutcome
            do {
                outcome = try await self.publisher.publish(from: service)
            } catch {
                // Stopped, or superseded by a newer offer: nothing landed.
                return
            }
            self.budgetRefusedOffer =
                outcome.droppedReasons.contains(.overPasteBudget)
                ? (seq, ceiling, self.pasteboard.changeCount)
                : nil
            if case .writeFailed = outcome { self.reportUnwritten() }
            #if DEBUG
            self.onInboundPublishedForTesting?()
            #endif
        }
    }

    /// Raises the guest's offer the pasteboard refused to take: the Mac's clipboard holds nothing of it.
    private func reportUnwritten() {
        let name = instance?.name ?? "?"
        reporter.gestureBegan()
        reporter.finish(ClipboardTransferFinish(gesture: .copy, outcome: .failed(.transferFailed), peerName: name))
    }

    /// Re-publishes the current offer when a raised paste ceiling would now serve
    /// files the last publish withheld.
    ///
    /// Without this, raising the limit — the very action the refusal invites —
    /// changes nothing: this offer's sequence is already consumed, and re-copying
    /// the same content in the guest is suppressed by its digest dedup, so the
    /// content stays unreachable until unrelated content is copied.
    ///
    /// It fires only for an offer that was *refused over the ceiling*, only while
    /// that offer is still the live one, only when the ceiling actually rose, and
    /// only while the host pasteboard still holds what we last put there — a
    /// pasteboard the user has written since is theirs, and re-publishing over it
    /// would destroy their copy.
    func republishIfCeilingRaised() {
        guard isRunning, let refused = budgetRefusedOffer,
            let instance, let service = instance.clipboardService,
            service.inboundOfferSeq == refused.seq,
            instance.effectiveClipboardMaxPasteBytes > refused.ceiling,
            pasteboard.changeCount == refused.pasteboardChangeCount
        else { return }
        Self.logger.log(
            .notice,
            "Paste ceiling raised — republishing the offer it refused for '\(instance.name, privacy: .public)'"
        )
        publishInbound(from: service, seq: refused.seq)
    }
}
