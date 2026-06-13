import Foundation
import KernovaProtocol
import os

/// Drives the Kernova clipboard sync protocol over a single `VsockChannel`.
///
/// Used for macOS guests (Linux guests use the SPICE-based service). The
/// service acts symmetrically: either side can announce new clipboard content
/// via `ClipboardOffer`, and the receiver pulls the bytes via
/// `ClipboardRequest` / `ClipboardData`. Each offer carries a monotonically
/// increasing `generation` so requests that race a newer offer are detectable.
///
/// Content is a set of UTI-tagged representations (`ClipboardContent`).
/// Offers advertise the representations' UTIs plus — when a plain-text
/// representation exists — the legacy `TEXT_UTF8` format, so peers that
/// predate UTI support still interop text-only: a legacy `format`-based
/// request is answered with the legacy `data` field, a `utis`-based request
/// with `representations`. Inbound frames are branched the same way.
///
/// One instance manages one channel for the lifetime of one accepted
/// connection; the service self-terminates when the channel closes.
///
/// The version handshake and agent liveness are not handled here — they live on
/// the always-on control channel (`VsockControlService` / port
/// `KernovaVsockPort.control`). This service starts producing feature payloads
/// as soon as `start()` is called; no `Hello` is exchanged on this channel.
@MainActor
@Observable
final class VsockClipboardService: ClipboardServicing {
    // MARK: - Observable state

    /// Bidirectional clipboard buffer.
    ///
    /// Set by the user (via the clipboard
    /// window) to seed an outbound offer; updated when the guest sends
    /// fresh data.
    var clipboardContent: ClipboardContent = .empty

    /// `true` once `start()` has been called.
    ///
    /// The clipboard channel is
    /// established by `VsockListenerHost` accepting a connection — by the time
    /// this service is constructed the socket is up, so connectivity is
    /// equivalent to "started and not yet stopped". A separate liveness signal
    /// (whether the agent process is still responsive) lives on the control
    /// channel and surfaces via `VMInstance.agentStatus`.
    private(set) var isConnected: Bool = false

    /// Most recent user-visible transfer problem; cleared by the next
    /// successful transfer in either direction.
    private(set) var lastTransferIssue: ClipboardTransferIssue?

    var supportsBinaryRepresentations: Bool { true }

    // MARK: - Private state

    // RATIONALE: `channel` is captured at init and never replaced. There is no
    // polling timer or reconnect loop that reads the channel from a different
    // actor context, so the publish/cleanup race fixed in
    // VsockGuestClipboardAgent.serve (PR #166 / issue #156) does not apply here.
    // If you add dynamic channel swapping (e.g., per-reconnect channel
    // reassignment), mirror that fix: replace any DispatchQueue.main.async
    // publish/cleanup in the new code with await MainActor.run so state settles
    // before the function that changes the channel returns.
    private let channel: VsockChannel
    private let label: String

    private var consumeTask: Task<Void, Never>?

    /// Counter for outbound offer generations.
    ///
    /// Starts at 1 so 0 can serve as
    /// "no pending request" sentinel for the inbound side.
    private var nextLocalGeneration: UInt64 = 1

    /// The most recent offer we sent the guest.
    ///
    /// Held until the guest requests
    /// (or supersedes) it so we can answer `ClipboardRequest`.
    private var pendingOutbound: (generation: UInt64, content: ClipboardContent)?

    /// The most recent offer the guest sent us that we asked to receive.
    ///
    /// We track it so a delayed `ClipboardData` for an older offer can be
    /// dropped.
    private var pendingInboundGeneration: UInt64?

    /// Digest of the last content we successfully announced.
    ///
    /// Skips redundant offers when `grabIfChanged()` is called repeatedly
    /// with the same content. A 32-byte digest rather than the content
    /// itself, so dedup state never retains a second multi-megabyte copy.
    private var lastGrabbedDigest: Data?

