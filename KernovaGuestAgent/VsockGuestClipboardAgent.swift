import AppKit
import Foundation
import KernovaProtocol
import UniformTypeIdentifiers

// MARK: - Pasteboard protocol

/// Subset of `NSPasteboard` actually used by `VsockGuestClipboardAgent`.
///
/// RATIONALE: `NSPasteboard.general` is a process-wide singleton with no
/// mockable surface; this protocol is the cheapest seam that lets tests run
/// without touching the developer's real clipboard.
protocol Pasteboard: AnyObject {
    var changeCount: Int { get }

    /// Types of the **first** pasteboard item, in fidelity order; empty when
    /// the pasteboard holds nothing. The agent models one logical item — see
    /// `ClipboardContent`.
    var firstItemTypes: [NSPasteboard.PasteboardType] { get }

    func data(forType type: NSPasteboard.PasteboardType) -> Data?

    @discardableResult func clearContents() -> Int

    /// Writes a single pasteboard item carrying every representation.
    @discardableResult
    func writeItem(representations: [(type: NSPasteboard.PasteboardType, data: Data)]) -> Bool
}

extension NSPasteboard: Pasteboard {
    var firstItemTypes: [NSPasteboard.PasteboardType] {
        pasteboardItems?.first?.types ?? []
    }

    // RATIONALE: NSPasteboard's own `data(forType:)` reads from "the first
    // pasteboard item that contains the type". The agent only queries types
    // reported by `firstItemTypes` (item 0), so the existing method satisfies
    // the protocol requirement with the intended item-0 semantics.

    func writeItem(representations: [(type: NSPasteboard.PasteboardType, data: Data)]) -> Bool {
        let item = NSPasteboardItem()
        for representation in representations {
            item.setData(representation.data, forType: representation.type)
        }
        return writeObjects([item])
    }
}

// MARK: - VsockGuestClipboardAgent

/// Guest-side clipboard agent that talks to the host's `VsockClipboardService`
/// on `KernovaVsockPort.clipboard` (49152).
///
/// Runs the offer/request/data state machine symmetrically:
/// - Outbound: a 0.5 s `NSPasteboard` poll detects local clipboard changes,
///   snapshots the first item's UTI-tagged representations (filtered and
///   size-capped by `ClipboardSnapshotPolicy`), and announces them via
///   `ClipboardOffer` with a monotonically increasing generation, then
///   answers the host's `ClipboardRequest` with the bytes.
/// - Inbound: when the host sends an offer the agent immediately requests
///   the bytes; on `ClipboardData` it writes one pasteboard item carrying
///   every representation to the guest's `NSPasteboard.general`.
///
/// Offers advertise UTIs plus — when a plain-text representation exists —
/// the legacy `TEXT_UTF8` format, so hosts that predate UTI support still
/// interop text-only (see `VsockClipboardService` for the mirror-image rule).
///
/// Connection lifecycle (connect, retry on failure, EOF handling) is owned by
/// `VsockGuestClient`. This class layers the protocol on top.
///
/// All mutable state is accessed exclusively on the main dispatch queue.
// RATIONALE: @unchecked Sendable with DispatchQueue.main serialization is
// used because @MainActor is impractical here — the entry point is
// main.swift top-level code (nonisolated in Swift 6), not an @main app.
final class VsockGuestClipboardAgent: @unchecked Sendable {
    private static let logger = KernovaLogger(subsystem: "app.kernova.agent", category: "VsockGuestClipboardAgent")
    private static let pollingInterval: TimeInterval = 0.5

    private static let errorCodeFormatUnavailable = "clipboard.format.unavailable"
    private static let errorCodeTransferFailure = "clipboard.transfer.send.failure"
    private static let errorCodeTooLarge = "clipboard.transfer.too.large"

    private let client: VsockGuestClient
    private let pasteboard: Pasteboard

    // MARK: - Main-queue state

    /// Live channel for the current connection, if any.
    ///
    /// Nil between
    /// connections; checked by the polling timer to short-circuit when
    /// the host isn't reachable.
    private var liveChannel: VsockChannel?

    #if DEBUG
    /// Exposes `liveChannel` as an internal read for tests that need to wait
    /// until the main-queue async assignment completes before driving polls.
    var liveChannelForTesting: VsockChannel? { liveChannel }

