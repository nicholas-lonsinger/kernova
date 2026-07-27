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

    private var pollTimer: DispatchSourceTimer?

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

    /// Staging for the poll's folder-archiving intake (a copied *folder* must be
    /// archived before it can be offered).
    ///
    /// Separate from the publisher's host-write staging; both stage under the
    /// launch-swept `"host"` root without collision, each generation being its own
    /// UUID subdirectory.
    private let staging = ClipboardFileStaging(label: HostClipboardPublisher.stagingLabel)
    private var stagingGeneration: UInt64 = 1

    private var isRunning = false

    #if DEBUG
    /// Fires after each inbound auto-publish completes.
    var onInboundPublishedForTesting: (@MainActor () -> Void)?
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
        pollTimer?.cancel()
        pollTimer = nil
        inboundObservation?.cancel()
        inboundObservation = nil
        Self.logger.notice(
            "Clipboard passthrough stopped for '\(self.instance?.name ?? "?", privacy: .public)'")
    }

    // MARK: - Host → guest (poll)

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        timer.setEventHandler { [weak self] in
            // The timer fires on the main queue, which is the main actor's
            // executor.
            MainActor.assumeIsolated { self?.pollHostClipboard() }
        }
        timer.resume()
        pollTimer = timer
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
        case .content(let content, _):
            service.clipboardContent = content
            service.grabIfChanged()
        case .pendingFiles(let urls):
            resolveAndForward(urls, allowsBinary: allowsBinary)
        case .rejected:
            // Nothing to forward; the intake already logged the reason.
            break
        }
    }

    /// Resolves copied files/folders off the main actor (a folder archives), then
    /// offers them to the current service on the way back.
    private func resolveAndForward(_ urls: [URL], allowsBinary: Bool) {
        let staging = self.staging
        let generation = stagingGeneration
        stagingGeneration += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            let dirTree = self.instance?.clipboardService?.supportsDirectoryTree ?? false
            let resolved = await ClipboardPasteboardIntake.read(
                filesAt: urls, allowsBinary: allowsBinary, staging: staging, generation: generation,
                dirTree: dirTree)
            // The live service may have been torn down or replaced during the resolve.
            guard let service = self.instance?.clipboardService else { return }
            if case .content(let content, _) = resolved {
                service.clipboardContent = content
                service.grabIfChanged()
            }
        }
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.publisher.publish(from: service)
            // Record our own write so the next poll tick skips it.
            if let changeCount = outcome.postWriteChangeCount {
                self.lastPasteboardChangeCount = changeCount
            }
            #if DEBUG
            self.onInboundPublishedForTesting?()
            #endif
        }
    }
}
