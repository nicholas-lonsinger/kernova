import Foundation
import KernovaKit
import KernovaLogging

/// Drives automatic clipboard passthrough for one VM, whether or not its
/// clipboard window is open: it polls the host pasteboard and forwards copies
/// made while the guest is connected, and writes inbound guest offers straight
/// to the host pasteboard.
///
/// Both directions funnel through the same choke-points the clipboard window's
/// gestures use, so only *who triggers* them differs. Echo suppression is
/// change-count based: a content digest can't be the key, since an inbound write
/// places lazy promised items whose digest need not match the offer's.
@MainActor
final class ClipboardPassthroughCoordinator {
    /// The VM whose live clipboard service this drives, weak because `VMInstance`
    /// owns the coordinator.
    private weak var instance: VMInstance?

    /// The shared per-VM host-pasteboard writer, also used by the clipboard
    /// window's "Copy to Mac".
    ///
    /// Sharing it is what lets the poll recognize a manual copy's write (via
    /// `lastWriteChangeCount`) and not re-forward it.
    private let publisher: HostClipboardPublisher

    /// The pasteboard polled for outbound changes and written for inbound
    /// offers: the publisher's own, so the poll sees every write it makes.
    private var pasteboard: any ClipboardPasteboard { publisher.pasteboard }

    /// This VM's transfer report, where an intake outcome this poll cannot answer
    /// inline is recorded.
    private let reporter: ClipboardTransferReporter

    /// Poll cadence — matches `VsockGuestClipboardAgent.pollingInterval` so both
    /// ends of the boundary sample their pasteboards at the same rate.
    private static let pollInterval: TimeInterval = 0.5

    /// A run-loop timer, not a dispatch timer on `.main`: the poll reads promised
    /// flavors, which fire another VM's provider synchronously, and that fire's
    /// serviced wait can drain the main queue only when it is not itself inside
    /// a main-queue callout (`NestedEventLoopWait`).
    private var pollTimer: Timer?

    /// The outbound side of one guest connection: a connection forwards only
    /// host copies made after it came up.
    ///
    /// A poll that finds a different connected service starts a new one, and a
    /// resolve launched for an old one never offers to its successor.
    @MainActor
    private final class OutboundConnection {
        weak var service: (any ClipboardServicing)?

        /// The last host-pasteboard change count this connection has *settled* —
        /// the guest holds that copy, or nothing about it can change by offering
        /// it again.
        ///
        /// A forward advances this only once the transport gives a delivery
        /// verdict (`ClipboardGrabOutcome`): consuming the count of a copy the
        /// guest never received loses the copy outright, since later polls read
        /// the change count as unchanged and skip.
        var settledChangeCount: Int

        /// The change count of the forward whose off-actor file resolve is still
        /// running.
        ///
        /// Neither settled nor retryable: polls firing during a multi-second
        /// folder walk must not launch a second walk of the same copy.
        var resolvingChangeCount: Int?