    /// Exposes `pendingInboundGeneration` for tests that need to assert the
    /// inbound-request lifecycle without relying on observable side effects.
    ///
    /// A seam is used here rather than a behavioral assertion (e.g. sending a
    /// stale `ClipboardData` and checking the pasteboard wasn't overwritten)
    /// because any reconnect path resets `pendingInboundGeneration` to `nil`
    /// via `serve()`'s teardown block. That reset would satisfy a behavioral
    /// assertion for the wrong reason, masking a regression in the generation
    /// commit logic itself.
    var pendingInboundGenerationForTesting: UInt64? { pendingInboundGeneration }
    #endif

    /// Counter for outbound offer generations.
    ///
    /// Starts at 1 so 0 can serve as
    /// "no pending request" sentinel for the inbound side.
    private var nextLocalGeneration: UInt64 = 1

    /// The most recent offer we sent the host; held until the host responds
    /// with a request (or supersedes it with a newer offer of our own).
    private var pendingOutbound: (generation: UInt64, content: ClipboardContent)?

    /// Last inbound offer we requested data for.
    ///
    /// Used to drop a delayed
    /// `ClipboardData` for an older offer.
    private var pendingInboundGeneration: UInt64?

    /// Last `NSPasteboard.changeCount` we observed.
    ///
    /// Set after every
    /// poll cycle and after every host write so we don't echo back our own
    /// content.
    private var lastPasteboardChangeCount: Int

    /// Digest of the most recent content we sent or wrote.
    ///
    /// Suppresses re-offering after
    /// a host-driven write and avoids redundant offers when the user
    /// touches the clipboard without changing the contents. A 32-byte
    /// digest rather than the content itself, so suppression state never
    /// retains a second multi-megabyte copy.
    private var lastSeenDigest: Data?

    private var pollingTimer: DispatchSourceTimer?

    /// Whether clipboard sync is currently allowed by host policy.
    ///
    /// Default `false` so the agent doesn't connect or poll until the host's first
    /// `PolicyUpdate(clipboardSharingEnabled: true)` arrives. Mutated only
    /// on the main queue.
    private var enabled: Bool = false

    #if DEBUG
    /// Test seam.
    var isEnabledForTesting: Bool { enabled }
    #endif

    // MARK: - Init

    /// Production init — uses real `NSPasteboard.general` on the clipboard port.
    convenience init() {
        self.init(
            pasteboard: NSPasteboard.general,
            client: VsockGuestClient(port: KernovaVsockPort.clipboard, label: "clipboard")
        )
    }

    /// Designated init; tests inject a fake pasteboard and socketpair-backed client.
    init(pasteboard: Pasteboard, client: VsockGuestClient) {
        self.pasteboard = pasteboard
        self.client = client
        self.lastPasteboardChangeCount = pasteboard.changeCount
        // Default-disabled: pause the reconnect loop until the host sends its
        // first `PolicyUpdate(clipboardSharingEnabled: true)`.
        self.client.pause()
    }

    // MARK: - Lifecycle

    /// Begins the connect/serve loop.
    ///
    /// The pasteboard poll is started when
    /// host policy enables clipboard sharing — see `setEnabled(_:)`.
    func start() {
        client.start { [weak self] channel in
            await self?.serve(channel: channel)
        }
        Self.logger.notice("Vsock clipboard agent started")
    }

