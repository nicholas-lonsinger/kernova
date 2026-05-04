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

    /// Bidirectional clipboard buffer. Set by the user (via the clipboard
    /// window) to seed an outbound offer; updated when the guest sends
    /// fresh data.
    var clipboardText: String = ""

    /// `true` once `start()` has been called. The clipboard channel is
    /// established by `VsockListenerHost` accepting a connection — by the time
    /// this service is constructed the socket is up, so connectivity is
    /// equivalent to "started and not yet stopped". A separate liveness signal
    /// (whether the agent process is still responsive) lives on the control
    /// channel and surfaces via `VMInstance.agentStatus`.
    private(set) var isConnected: Bool = false

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

    /// Counter for outbound offer generations. Starts at 1 so 0 can serve as
    /// "no pending request" sentinel for the inbound side.
    private var nextLocalGeneration: UInt64 = 1

    /// The most recent offer we sent the guest. Held until the guest requests
    /// (or supersedes) it so we can answer `ClipboardRequest`.
    private var pendingOutbound: (generation: UInt64, text: String)?

    /// The most recent offer the guest sent us that we asked to receive. We
    /// track it so a delayed `ClipboardData` for an older offer can be
    /// dropped.
    private var pendingInboundGeneration: UInt64?

    /// Last text we successfully announced. Skips redundant offers when
    /// `grabIfChanged()` is called repeatedly with the same content.
    private var lastGrabbedText: String?

    /// Exposes `pendingInboundGeneration` for tests that need to assert the
    /// inbound-request lifecycle without relying on observable side effects.
    ///
    /// A seam is used here rather than a behavioral assertion (e.g. sending a
    /// stale `ClipboardData` and checking `clipboardText` wasn't overwritten)
    /// because any channel teardown resets `pendingInboundGeneration` to `nil`
    /// via `stop()`. That reset would satisfy a behavioral assertion for the
    /// wrong reason, masking a regression in the generation commit logic itself.
    var pendingInboundGenerationForTesting: UInt64? { pendingInboundGeneration }

    private static let logger = Logger(subsystem: "com.kernova.app", category: "VsockClipboardService")

    private static let errorCodeFormatUnavailable = "clipboard.format.unavailable"
    private static let errorCodeEncodingFailure = "clipboard.transfer.encoding.failure"
    private static let errorCodeTransferFailure = "clipboard.transfer.send.failure"

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
        guard !clipboardText.isEmpty else { return }
        guard clipboardText != lastGrabbedText else { return }

        let generation = nextLocalGeneration

        var offer = Frame()
        offer.protocolVersion = 1
        offer.clipboardOffer = Kernova_V1_ClipboardOffer.with {
            $0.generation = generation
            $0.formats = [.textUtf8]
        }

        do {
            try channel.send(offer)
            // Plain `+=` traps on overflow rather than wrapping into 0,
            // which the inbound side uses as a "no pending offer" sentinel.
            // UInt64.max is unreachable in practice.
            nextLocalGeneration += 1
            pendingOutbound = (generation: generation, text: clipboardText)
            lastGrabbedText = clipboardText
            Self.logger.notice(
                "Sent clipboard offer to '\(self.label, privacy: .public)' (gen=\(generation, privacy: .public), \(self.clipboardText.utf8.count, privacy: .public) bytes)"
            )
        } catch {
            // State left untouched: lastGrabbedText still differs from
            // clipboardText, generation still unconsumed — next call will
            // re-attempt the same offer.
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
        case .hello, .heartbeat, .logRecord, .none:
            // Hello and Heartbeat belong on the control channel, LogRecord on
            // the log channel. .none means a frame with no payload. Any of
            // these arriving here means the peer crossed wires — log and ignore.
            Self.logger.warning(
                "Unexpected payload on clipboard channel for '\(self.label, privacy: .public)' — wrong port"
            )
        }
    }

    // MARK: - Inbound handlers

    private func handleOffer(_ offer: Kernova_V1_ClipboardOffer) {
        guard offer.formats.contains(.textUtf8) else {
            Self.logger.debug(
                "Guest offer omits TEXT_UTF8 (formats=\(offer.formats.map(\.rawValue), privacy: .public)) — ignoring"
            )
            return
        }

        var request = Frame()
        request.protocolVersion = 1
        request.clipboardRequest = Kernova_V1_ClipboardRequest.with {
            $0.generation = offer.generation
            $0.format = .textUtf8
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
        guard request.format == .textUtf8 else {
            Self.logger.warning(
                "Unsupported clipboard format requested gen=\(request.generation, privacy: .public) format=\(request.format.rawValue, privacy: .public)"
            )
            sendErrorFrame(
                code: Self.errorCodeFormatUnavailable,
                message: "Host only carries TEXT_UTF8 (gen=\(request.generation), requested format=\(request.format.rawValue))",
                inReplyTo: "clipboard.request"
            )
            return
        }
        guard let bytes = pending.text.data(using: .utf8) else {
            Self.logger.warning(
                "Failed to encode clipboard text as UTF-8 gen=\(pending.generation, privacy: .public) chars=\(pending.text.count, privacy: .public)"
            )
            sendErrorFrame(
                code: Self.errorCodeEncodingFailure,
                message: "Host could not encode \(pending.text.count) characters as UTF-8 (gen=\(pending.generation))",
                inReplyTo: "clipboard.request"
            )
            return
        }

        var dataFrame = Frame()
        dataFrame.protocolVersion = 1
        dataFrame.clipboardData = Kernova_V1_ClipboardData.with {
            $0.generation = pending.generation
            $0.format = .textUtf8
            $0.data = bytes
        }
        do {
            try channel.send(dataFrame)
            Self.logger.debug(
                "Sent clipboard data to '\(self.label, privacy: .public)' (gen=\(pending.generation, privacy: .public), \(bytes.count, privacy: .public) bytes)"
            )
        } catch {
            // Logged at .error: this failure is user-visible (paste produces nothing).
            // Include gen + size so post-mortems can pair this with the peer's "request sent" log.
            Self.logger.error(
                "Failed to send clipboard data to '\(self.label, privacy: .public)' gen=\(pending.generation, privacy: .public) bytes=\(bytes.count, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            // If the channel is dead, the peer will learn via EOF — no further fallback needed.
            sendErrorFrame(
                code: Self.errorCodeTransferFailure,
                message: "Host failed to deliver clipboard data (gen=\(pending.generation), \(bytes.count) bytes): \(error.localizedDescription)",
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
        guard data.format == .textUtf8 else { return }
        guard let text = String(data: data.data, encoding: .utf8) else {
            Self.logger.warning(
                "Guest clipboard data not valid UTF-8 (\(data.data.count, privacy: .public) bytes)"
            )
            return
        }

        clipboardText = text
        // Reset the dedup so a subsequent grab from the host side actually
        // re-offers — otherwise round-tripping the same text would silently
        // drop the next outbound.
        lastGrabbedText = nil
        pendingInboundGeneration = nil
        Self.logger.debug(
            "Received guest clipboard text for '\(self.label, privacy: .public)' (\(text.count, privacy: .public) chars)"
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
