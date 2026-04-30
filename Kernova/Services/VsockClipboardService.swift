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
@MainActor
@Observable
final class VsockClipboardService: ClipboardServicing {

    // MARK: - Observable state

    /// Bidirectional clipboard buffer. Set by the user (via the clipboard
    /// window) to seed an outbound offer; updated when the guest sends
    /// fresh data.
    var clipboardText: String = ""

    /// `true` once the guest agent has sent its `Hello`. Reset on disconnect.
    private(set) var isConnected: Bool = false

    // MARK: - Private state

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

    private static let logger = Logger(subsystem: "com.kernova.app", category: "VsockClipboardService")

    // MARK: - Init

    init(channel: VsockChannel, label: String) {
        self.channel = channel
        self.label = label
    }

    // MARK: - Lifecycle

    func start() {
        guard consumeTask == nil else { return }

        sendHello()

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
        // Plain `+=` traps on overflow rather than wrapping into 0, which is
        // the "no pending request" sentinel for the inbound side. UInt64.max
        // is unreachable in practice; the trap surfaces a real bug if the
        // counter ever runs that far.
        nextLocalGeneration += 1

        var offer = Frame()
        offer.protocolVersion = 1
        offer.clipboardOffer = Kernova_V1_ClipboardOffer.with {
            $0.generation = generation
            $0.formats = [.textUtf8]
        }

        do {
            try channel.send(offer)
            pendingOutbound = (generation: generation, text: clipboardText)
            lastGrabbedText = clipboardText
            Self.logger.notice(
                "Sent clipboard offer to '\(self.label, privacy: .public)' (gen=\(generation, privacy: .public), \(self.clipboardText.utf8.count, privacy: .public) bytes)"
            )
        } catch {
            Self.logger.error(
                "Failed to send clipboard offer for '\(self.label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Hello

    private func sendHello() {
        var hello = Frame()
        hello.protocolVersion = 1
        hello.hello = Kernova_V1_Hello.with {
            $0.serviceVersion = 1
            $0.capabilities = ["clipboard.text.utf8"]
            $0.agentInfo = Kernova_V1_AgentInfo.with {
                $0.os = "macOS"
                $0.osVersion = ProcessInfo.processInfo.operatingSystemVersionString
                $0.agentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "host"
            }
        }
        do {
            try channel.send(hello)
        } catch {
            Self.logger.error(
                "Failed to send clipboard hello for '\(self.label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
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
                await dispatch(frame)
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
        case .hello(let hello):
            isConnected = true
            Self.logger.notice(
                "Guest clipboard agent connected for '\(self.label, privacy: .public)' (service=\(hello.serviceVersion, privacy: .public), caps=\(hello.capabilities.joined(separator: ","), privacy: .public))"
            )
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
        case .logRecord, .none:
            // Wrong port for log records; .none means a frame with no payload.
            // Either way, ignore on the clipboard channel.
            Self.logger.debug(
                "Ignoring unexpected payload on clipboard channel for '\(self.label, privacy: .public)'"
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

        // Accept the latest offer. If a previous inbound was still pending,
        // the older `ClipboardData` will be discarded by `handleData` because
        // the generation no longer matches.
        pendingInboundGeneration = offer.generation

        var request = Frame()
        request.protocolVersion = 1
        request.clipboardRequest = Kernova_V1_ClipboardRequest.with {
            $0.generation = offer.generation
            $0.format = .textUtf8
        }
        do {
            try channel.send(request)
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
            Self.logger.debug(
                "Stale clipboard request gen=\(request.generation, privacy: .public) (pending=\(self.pendingOutbound?.generation ?? 0, privacy: .public))"
            )
            return
        }
        guard request.format == .textUtf8 else {
            Self.logger.debug(
                "Unsupported clipboard format requested: \(request.format.rawValue, privacy: .public)"
            )
            return
        }
        guard let bytes = pending.text.data(using: .utf8) else {
            Self.logger.warning(
                "Failed to encode clipboard text as UTF-8 (\(pending.text.count, privacy: .public) chars)"
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
            Self.logger.error(
                "Failed to send clipboard data: \(error.localizedDescription, privacy: .public)"
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