    /// Applies a host policy update for clipboard sharing.
    ///
    /// When disabling: cancels the pasteboard poll, closes any active channel
    /// via the underlying client, clears per-connection state, and pauses
    /// the reconnect loop. When enabling: resumes the loop and starts the
    /// pasteboard poll. Idempotent — repeated calls with the same value are
    /// no-ops.
    func setEnabled(_ enabled: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.applyEnabledOnMain(enabled)
        }
    }

    /// Main-queue body of `setEnabled(_:)`.
    ///
    /// Caller must dispatch to main.
    private func applyEnabledOnMain(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if enabled {
            client.resume()
            startPolling()
            Self.logger.notice("Clipboard sharing enabled by host policy")
        } else {
            client.pause()
            pollingTimer?.cancel()
            pollingTimer = nil
            liveChannel = nil
            pendingOutbound = nil
            pendingInboundGeneration = nil
            Self.logger.notice("Clipboard sharing disabled by host policy")
        }
    }

    /// Tears down the connection and the poll timer.
    func stop() {
        client.stop()
        DispatchQueue.main.async { [weak self] in
            self?.pollingTimer?.cancel()
            self?.pollingTimer = nil
            self?.liveChannel = nil
            self?.pendingOutbound = nil
            self?.pendingInboundGeneration = nil
        }
        Self.logger.notice("Vsock clipboard agent stopped")
    }

    // MARK: - Per-connection serve

    private func serve(channel: VsockChannel) async {
        // RATIONALE: Use await MainActor.run rather than DispatchQueue.main.async
        // here so the publish completes before serve() advances to the read loop.
        // The polling timer checks liveChannel on the main queue; with async
        // dispatch there would be a window where the timer fires, sees a nil
        // channel, and silently skips an offer — even though the connection is
        // already live. The other DispatchQueue.main.async sites in this class
        // (start/stop, frame-handler dispatch in the loop body) are
        // fire-and-forget and don't need this guarantee. MainActor.run shares
        // the main-queue executor with DispatchQueue.main, so FIFO ordering is
        // preserved between the two idioms.
        await MainActor.run {
            self.liveChannel = channel
            self.pendingOutbound = nil
            self.pendingInboundGeneration = nil
            // The host on the other end may be a brand-new instance (host
            // app restarted, VM stopped+started, etc.) that has no record
            // of prior offers. Clear the dedup state so the next poll
            // cycle re-announces the current clipboard rather than
            // assuming the host already has it.
            self.lastSeenDigest = nil
            self.lastPasteboardChangeCount = -1
        }
        Self.logger.notice("Vsock clipboard connected to host")

        do {
            for try await frame in channel.incoming {
                DispatchQueue.main.async { [weak self] in
                    self?.handle(frame: frame, channel: channel)
                }
            }
            Self.logger.notice("Vsock clipboard channel closed by host")
        } catch {
            Self.logger.warning(
                "Vsock clipboard channel ended with error: \(error.localizedDescription, privacy: .public)"
            )
        }

        // RATIONALE: Cleanup also uses await MainActor.run so it settles before
        // serve() returns. The reconnect loop in VsockGuestClient cannot call the
        // next socketProvider until serve() returns, which means liveChannel is
        // guaranteed nil before a new connection is published. An async dispatch
        // here would leave a window where the timer dispatches a checkClipboardChange
        // to the dead channel, and tests could pass under eventual consistency
        // without catching the race (see serveSynchronouslyClearsLiveChannelOnClose).
        await MainActor.run {
            if self.liveChannel === channel {
                self.liveChannel = nil
                self.pendingOutbound = nil
                self.pendingInboundGeneration = nil
            }
        }
    }

    // MARK: - Pasteboard polling (main queue)

    private func startPolling() {
        // RATIONALE: A timer poll, not an event source, because macOS exposes no
        // change notification for NSPasteboard — comparing `changeCount` on an
        // interval is the only way to detect local clipboard writes. The handler
        // reads just the integer `changeCount` first (see `checkClipboardChange`)
        // and bails before any allocation when it's unchanged, so the 0.5 s tick
        // is cheap. This is the canonical AppKit clipboard-watching pattern; an
        // async/event-driven audit will flag it but there is no event to await.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.pollingInterval, repeating: Self.pollingInterval)
        timer.setEventHandler { [weak self] in
            self?.checkClipboardChange()
        }
        timer.resume()
        pollingTimer = timer
    }

    func checkClipboardChange() {
        guard let channel = liveChannel else { return }

        let currentCount = pasteboard.changeCount
        guard currentCount != lastPasteboardChangeCount else { return }

        // A copied image *file* (Finder ⌘C) puts only a file URL and its name
        // on the pasteboard — not the pixels. Expand it to the image itself so
        // it pastes as an image on the host, matching how macOS pastes a copied
        // image file. Non-image files fall through to the normal snapshot, where
        // the file reference is filtered and only the name survives.
        let content: ClipboardContent
        if let imageFileContent = expandedImageFileContent() {
            content = imageFileContent
        } else {
            // Identity-based skips run before any data is read so transient
            // markers and file references cost nothing per poll.
            let raw: [(uti: String, data: Data)] = pasteboard.firstItemTypes.compactMap { type in
                guard !ClipboardSnapshotPolicy.shouldSkipBeforeReading(uti: type.rawValue) else {
                    return nil
                }
                guard let data = pasteboard.data(forType: type) else { return nil }
                return (uti: type.rawValue, data: data)
            }
            let outcome = ClipboardSnapshotPolicy.evaluate(raw)

            if !outcome.skipped.isEmpty {
                // Never a silent empty/partial snapshot — say what was dropped.
                let summary = outcome.skipped
                    .map { "\($0.uti): \(String(describing: $0.reason))" }
                    .joined(separator: ", ")
                Self.logger.notice(
                    "Clipboard snapshot skipped \(outcome.skipped.count, privacy: .public) representation(s): \(summary, privacy: .public)"
                )
            }
            content = outcome.content
        }

        guard !content.isEmpty else {
            lastPasteboardChangeCount = currentCount
            return
        }
        // Don't echo back content we just wrote from the host.
        guard content.digest != lastSeenDigest else {
            lastPasteboardChangeCount = currentCount
            return
        }

        let generation = nextLocalGeneration

        var offer = Frame()
        offer.protocolVersion = 1
        offer.clipboardOffer = Kernova_V1_ClipboardOffer.with {
            $0.generation = generation
            $0.utis = content.representations.map(\.uti)
            // Legacy field: lets pre-UTI hosts pull the text representation.
            $0.formats = content.text != nil ? [.textUtf8] : []
        }
        do {
            try channel.send(offer)
            // Plain `+=` traps on overflow rather than wrapping into 0,
            // which the inbound side uses as a "no pending offer" sentinel.
            // UInt64.max is unreachable in practice.
            nextLocalGeneration += 1
            pendingOutbound = (generation: generation, content: content)
            lastSeenDigest = content.digest
            lastPasteboardChangeCount = currentCount
            Self.logger.notice(
                "Sent clipboard offer (gen=\(generation, privacy: .public), \(content.representations.count, privacy: .public) reps, \(content.totalByteCount, privacy: .public) bytes)"
            )
        } catch {
            // State left untouched: lastSeenDigest still differs from the
            // content's digest, changeCount still old, generation still
            // unconsumed — the next poll cycle will re-attempt the same offer.
            Self.logger.warning(
                "Failed to send clipboard offer: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// When the first pasteboard item is a single copied image *file*,
    /// returns the image's bytes as one representation.
    ///
    /// Finder's ⌘C on a file puts a `public.file-url` (and the name) on the
    /// pasteboard, not the pixels; this reads the file so the image itself
    /// crosses — the guest-side mirror of the host window's file-drop image
    /// expansion. Returns nil for non-file or non-image clipboards (and for
    /// files over the per-representation cap, after logging), so the normal
    /// snapshot runs instead and the file's name survives.
    private func expandedImageFileContent() -> ClipboardContent? {
        guard pasteboard.firstItemTypes.contains(.fileURL),
            let urlData = pasteboard.data(forType: .fileURL),
            let urlString = String(data: urlData, encoding: .utf8),
            let url = URL(string: urlString), url.isFileURL
        else { return nil }

        guard let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey]),
            let type = values.contentType, type.conforms(to: .image)
        else { return nil }

        let size = values.fileSize ?? 0
        guard size > 0 else { return nil }
        guard size <= ClipboardSnapshotPolicy.maxRepresentationByteCount else {
            Self.logger.notice(
                "Copied image file too large to expand (\(size, privacy: .public) bytes) — sending its name instead"
            )
            return nil
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return ClipboardContent(representations: [
            ClipboardContent.Representation(uti: type.identifier, data: data)
        ])
    }

    // MARK: - Frame handlers (main queue)

    private func handle(frame: Frame, channel: VsockChannel) {
        guard frame.protocolVersion == 1 else {
            Self.logger.warning(
                "Dropping frame with unsupported protocol version \(frame.protocolVersion, privacy: .public)"
            )
            return
        }
        switch frame.payload {
        case .clipboardOffer(let offer):
            handleOffer(offer, channel: channel)
        case .clipboardRequest(let req):
            handleRequest(req, channel: channel)
        case .clipboardData(let data):
            handleData(data)
        case .clipboardRelease(let release):
            handleRelease(release)
        case .error(let error):
            Self.logger.warning(
                "Host clipboard error: \(error.code, privacy: .public) — \(error.message, privacy: .public)"
            )
        case .hello, .heartbeat, .policyUpdate, .logRecord, .none:
            Self.logger.warning("Unexpected payload on clipboard channel — wrong port")
        }
    }

    private func handleOffer(_ offer: Kernova_V1_ClipboardOffer, channel: VsockChannel) {
        var request = Frame()
        request.protocolVersion = 1

        if !offer.utis.isEmpty {
            // UTI-capable host: pull every advertised representation (the
            // sender already applied ClipboardSnapshotPolicy's caps).
            request.clipboardRequest = Kernova_V1_ClipboardRequest.with {
                $0.generation = offer.generation
                $0.utis = offer.utis
            }
        } else if offer.formats.contains(.textUtf8) {
            // Legacy host: text is all it can serve.
            request.clipboardRequest = Kernova_V1_ClipboardRequest.with {
                $0.generation = offer.generation
                $0.format = .textUtf8
            }
        } else {
            Self.logger.debug(
                "Host offer carries no usable format (formats=\(offer.formats.map(\.rawValue), privacy: .public))"
            )
            return
        }

        do {
            try channel.send(request)
            pendingInboundGeneration = offer.generation
            Self.logger.debug("Requested clipboard data from host (gen=\(offer.generation, privacy: .public))")
        } catch {
            Self.logger.warning(
                "Failed to send clipboard request: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func handleRequest(_ request: Kernova_V1_ClipboardRequest, channel: VsockChannel) {
        guard let pending = pendingOutbound, pending.generation == request.generation else {
            // Stale: the host has already replaced or dropped the offer this targets.
            // Don't burden it with an error — silence is correct here.
            Self.logger.debug(
                "Stale clipboard request gen=\(request.generation, privacy: .public) (pending=\(self.pendingOutbound?.generation ?? 0, privacy: .public))"
            )
            return
        }
        var dataFrame = Frame()
        dataFrame.protocolVersion = 1

        if !request.utis.isEmpty {
            let requested = Set(request.utis)
            let representations = pending.content.representations.filter {
                requested.contains($0.uti)
            }
            guard !representations.isEmpty else {
                Self.logger.warning(
                    "Requested UTIs not in pending offer gen=\(request.generation, privacy: .public)"
                )
                sendErrorFrame(
                    on: channel,
                    code: Self.errorCodeFormatUnavailable,
                    message:
                        "Guest agent has none of the requested representations (gen=\(request.generation))",
                    inReplyTo: "clipboard.request"
                )
                return
            }
            dataFrame.clipboardData = Kernova_V1_ClipboardData.with {
                $0.generation = pending.generation
                $0.representations = representations.map { representation in
                    Kernova_V1_ClipboardRepresentation.with {
                        $0.uti = representation.uti
                        $0.data = representation.data
                    }
                }
            }
        } else {
            guard request.format == .textUtf8 else {
                Self.logger.warning(
                    "Unsupported clipboard format requested gen=\(request.generation, privacy: .public) format=\(request.format.rawValue, privacy: .public)"
                )
                sendErrorFrame(
                    on: channel,
                    code: Self.errorCodeFormatUnavailable,
                    message:
                        "Guest agent only carries TEXT_UTF8 on the legacy path (gen=\(request.generation), requested format=\(request.format.rawValue))",
                    inReplyTo: "clipboard.request"
                )
                return
            }
            guard let text = pending.content.text else {
                Self.logger.warning(
                    "Legacy text request but pending content has no text representation gen=\(pending.generation, privacy: .public)"
                )
                sendErrorFrame(
                    on: channel,
                    code: Self.errorCodeFormatUnavailable,
                    message:
                        "Guest agent content has no text representation (gen=\(pending.generation))",
                    inReplyTo: "clipboard.request"
                )
                return
            }
            dataFrame.clipboardData = Kernova_V1_ClipboardData.with {
                $0.generation = pending.generation
                $0.format = .textUtf8
                $0.data = Data(text.utf8)
            }
        }

        let byteCount = pending.content.totalByteCount
        do {
            try channel.send(dataFrame)
            Self.logger.debug(
                "Sent clipboard data (gen=\(pending.generation, privacy: .public), \(byteCount, privacy: .public) bytes)"
            )
        } catch VsockFrameError.frameTooLarge(let declaredSize, let maxAllowed) {
            // Encoding failed before any bytes hit the wire; the channel is
            // still healthy. ClipboardSnapshotPolicy's caps make this
            // unreachable for poll-produced content; it exists so a cap
            // regression degrades to an error message instead of a silent
            // paste failure.
            Self.logger.error(
                "Clipboard data exceeds frame limit gen=\(pending.generation, privacy: .public) frame=\(declaredSize, privacy: .public) max=\(maxAllowed, privacy: .public)"
            )
            sendErrorFrame(
                on: channel,
                code: Self.errorCodeTooLarge,
                message:
                    "Guest clipboard content exceeds the transfer limit (gen=\(pending.generation), \(byteCount) bytes)",
                inReplyTo: "clipboard.request"
            )
        } catch {
            // Logged at .error: this failure is user-visible (paste produces nothing).
            // Include gen + size so post-mortems can pair this with the peer's "request sent" log.
            Self.logger.error(
                "Failed to send clipboard data gen=\(pending.generation, privacy: .public) bytes=\(byteCount, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            // If the channel is dead, the peer will learn via EOF — no further fallback needed.
            sendErrorFrame(
                on: channel,
                code: Self.errorCodeTransferFailure,
                message:
                    "Guest agent failed to deliver clipboard data (gen=\(pending.generation), \(byteCount) bytes): \(error.localizedDescription)",
                inReplyTo: "clipboard.request"
            )
        }
    }

    private func handleData(_ data: Kernova_V1_ClipboardData) {
        guard data.generation == pendingInboundGeneration else {
            Self.logger.debug(
                "Stale clipboard data gen=\(data.generation, privacy: .public) (pending=\(self.pendingInboundGeneration ?? 0, privacy: .public))"
            )
            return
        }
        let content: ClipboardContent
        if !data.representations.isEmpty {
            // Receive-side sanitization: never apply file references or
            // transient markers, no matter what the peer sent.
            let sanitized = ClipboardSnapshotPolicy.sanitizedForApply(
                data.representations.map {
                    ClipboardContent.Representation(uti: $0.uti, data: $0.data)
                }
            )
            if sanitized.count != data.representations.count {
                Self.logger.warning(
                    "Dropped \(data.representations.count - sanitized.count, privacy: .public) forbidden representation(s) from host clipboard data gen=\(data.generation, privacy: .public)"
                )
            }
            guard !sanitized.isEmpty else {
                // The generation was consumed even though nothing was usable.
                pendingInboundGeneration = nil
                return
            }
            content = ClipboardContent(representations: sanitized)
        } else if data.format == .textUtf8 {
            guard let text = String(data: data.data, encoding: .utf8) else {
                Self.logger.warning(
                    "Host clipboard data not valid UTF-8 (\(data.data.count, privacy: .public) bytes)"
                )
                pendingInboundGeneration = nil
                return
            }
            content = ClipboardContent(text: text)
        } else {
            Self.logger.debug(
                "Host clipboard data carries no usable payload (format=\(data.format.rawValue, privacy: .public))"
            )
            pendingInboundGeneration = nil
            return
        }
        guard !content.isEmpty else {
            pendingInboundGeneration = nil
            return
        }

        pasteboard.clearContents()
        let written = pasteboard.writeItem(
            representations: content.representations.map { representation in
                (
                    type: NSPasteboard.PasteboardType(rawValue: representation.uti),
                    data: representation.data
                )
            }
        )
        guard written else {
            Self.logger.warning(
                "Failed to write host clipboard to pasteboard (gen=\(data.generation, privacy: .public), \(content.totalByteCount, privacy: .public) bytes). Echo-suppression state preserved; next user clipboard change will offer normally."
            )
            return
        }
        // Record so the polling timer doesn't echo this back to the host
        // on the next change-count tick.
        lastPasteboardChangeCount = pasteboard.changeCount
        lastSeenDigest = content.digest
        pendingInboundGeneration = nil
        Self.logger.notice(
            "Wrote host clipboard to pasteboard (\(content.representations.count, privacy: .public) reps, \(content.totalByteCount, privacy: .public) bytes)"
        )
    }

    private func handleRelease(_ release: Kernova_V1_ClipboardRelease) {
        if pendingInboundGeneration == release.generation {
            pendingInboundGeneration = nil
            Self.logger.debug(
                "Host released clipboard offer (gen=\(release.generation, privacy: .public))"
            )
        }
    }

    // MARK: - Error helpers

    /// If `channel.sendErrorFrame` fails (typically because the channel just tore down
    /// for the same reason we're reporting), the failure is logged at `.debug`
    /// and swallowed — we have nothing better to do at that point.
    private func sendErrorFrame(
        on channel: VsockChannel,
        code: String,
        message: String,
        inReplyTo: String?
    ) {
        do {
            try channel.sendErrorFrame(code: code, message: message, inReplyTo: inReplyTo)
        } catch {
            Self.logger.debug(
                "Failed to send error frame (code=\(code, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