        init(service: any ClipboardServicing, settledChangeCount: Int) {
            self.service = service
            self.settledChangeCount = settledChangeCount
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
    /// re-observation (or per-rep materialization) doesn't re-publish.
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
    ///
    /// `digest` pins the buffer's *contents*, which the sequence alone does not:
    /// an outbound poll writes the host clipboard into the same buffer without
    /// advancing the inbound sequence, so a replay keyed on the sequence could
    /// publish content the refusal was never about.
    private var budgetRefusedOffer: (seq: UInt64, ceiling: Int, pasteboardChangeCount: Int, digest: Data)?

    private var isRunning = false

    #if DEBUG
    /// Fires after each inbound auto-publish completes.
    var onInboundPublishedForTesting: (@MainActor () -> Void)?

    /// The inbound publish in flight, for a test to await its unwinding.
    var inboundPublishTaskForTesting: Task<Void, Never>? { inboundPublishTask }

    /// Fires once the poll's off-actor file resolve has been handled, on every
    /// outcome — the seam a test needs to observe that a forward produced
    /// *nothing*, which no other signal announces.
    var onForwardResolvedForTesting: (@MainActor () -> Void)?
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

    /// Arms the host-pasteboard poll and the inbound-offer observation.
    ///
    /// Idempotent.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastInboundOfferSeq = instance?.clipboardService?.inboundOfferSeq ?? 0
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
        guard let connection = outbound, connection.service === service else {
            outbound = OutboundConnection(
                service: service, settledChangeCount: pasteboard.changeCount)
            return
        }
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

    /// Runs the host pasteboard through the shared intake and offers the result to
    /// the guest, settling `changeCount` only once the copy needs no retry.
    private func forwardHostClipboard(
        _ changeCount: Int, over connection: OutboundConnection, to service: any ClipboardServicing
    ) {
        // Each copy is a gesture of its own, so the refusal this one raises is
        // announced even when the copy before it raised the identical one — the
        // offer's own reset doesn't fire for content the guest already holds.
        reporter.gestureBegan()
        let allowsBinary = service.supportsBinaryRepresentations
        switch ClipboardPasteboardIntake.read(from: pasteboard, allowsBinary: allowsBinary) {
        case .content(let content, let skipped):
            settle(changeCount, on: connection, offer(content, skipped: skipped, to: service))
        case .pendingFiles(let urls, let unresolved):
            connection.resolvingChangeCount = changeCount
            resolveAndForward(
                urls, unresolved: unresolved, allowsBinary: allowsBinary, changeCount: changeCount,
                over: connection)
        case .rejected(let refusal):
            // A verdict on this copy: re-reading the same pasteboard reaches it
            // again.
            connection.settledChangeCount = changeCount
            report(refusal)
        }
    }

    /// Consumes `changeCount` when the grab settled, leaving it for the
    /// connection's next poll to retry when it did not.
    private func settle(
        _ changeCount: Int, on connection: OutboundConnection, _ outcome: ClipboardGrabOutcome
    ) {
        guard outcome == .settled else { return }
        connection.settledChangeCount = changeCount
    }

    /// Resolves copied files/folders off the main actor (the stat and folder
    /// estimate walk are I/O), then offers them over `connection` on the way
    /// back, provided it is still the current one.
    private func resolveAndForward(
        _ urls: [URL], unresolved: Int, allowsBinary: Bool, changeCount: Int,
        over connection: OutboundConnection
    ) {
        Task { @MainActor [weak self] in
            let resolved = await ClipboardPasteboardIntake.read(
                filesAt: urls, unresolved: unresolved, allowsBinary: allowsBinary)
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
            // The host clipboard moved on during the walk, so this content is
            // nobody's copy now; the next poll takes whatever replaced it.
            guard self.pasteboard.changeCount == changeCount else { return }
            switch resolved {
            case .content(let content, let skipped):
                self.settle(
                    changeCount, on: connection, self.offer(content, skipped: skipped, to: service))
            case .rejected(let refusal):
                connection.settledChangeCount = changeCount
                self.report(refusal)
            case .pendingFiles:
                connection.settledChangeCount = changeCount
                Self.logger.log(.fault, "Resolving copied files yielded another pending-files intake")
                assertionFailure("Resolving copied files yielded another pending-files intake")
            }
        }
    }

    /// Raises a rejection only when it means content was there and could not be
    /// read.
    ///
    /// A policy verdict — an empty clipboard, a privacy marker, a text-only
    /// transport refusing a file copy — leaves nothing to report, and the
    /// text-only one would otherwise fire on every file the user copies.
    private func report(_ refusal: ClipboardIntakeRefusal) {
        guard case .unreadable = refusal else { return }
        reportUnforwarded(.itemsUnreadable)
    }

    /// Offers intake output to the guest, raising the items it left out when
    /// there were any, and reports what became of the grab.
    ///
    /// The skip is raised *after* the grab, which clears the issue on a
    /// successful offer, and only on `.settled`: an undelivered forward left
    /// nothing behind for the user to act on yet, and reporting each attempt
    /// would file one transfer report per poll until the retry lands.
    private func offer(
        _ content: ClipboardContent, skipped: Int, to service: any ClipboardServicing
    ) -> ClipboardGrabOutcome {
        service.clipboardContent = content
        let outcome = service.grabIfChanged()
        if outcome == .settled, skipped > 0 {
            reportUnforwarded(.itemsSkipped(count: skipped))
        }
        return outcome
    }

    /// Raises an intake loss the user is owed — a partial copy's skipped items,
    /// or a copy none of whose items could be read — as a finished forward.
    ///
    /// The window shows these inline for its own paste/drop gestures; this poll
    /// has no gesture to answer, so the report is the only surface they get.
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
                ? (seq, ceiling, self.pasteboard.changeCount, service.clipboardContent.digest)
                : nil
            #if DEBUG
            self.onInboundPublishedForTesting?()
            #endif
        }
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
            service.clipboardContent.digest == refused.digest,
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