    #if DEBUG
    /// Exposes `pendingInboundGeneration` for tests that need to assert the
    /// inbound-request lifecycle without relying on observable side effects.
    ///
    /// A seam is used here rather than a behavioral assertion (e.g. sending a
    /// stale `ClipboardData` and checking `clipboardContent` wasn't overwritten)
    /// because any channel teardown resets `pendingInboundGeneration` to `nil`
    /// via `stop()`. That reset would satisfy a behavioral assertion for the
    /// wrong reason, masking a regression in the generation commit logic itself.
    var pendingInboundGenerationForTesting: UInt64? { pendingInboundGeneration }
    #endif

    private static let logger = Logger(subsystem: "app.kernova", category: "VsockClipboardService")

    private static let errorCodeFormatUnavailable = "clipboard.format.unavailable"
    private static let errorCodeTransferFailure = "clipboard.transfer.send.failure"
    private static let errorCodeTooLarge = "clipboard.transfer.too.large"

    // MARK: - Init

    init(channel: VsockChannel, label: String) {
        self.channel = channel
        self.label = label
    }

    // MARK: - Lifecycle

    func start() {
        guard consumeTask == nil else { return }

        isConnected = true

        let channel = self.channel
        let label = self.label
        consumeTask = Task { [weak self] in
            await Self.consume(channel: channel, label: label) { @MainActor frame in
                self?.handle(frame: frame)
            }
        }

        Self.logger.info("Vsock clipboard service started for '\(self.label, privacy: .public)'")
    }

    func stop() {
        consumeTask?.cancel()
        consumeTask = nil
        channel.close()
        isConnected = false
        pendingOutbound = nil
        pendingInboundGeneration = nil
        Self.logger.info("Vsock clipboard service stopped for '\(self.label, privacy: .public)'")
    }

    // MARK: - Public API

