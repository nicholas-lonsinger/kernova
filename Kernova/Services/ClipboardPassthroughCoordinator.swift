import AppKit
import KernovaKit
import os

/// Drives automatic clipboard passthrough for one VM: with no window open, it
/// polls the host pasteboard and forwards changes to the guest, and writes
/// inbound guest offers straight to the host pasteboard.
///
/// This is passthrough as CLIPBOARD.md §4 requires it — a change to *when
/// consume is authorized*, not a parallel transport. Both directions funnel
/// through the exact same choke-points the gated (clipboard-window) path uses:
///
/// - **Host → guest:** `ClipboardPasteboardIntake.read` → set
///   `service.clipboardContent` → `service.grabIfChanged()` — the same steps the
///   window's Paste/drop gestures run, so the transport, the privacy-marker
///   filtering, and the metadata-only offer are identical.
/// - **Guest → host:** `HostClipboardPublisher.publish` — the same lazy write the
///   window's "Copy to Mac" button runs, shared through one per-VM publisher.
///
/// The coordinator only changes *who triggers* those choke-points: a poll timer
/// (mirroring the guest agent's own 0.5 s pasteboard poll) instead of a window
/// gesture, and an observation of new inbound offers instead of a button click.
///
/// Echo suppression is change-count based: the publisher records the pasteboard
/// change count of its own writes, and the poll skips that exact change so guest
/// content just written to the host pasteboard is never re-forwarded to the
/// guest. (A content digest can't be the key — an inbound write places lazy
/// promised items, whose materialized digest need not match the offer's
/// placeholder digest.)
///
/// `@MainActor` because everything it touches — the pasteboard, the transport
/// service, the publisher — is main-actor isolated.
@MainActor
final class ClipboardPassthroughCoordinator {
    /// The VM whose live clipboard service this drives.
    ///
    /// Weak: `VMInstance` owns the coordinator, so this back-reference must not
    /// retain it.
    private weak var instance: VMInstance?

    /// The shared per-VM host-pasteboard writer, also used by the clipboard
    /// window's "Copy to Mac".
    ///
    /// Sharing it is what lets the poll recognize a manual copy's write (via
    /// `lastWriteChangeCount`) and not re-forward it.
    private let publisher: HostClipboardPublisher

    /// The pasteboard polled for outbound changes and written for inbound offers.
    ///
    /// `.general` in production; tests inject a private `NSPasteboard(name:)`
    /// (matching the publisher's write pasteboard) so they never touch the
    /// developer's real clipboard.
    private let pasteboard: NSPasteboard

    /// Poll cadence — matches `VsockGuestClipboardAgent.pollingInterval` so both
    /// ends of the boundary sample their pasteboards at the same rate.
    private static let pollInterval: TimeInterval = 0.5

    private var pollTimer: DispatchSourceTimer?

    /// The last host-pasteboard change count this coordinator has forwarded or
    /// absorbed.
    ///
    /// Seeded to `-1` on start so the first poll after the guest connects forwards
    /// the *current* host clipboard (turning passthrough on shares what's already
    /// copied). A change that happens while the guest is disconnected is caught on
    /// the first connected poll, since disconnected polls neither forward nor record.
    private var lastPasteboardChangeCount = -1

    private var inboundObservation: ObservationLoop?

    /// The inbound-offer sequence already published to the host pasteboard, so a
    /// re-observation (or per-rep materialization) doesn't re-publish.
    private var lastInboundOfferSeq: UInt64 = 0

    /// Staging for the poll's folder-archiving intake (a copied *folder* must be
    /// archived before it can be offered).
    ///
    /// Separate from the publisher's host-write staging; both stage under the
    /// launch-swept `"host"` root without collision (each generation is its own
    /// UUID subdirectory).
    private let staging = ClipboardFileStaging(label: HostClipboardPublisher.stagingLabel)
    private var stagingGeneration: UInt64 = 1

    private var isRunning = false

    #if DEBUG
    /// Fires after each inbound auto-publish completes.
    ///
    /// Test seam so a test awaits the publish event-driven (via `AsyncGate`)
    /// instead of polling the signal-less pasteboard — the poll's deadline would
    /// otherwise become the pass/fail criterion under a contended CI main actor.
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
            // executor; assume that isolation to touch main-actor state.
            MainActor.assumeIsolated { self?.pollHostClipboard() }
        }
        timer.resume()
        pollTimer = timer
    }

    /// Forwards a genuine host-clipboard change to the guest, skipping our own
    /// inbound writes.
    ///
    /// Internal (not `private`) so tests can drive one tick deterministically
    /// rather than waiting out the 0.5 s timer.
    func pollHostClipboard() {
        guard let service = instance?.clipboardService, service.isConnected else {
            // No live/connected transport yet (macOS constructs it on connect).
            // Don't record the change count, so the current clipboard is forwarded
            // on the first connected poll.
            return
        }
        let current = pasteboard.changeCount
        // Skip the change our own host-write produced — an inbound auto-publish, or
        // a window "Copy to Mac" through the same shared publisher. Never re-forward
        // guest content back to the guest.
        if let selfWritten = publisher.lastWriteChangeCount, current == selfWritten {
            lastPasteboardChangeCount = current
            return
        }
        guard current != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = current
        forwardHostClipboard(to: service)
    }

    /// Runs the host pasteboard through the shared intake and offers the result to
    /// the guest — the same path the window's Paste gesture uses.
    private func forwardHostClipboard(to service: any ClipboardServicing) {
        let allowsBinary = service.supportsBinaryRepresentations
        switch ClipboardPasteboardIntake.read(from: pasteboard, allowsBinary: allowsBinary) {
        case .content(let content, _):
            service.clipboardContent = content
            service.grabIfChanged()
        case .pendingFiles(let urls):
            resolveAndForward(urls, allowsBinary: allowsBinary)
        case .rejected:
            // Transient/auto-generated/empty/text-only-unsupported — nothing to
            // forward. Intake already logged the reason.
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
            let resolved = await ClipboardPasteboardIntake.read(
                filesAt: urls, allowsBinary: allowsBinary, staging: staging, generation: generation)
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
                // Reading `clipboardService` (an @Observable VMInstance property)
                // re-arms the loop when it connects; reading `inboundOfferSeq` fires
                // it on each new guest offer.
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
            // Record our own write so the next poll tick recognizes and skips it
            // (belt-and-braces alongside the poll's `lastWriteChangeCount` check).
            if let changeCount = outcome.postWriteChangeCount {
                self.lastPasteboardChangeCount = changeCount
            }
            #if DEBUG
            self.onInboundPublishedForTesting?()
            #endif
        }
    }
}
