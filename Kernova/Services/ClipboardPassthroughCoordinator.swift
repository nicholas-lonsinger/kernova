import AppKit
import KernovaKit
import os

/// Drives automatic clipboard passthrough for one VM: with no window open, it
/// polls the host pasteboard and forwards changes to the guest, and writes
/// inbound guest offers straight to the host pasteboard.
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

    /// The pasteboard polled for outbound changes and written for inbound offers.
    private let pasteboard: NSPasteboard

    /// Poll cadence — matches `VsockGuestClipboardAgent.pollingInterval` so both
    /// ends of the boundary sample their pasteboards at the same rate.
    private static let pollInterval: TimeInterval = 0.5

    /// A run-loop timer, not a dispatch timer on `.main`: the poll reads promised
    /// flavors, which fire another VM's provider synchronously, and that fire's
    /// serviced wait can drain the main queue only when it is not itself inside
    /// a main-queue callout (`NestedEventLoopWait`).
    private var pollTimer: Timer?

    /// The last host-pasteboard change count this coordinator has forwarded or
    /// absorbed.
    ///
    /// Seeded to `-1` on start so the first poll after the guest connects forwards
    /// the *current* host clipboard. A change made while the guest is disconnected
    /// is caught then too, since disconnected polls neither forward nor record.
    private var lastPasteboardChangeCount = -1

    private var inboundObservation: ObservationLoop?

    /// The inbound-offer sequence already published to the host pasteboard, so a
    /// re-observation (or per-rep materialization) doesn't re-publish.
    private var lastInboundOfferSeq: UInt64 = 0

    /// The offer whose files the paste ceiling withheld.
    ///
    /// Carries the ceiling that withheld them and what the host pasteboard held
    /// once the refusal settled — the state `republishIfCeilingRaised()` acts on.
    ///
    /// The change count is captured here rather than compared against
    /// `lastPasteboardChangeCount`: a refusal that serves nothing performs no
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

    /// Fires once the poll's off-actor file resolve has been handled, on every
    /// outcome — the seam a test needs to observe that a forward produced
    /// *nothing*, which no other signal announces.
    var onForwardResolvedForTesting: (@MainActor () -> Void)?
    #endif

    private static let logger = Logger(
        subsystem: "app.kernova", category: "ClipboardPassthroughCoordinator")

    init(
        instance: VMInstance, publisher: HostClipboardPublisher,
        pasteboard: NSPasteboard = .general
    ) {
        self.instance = instance
        self.publisher = publisher
        self.pasteboard = pasteboard
    }

    // MARK: - Lifecycle

    /// Arms the host-pasteboard poll and the inbound-offer observation.
    ///
    /// Idempotent.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        // Force the first connected poll to forward the current host clipboard.
        lastPasteboardChangeCount = -1
        lastInboundOfferSeq = instance?.clipboardService?.inboundOfferSeq ?? 0
        startPolling()
        observeInbound()
        Self.logger.notice(
            "Clipboard passthrough started for '\(self.instance?.name ?? "?", privacy: .public)'")
    }

    /// Cancels the poll and observation.
    ///
    /// Idempotent.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        pollTimer?.invalidate()
        pollTimer = nil
        inboundObservation?.cancel()
        inboundObservation = nil
        Self.logger.notice(
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

    /// Forwards a genuine host-clipboard change to the guest, skipping our own
    /// inbound writes.
    func pollHostClipboard() {
        guard let service = instance?.clipboardService, service.isConnected else {
            // Don't record the change count while disconnected, so the current
            // clipboard is forwarded on the first connected poll.
            return
        }
        let current = pasteboard.changeCount
        // Skip the change our own host-write produced, so guest content is never
        // re-forwarded back to the guest.
        if let selfWritten = publisher.lastWriteChangeCount, current == selfWritten {
            lastPasteboardChangeCount = current
            return
        }
        guard current != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = current
        forwardHostClipboard(to: service)
    }

    /// Runs the host pasteboard through the shared intake and offers the result to
    /// the guest.
    private func forwardHostClipboard(to service: any ClipboardServicing) {
        let allowsBinary = service.supportsBinaryRepresentations
        switch ClipboardPasteboardIntake.read(from: pasteboard, allowsBinary: allowsBinary) {
        case .content(let content, let note):
            offer(content, note: note, to: service)
        case .pendingFiles(let urls, let unresolved):
            resolveAndForward(urls, unresolved: unresolved, allowsBinary: allowsBinary)
        case .rejected(let message, let unreadable):
            report(rejection: message, unreadable: unreadable, to: service)
        }
    }

    /// Resolves copied files/folders off the main actor (the stat and folder
    /// estimate walk are I/O), then offers them to the current service on the
    /// way back.
    private func resolveAndForward(_ urls: [URL], unresolved: Int, allowsBinary: Bool) {
        Task { @MainActor [weak self] in
            let resolved = await ClipboardPasteboardIntake.read(
                filesAt: urls, unresolved: unresolved, allowsBinary: allowsBinary)
            guard let self else { return }
            #if DEBUG
            defer { self.onForwardResolvedForTesting?() }
            #endif
            // The live service may have been torn down or replaced during the resolve.
            guard let service = self.instance?.clipboardService else { return }
            switch resolved {
            case .content(let content, let note):
                self.offer(content, note: note, to: service)
            case .rejected(let message, let unreadable):
                self.report(rejection: message, unreadable: unreadable, to: service)
            case .pendingFiles:
                break
            }
        }
    }

    /// Raises a rejection only when it means content was there and could not be
    /// read.
    ///
    /// A policy verdict — an empty clipboard, a privacy marker, a text-only
    /// transport refusing a file copy — leaves nothing to report, and the
    /// text-only one would otherwise fire on every file the user copies.
    private func report(
        rejection message: String, unreadable: Bool, to service: any ClipboardServicing
    ) {
        guard unreadable else { return }
        reportUnforwarded(message, to: service)
    }

    /// Offers intake output to the guest, raising the intake's skip note when it
    /// carried one.
    ///
    /// Raised *after* the grab, which clears the issue on a successful offer.
    private func offer(
        _ content: ClipboardContent, note: String?, to service: any ClipboardServicing
    ) {
        service.clipboardContent = content
        service.grabIfChanged()
        guard let note else { return }
        reportUnforwarded(note, to: service)
    }

    /// Raises an intake outcome the user is owed — a partial copy's skip note,
    /// or the rejection when nothing resolved at all — as a transfer issue.
    ///
    /// The window shows these inline for its own paste/drop gestures; this poll
    /// has no gesture to answer, so the issue is the only surface they get.
    private func reportUnforwarded(_ note: String, to service: any ClipboardServicing) {
        Self.logger.warning(
            "Clipboard passthrough could not forward every copied item for '\(self.instance?.name ?? "?", privacy: .public)': \(note, privacy: .public)"
        )
        service.reportIssue(.forwardSkippedItems(note: note))
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.publisher.publish(from: service)
            // Record our own write so the next poll tick skips it.
            if let changeCount = outcome.postWriteChangeCount {
                self.lastPasteboardChangeCount = changeCount
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
    /// Deliberately narrow. It fires only for an offer that was *refused over the
    /// ceiling*, only while that offer is still the live one, only when the
    /// ceiling actually rose, and only while the host pasteboard still holds what
    /// we last put there — a pasteboard the user has written since is theirs, and
    /// re-publishing over it would destroy their copy.
    func republishIfCeilingRaised() {
        guard isRunning, let refused = budgetRefusedOffer,
            let instance, let service = instance.clipboardService,
            service.inboundOfferSeq == refused.seq,
            service.clipboardContent.digest == refused.digest,
            instance.effectiveClipboardMaxPasteBytes > refused.ceiling,
            pasteboard.changeCount == refused.pasteboardChangeCount
        else { return }
        Self.logger.notice(
            "Paste ceiling raised — republishing the offer it refused for '\(instance.name, privacy: .public)'"
        )
        publishInbound(from: service, seq: refused.seq)
    }
}
