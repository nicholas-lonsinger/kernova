import AppKit
import Foundation
import KernovaProtocol

// MARK: - Pasteboard protocol

/// Subset of `NSPasteboard` actually used by `VsockGuestClipboardAgent`.
///
/// RATIONALE: `NSPasteboard.general` is a process-wide singleton with no
/// mockable surface; this protocol is the cheapest seam that lets tests run
/// without touching the developer's real clipboard.
protocol Pasteboard: AnyObject {
    var changeCount: Int { get }
    func string(forType type: NSPasteboard.PasteboardType) -> String?
    @discardableResult func clearContents() -> Int
    @discardableResult func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool
}

extension NSPasteboard: Pasteboard {}

// MARK: - VsockGuestClipboardAgent

/// Guest-side clipboard agent that talks to the host's `VsockClipboardService`
/// on `KernovaVsockPort.clipboard` (49152).
///
/// Runs the offer/request/data state machine symmetrically:
/// - Outbound: a 0.5 s `NSPasteboard` poll detects local clipboard changes
///   and announces them via `ClipboardOffer` with a monotonically increasing
///   generation, then answers the host's `ClipboardRequest` with the bytes.
/// - Inbound: when the host sends an offer the agent immediately requests
///   the bytes; on `ClipboardData` it writes the text to the guest's
///   `NSPasteboard.general`.
///
/// Connection lifecycle (connect, retry on failure, EOF handling) is owned by
/// `VsockGuestClient`. This class layers the protocol on top.
///
/// All mutable state is accessed exclusively on the main dispatch queue.
// RATIONALE: @unchecked Sendable with DispatchQueue.main serialization is
// used because @MainActor is impractical here — the entry point is
// main.swift top-level code (nonisolated in Swift 6), not an @main app.
final class VsockGuestClipboardAgent: @unchecked Sendable {

    private static let logger = KernovaLogger(subsystem: "com.kernova.agent", category: "VsockGuestClipboardAgent")
    private static let pollingInterval: TimeInterval = 0.5

    private let client: VsockGuestClient
    private let pasteboard: Pasteboard

    // MARK: - Main-queue state

    /// Live channel for the current connection, if any. Nil between
    /// connections; checked by the polling timer to short-circuit when
    /// the host isn't reachable.
    private var liveChannel: VsockChannel?

    /// Counter for outbound offer generations. Starts at 1 so 0 can serve as
    /// "no pending request" sentinel for the inbound side.
    private var nextLocalGeneration: UInt64 = 1

    /// The most recent offer we sent the host; held until the host responds
    /// with a request (or supersedes it with a newer offer of our own).
    private var pendingOutbound: (generation: UInt64, text: String)?

    /// Last inbound offer we requested data for. Used to drop a delayed
    /// `ClipboardData` for an older offer.
    private var pendingInboundGeneration: UInt64?

    /// Last `NSPasteboard.changeCount` we observed. Set after every
    /// poll cycle and after every host write so we don't echo back our own
    /// content.
    private var lastPasteboardChangeCount: Int

    /// The most recent text we sent or wrote. Suppresses re-offering after
    /// a host-driven write and avoids redundant offers when the user
    /// touches the clipboard without changing the contents.
    private var lastSeenText: String?