    func grabIfChanged() {
        guard isConnected else { return }
        guard !clipboardContent.isEmpty else { return }
        guard clipboardContent.digest != lastGrabbedDigest else { return }

        // Defense for content set directly on the service (the window's
        // paste/drop intake already enforces ClipboardSnapshotPolicy): an
        // oversized payload would fail frame encoding at request time, so
        // refuse the offer up front and tell the user instead.
        let totalByteCount = clipboardContent.totalByteCount
        guard totalByteCount <= ClipboardSnapshotPolicy.maxTotalByteCount else {
            lastTransferIssue = ClipboardTransferIssue(
                kind: .contentTooLarge(
                    byteCount: totalByteCount,
                    limit: ClipboardSnapshotPolicy.maxTotalByteCount
                ),
                date: Date()
            )
            // Oversized content can never be offered, so mark it handled —
            // otherwise every window blur re-enters this guard and re-fires
            // the same transient message. A subsequent content change has a
            // different digest and is re-evaluated normally.
            lastGrabbedDigest = clipboardContent.digest
            Self.logger.warning(
                "Clipboard content too large to offer (\(totalByteCount, privacy: .public) bytes > \(ClipboardSnapshotPolicy.maxTotalByteCount, privacy: .public)) for '\(self.label, privacy: .public)'"
            )
            return
        }

        let generation = nextLocalGeneration
        let content = clipboardContent

        var offer = Frame()
        offer.protocolVersion = 1
        offer.clipboardOffer = Kernova_V1_ClipboardOffer.with {
            $0.generation = generation
            $0.utis = content.representations.map(\.uti)
            // Legacy field: lets pre-UTI peers pull the text representation.
            $0.formats = content.text != nil ? [.textUtf8] : []
        }

        do {
            try channel.send(offer)
            // Plain `+=` traps on overflow rather than wrapping into 0,
            // which the inbound side uses as a "no pending offer" sentinel.
            // UInt64.max is unreachable in practice.
            nextLocalGeneration += 1
            pendingOutbound = (generation: generation, content: content)
            lastGrabbedDigest = content.digest
            lastTransferIssue = nil
            Self.logger.notice(
                "Sent clipboard offer to '\(self.label, privacy: .public)' (gen=\(generation, privacy: .public), \(content.representations.count, privacy: .public) reps, \(totalByteCount, privacy: .public) bytes)"
            )
        } catch {
            // State left untouched: lastGrabbedDigest still differs from
            // clipboardContent.digest, generation still unconsumed — next
            // call will re-attempt the same offer.
            Self.logger.error(
                "Failed to send clipboard offer for '\(self.label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Error helpers

    /// If `channel.sendErrorFrame` fails (typically because the channel just tore down
    /// for the same reason we're reporting), the failure is logged at `.debug`
    /// and swallowed — we have nothing better to do at that point.
    private func sendErrorFrame(code: String, message: String, inReplyTo: String?) {
        do {
            try channel.sendErrorFrame(code: code, message: message, inReplyTo: inReplyTo)
        } catch {
            Self.logger.debug(
                "Failed to send error frame (code=\(code, privacy: .public)) for '\(self.label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Frame consumer

    private static func consume(
        channel: VsockChannel,
        label: String,
        dispatch: @MainActor @escaping (Frame) -> Void
    ) async {
        do {
            for try await frame in channel.incoming {
                dispatch(frame)
            }
            logger.info("Vsock clipboard channel closed for '\(label, privacy: .public)'")
        } catch {
            logger.warning(
                "Vsock clipboard channel ended with error for '\(label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func handle(frame: Frame) {
        guard frame.protocolVersion == 1 else {
            Self.logger.warning(
                "Dropping frame with unsupported protocol version \(frame.protocolVersion, privacy: .public) for '\(self.label, privacy: .public)'"
            )
            return
        }
        switch frame.payload {
        case .clipboardOffer(let offer):
            handleOffer(offer)
        case .clipboardRequest(let request):
            handleRequest(request)
        case .clipboardData(let data):
            handleData(data)
        case .clipboardRelease(let release):
            handleRelease(release)
        case .error(let error):
            Self.logger.warning(
                "Guest clipboard error for '\(self.label, privacy: .public)': \(error.code, privacy: .public) — \(error.message, privacy: .public)"
            )
            // Clipboard-scoped peer errors are user-visible: the transfer the
            // user initiated did not complete on the other side.
            if error.code.hasPrefix("clipboard.") {
                lastTransferIssue = ClipboardTransferIssue(
                    kind: .peerReportedError(code: error.code, message: error.message),
                    date: Date()
                )
            }
        case .hello, .heartbeat, .policyUpdate, .logRecord, .none:
            // Hello, Heartbeat, and PolicyUpdate belong on the control
            // channel, LogRecord on the log channel. .none means a frame with
            // no payload. Any of these arriving here means the peer crossed
            // wires — log and ignore.
            Self.logger.warning(
                "Unexpected payload on clipboard channel for '\(self.label, privacy: .public)' — wrong port"
            )
        }
    }

    // MARK: - Inbound handlers

    private func handleOffer(_ offer: Kernova_V1_ClipboardOffer) {
        var request = Frame()
        request.protocolVersion = 1

        if !offer.utis.isEmpty {
            // UTI-capable peer: pull every advertised representation (the
            // sender already applied ClipboardSnapshotPolicy's caps).
            request.clipboardRequest = Kernova_V1_ClipboardRequest.with {
                $0.generation = offer.generation
                $0.utis = offer.utis
            }
        } else if offer.formats.contains(.textUtf8) {
            // Legacy peer: text is all it can serve.
            request.clipboardRequest = Kernova_V1_ClipboardRequest.with {
                $0.generation = offer.generation
                $0.format = .textUtf8
            }
        } else {
            Self.logger.debug(
                "Guest offer carries no usable format (formats=\(offer.formats.map(\.rawValue), privacy: .public)) — ignoring"
            )
            return
        }

        do {
            try channel.send(request)
            // Accept the latest offer only after the request is successfully
            // sent. If the send fails, leaving pendingInboundGeneration nil
            // lets the inbound side remain clean — no stale generation that
            // could cause a real ClipboardData to be dropped as "mismatch".
            pendingInboundGeneration = offer.generation
            Self.logger.debug(
                "Requested clipboard data from '\(self.label, privacy: .public)' (gen=\(offer.generation, privacy: .public))"
            )
        } catch {
            Self.logger.error(
                "Failed to send clipboard request: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func handleRequest(_ request: Kernova_V1_ClipboardRequest) {
        guard let pending = pendingOutbound, pending.generation == request.generation else {
            // Stale: the guest has already replaced or dropped the offer this targets.
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
                    code: Self.errorCodeFormatUnavailable,
                    message:
                        "Host has none of the requested representations (gen=\(request.generation))",
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
                    code: Self.errorCodeFormatUnavailable,
                    message:
                        "Host only carries TEXT_UTF8 on the legacy path (gen=\(request.generation), requested format=\(request.format.rawValue))",
                    inReplyTo: "clipboard.request"
                )
                return
            }
            guard let text = pending.content.text else {
                Self.logger.warning(
                    "Legacy text request but pending content has no text representation gen=\(pending.generation, privacy: .public)"
                )
                sendErrorFrame(
                    code: Self.errorCodeFormatUnavailable,
                    message: "Host content has no text representation (gen=\(pending.generation))",
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
                "Sent clipboard data to '\(self.label, privacy: .public)' (gen=\(pending.generation, privacy: .public), \(byteCount, privacy: .public) bytes)"
            )
        } catch VsockFrameError.frameTooLarge(let declaredSize, let maxAllowed) {
            // frameTooLarge: encoding failed before any bytes hit the wire,
            // so the channel is still healthy. grabIfChanged's size guard
            // makes this unreachable for policy-conformant content; it exists
            // so a guard regression degrades to an error message instead of
            // a silent paste failure.
            Self.logger.error(
                "Clipboard data exceeds frame limit gen=\(pending.generation, privacy: .public) frame=\(declaredSize, privacy: .public) max=\(maxAllowed, privacy: .public)"
            )
            lastTransferIssue = ClipboardTransferIssue(
                kind: .contentTooLarge(byteCount: declaredSize, limit: maxAllowed),
                date: Date()
            )
            sendErrorFrame(
                code: Self.errorCodeTooLarge,
                message:
                    "Host clipboard content exceeds the transfer limit (gen=\(pending.generation), \(byteCount) bytes)",
                inReplyTo: "clipboard.request"
            )
        } catch {
            // Logged at .error: this failure is user-visible (paste produces nothing).
            // Include gen + size so post-mortems can pair this with the peer's "request sent" log.
            Self.logger.error(
                "Failed to send clipboard data to '\(self.label, privacy: .public)' gen=\(pending.generation, privacy: .public) bytes=\(byteCount, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            // If the channel is dead, the peer will learn via EOF — no further fallback needed.
            sendErrorFrame(
                code: Self.errorCodeTransferFailure,
                message:
                    "Host failed to deliver clipboard data (gen=\(pending.generation), \(byteCount) bytes): \(error.localizedDescription)",
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
                    "Dropped \(data.representations.count - sanitized.count, privacy: .public) forbidden representation(s) from guest clipboard data gen=\(data.generation, privacy: .public)"
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
                    "Guest clipboard data not valid UTF-8 (\(data.data.count, privacy: .public) bytes)"
                )
                pendingInboundGeneration = nil
                return
            }
            content = ClipboardContent(text: text)
        } else {
            Self.logger.debug(
                "Guest clipboard data carries no usable payload (format=\(data.format.rawValue, privacy: .public))"
            )
            pendingInboundGeneration = nil
            return
        }

        clipboardContent = content
        // Reset the dedup so a subsequent grab from the host side actually
        // re-offers — otherwise round-tripping the same content would silently
        // drop the next outbound.
        lastGrabbedDigest = nil
        pendingInboundGeneration = nil
        lastTransferIssue = nil
        Self.logger.debug(
            "Received guest clipboard content for '\(self.label, privacy: .public)' (\(content.representations.count, privacy: .public) reps, \(content.totalByteCount, privacy: .public) bytes)"
        )
    }

    private func handleRelease(_ release: Kernova_V1_ClipboardRelease) {
        if pendingInboundGeneration == release.generation {
            pendingInboundGeneration = nil
            Self.logger.debug(
                "Guest released clipboard offer (gen=\(release.generation, privacy: .public)) for '\(self.label, privacy: .public)'"
            )
        }
    }
}