    private var pollingTimer: DispatchSourceTimer?

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
    }

    // MARK: - Lifecycle

    /// Begins the connect/serve loop and the local pasteboard poll.
    func start() {
        client.start { [weak self] channel in
            await self?.serve(channel: channel)
        }
        DispatchQueue.main.async { [weak self] in
            self?.startPolling()
        }
        Self.logger.notice("Vsock clipboard agent started")
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
        // Send Hello *before* publishing the channel for the polling timer,
        // so any offer the timer dispatches is guaranteed to land on the host
        // after Hello — the host doesn't otherwise gate offer handling on
        // hello completion, but ordering keeps the wire trace coherent.
        sendHello(on: channel)

        DispatchQueue.main.async { [weak self] in
            self?.liveChannel = channel
            self?.pendingOutbound = nil
            self?.pendingInboundGeneration = nil
            // The host on the other end may be a brand-new instance (host
            // app restarted, VM stopped+started, etc.) that has no record
            // of prior offers. Clear the dedup state so the next poll
            // cycle re-announces the current clipboard rather than
            // assuming the host already has it.
            self?.lastSeenText = nil
            self?.lastPasteboardChangeCount = -1
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

        DispatchQueue.main.async { [weak self] in
            if self?.liveChannel === channel {
                self?.liveChannel = nil
                self?.pendingOutbound = nil
                self?.pendingInboundGeneration = nil
            }
        }
    }

    // MARK: - Pasteboard polling (main queue)

    private func startPolling() {
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

        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            lastPasteboardChangeCount = currentCount
            return
        }
        // Don't echo back text we just wrote from the host.
        guard text != lastSeenText else {
            lastPasteboardChangeCount = currentCount
            return
        }

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
            pendingOutbound = (generation: generation, text: text)
            lastSeenText = text
            lastPasteboardChangeCount = currentCount
            Self.logger.notice(
                "Sent clipboard offer (gen=\(generation, privacy: .public), \(text.utf8.count, privacy: .public) bytes)"
            )
        } catch {
            // State left untouched: lastSeenText still differs from `text`,
            // changeCount still old, generation still unconsumed — the next
            // poll cycle will re-attempt the same offer.
            Self.logger.warning(
                "Failed to send clipboard offer: \(error.localizedDescription, privacy: .public)"
            )
        }
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
        case .hello(let hello):
            Self.logger.notice(
                "Host clipboard service ready (caps: \(hello.capabilities.joined(separator: ","), privacy: .public))"
            )
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
        case .logRecord, .none:
            Self.logger.debug("Ignoring unexpected payload on clipboard channel")
        }
    }

    private func handleOffer(_ offer: Kernova_V1_ClipboardOffer, channel: VsockChannel) {
        guard offer.formats.contains(.textUtf8) else {
            Self.logger.debug(
                "Host offer omits TEXT_UTF8 (formats=\(offer.formats.map(\.rawValue), privacy: .public))"
            )
            return
        }
        pendingInboundGeneration = offer.generation

        var request = Frame()
        request.protocolVersion = 1
        request.clipboardRequest = Kernova_V1_ClipboardRequest.with {
            $0.generation = offer.generation
            $0.format = .textUtf8
        }
        do {
            try channel.send(request)
            Self.logger.debug("Requested clipboard data from host (gen=\(offer.generation, privacy: .public))")
        } catch {
            Self.logger.warning(
                "Failed to send clipboard request: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func handleRequest(_ request: Kernova_V1_ClipboardRequest, channel: VsockChannel) {
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
                "Sent clipboard data (gen=\(pending.generation, privacy: .public), \(bytes.count, privacy: .public) bytes)"
            )
        } catch {
            Self.logger.warning(
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
                "Host clipboard data not valid UTF-8 (\(data.data.count, privacy: .public) bytes)"
            )
            return
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Record so the polling timer doesn't echo this back to the host
        // on the next change-count tick.
        lastPasteboardChangeCount = pasteboard.changeCount
        lastSeenText = text
        pendingInboundGeneration = nil
        Self.logger.notice(
            "Wrote host clipboard to pasteboard (\(text.count, privacy: .public) chars)"
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

    // MARK: - Hello

    private func sendHello(on channel: VsockChannel) {
        var hello = Frame()
        hello.protocolVersion = 1
        hello.hello = Kernova_V1_Hello.with {
            $0.serviceVersion = 1
            $0.capabilities = ["clipboard.text.utf8"]
            $0.agentInfo = Kernova_V1_AgentInfo.with {
                $0.os = "macOS"
                $0.osVersion = ProcessInfo.processInfo.operatingSystemVersionString
                $0.agentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
            }
        }
        do {
            try channel.send(hello)
        } catch {
            Self.logger.warning(
                "Failed to send clipboard Hello: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
