import Foundation
import os

/// Manages SPICE clipboard sharing between the host and a single guest VM.
///
/// Instead of using Apple's `VZSpiceAgentPortAttachment` (which automatically syncs
/// with the host `NSPasteboard`), this service speaks the SPICE agent protocol directly
/// over raw pipe I/O. Clipboard data is surfaced in an observable property for the UI
/// rather than written to the system clipboard.
///
/// The service acts as the SPICE **client** (host side). The guest runs a standard
/// SPICE agent (`spice-vdagent` on Linux, or a macOS equivalent).
///
/// ## Lifecycle
/// - Created by `VMInstance.startClipboardService()` after VM start
/// - Destroyed by `VMInstance.stopClipboardService()` on teardown
@MainActor
@Observable
final class SpiceClipboardService {

    // MARK: - Observable State

    /// Unified clipboard text buffer shared between guest and host.
    ///
    /// - Set by the guest agent when the guest copies text (via `handleClipboardData`)
    /// - Editable by the user in the clipboard window's `TextEditor`
    /// - Announced to the guest (via `CLIPBOARD_GRAB`) when the clipboard window loses
    ///   focus; the guest then requests the actual data via `CLIPBOARD_REQUEST`
    var clipboardText: String = ""

    /// `true` once the guest agent has completed the capabilities handshake.
    private(set) var isConnected: Bool = false

    // MARK: - Private

    private let inputPipe: Pipe    // host writes → guest reads
    private let outputPipe: Pipe   // guest writes → host reads
    private var parser = SpiceAgentParser()

    /// Holds the text for the guest's `CLIPBOARD_REQUEST` response.
    private var pendingOutboundText: String?

    /// Tracks the last text we sent via GRAB to avoid redundant grabs.
    private var lastGrabbedText: String?

    /// Whether the guest advertised `VD_AGENT_CAP_CLIPBOARD_BY_DEMAND`.
    /// When `false` (legacy mode), we send clipboard data immediately after GRAB
    /// instead of waiting for a REQUEST.
    private var guestSupportsByDemand = false

    private static let logger = Logger(subsystem: "com.kernova.app", category: "SpiceClipboardService")

    // MARK: - Init

    init(inputPipe: Pipe, outputPipe: Pipe) {
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
    }

    // MARK: - Lifecycle

    /// Begins reading from the guest pipe and sends the initial capabilities handshake.
    func start() {
        startReading()
        sendCapabilities()
        Self.logger.info("SPICE clipboard service started")
    }

    /// Stops reading and releases resources.
    func stop() {
        outputPipe.fileHandleForReading.readabilityHandler = nil
        isConnected = false
        pendingOutboundText = nil
        guestSupportsByDemand = false
        Self.logger.info("SPICE clipboard service stopped")
    }

    // MARK: - Public API

    /// Sends a `CLIPBOARD_GRAB` to the guest if `clipboardText` has been edited
    /// since the last grab (or since the guest last sent us data).
    ///
    /// Called by `ClipboardWindowController` when the clipboard window loses focus.
    /// - **By-demand guests** (modern): the guest sends a `CLIPBOARD_REQUEST` when
    ///   something pastes, and we respond with `clipboardText` at that point.
    /// - **Legacy guests**: we send `CLIPBOARD` data immediately after the GRAB.
    func grabIfChanged() {
        guard isConnected else { return }
        guard !clipboardText.isEmpty else { return }
        guard clipboardText != lastGrabbedText else { return }

        let grabMessage = SpiceMessageBuilder.buildClipboardGrab(types: [.utf8Text])
        guard writeToGuest(grabMessage) else { return }

        // Only update state after successful write — otherwise a failed grab
        // would permanently prevent retries (clipboardText == lastGrabbedText).
        lastGrabbedText = clipboardText
        pendingOutboundText = clipboardText

        if !guestSupportsByDemand {
            // Legacy mode: guest won't send REQUEST, deliver data immediately.
            // Reset lastGrabbedText on failure so the next call retries.
            if !sendClipboardText(clipboardText) {
                lastGrabbedText = nil
            }
        }

        Self.logger.notice("Sent clipboard grab (\(self.clipboardText.utf8.count, privacy: .public) bytes pending, byDemand: \(self.guestSupportsByDemand, privacy: .public))")
    }

    // MARK: - Reading

    /// Hooks the readability handler on the output pipe to receive guest messages.
    private func startReading() {
        // Capture for the closure (runs on a background GCD queue)
        let logger = Self.logger

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF — pipe closed. Nil-out immediately to prevent GCD spin loop.
                handle.readabilityHandler = nil
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isConnected = false
                    Self.logger.notice("SPICE pipe closed (EOF)")
                }
                return
            }

            logger.debug("Received \(data.count, privacy: .public) bytes from guest SPICE agent")

            Task { @MainActor [weak self] in
                self?.handleIncomingData(data)
            }
        }
    }

    private func handleIncomingData(_ data: Data) {
        let messages = parser.feed(data)

        if parser.didReset {
            Self.logger.error("SPICE parser buffer reset — stream may be corrupted")
        }

        for message in messages {
            switch message {
            case .announceCapabilities(let request, let caps):
                handleCapabilities(request: request, caps: caps)

            case .clipboardGrab(let types):
                handleClipboardGrab(types: types)

            case .clipboardRequest(let type):
                handleClipboardRequest(type: type)

            case .clipboardData(let type, let data):
                handleClipboardData(type: type, data: data)

            case .clipboardRelease:
                Self.logger.debug("Guest released clipboard")

            case .other(let type):
                Self.logger.debug("Ignoring unhandled SPICE message type: \(type.rawValue, privacy: .public)")

            case .malformedChunk:
                Self.logger.warning("Skipping malformed SPICE chunk")
            }
        }
    }

    // MARK: - Message Handlers

    // RATIONALE: Modern agents (spice-vdagent, UTM) only set VD_AGENT_CAP_CLIPBOARD_BY_DEMAND
    // (bit 5) — the legacy VD_AGENT_CAP_CLIPBOARD (bit 3) is the old "always-sync" mode that
    // no current agent advertises. We accept either bit as proof of clipboard support.
    private func handleCapabilities(request: Bool, caps: [UInt32]) {
        let hasClipboard = hasCapability(caps, .clipboard)
        let byDemand = hasCapability(caps, .clipboardByDemand)

        guard hasClipboard || byDemand else {
            Self.logger.warning("Guest agent does not support clipboard (caps: \(caps.map { String($0, radix: 16) }, privacy: .public))")
            return
        }

        isConnected = true
        guestSupportsByDemand = byDemand

        // If the guest requested our capabilities, send them back (non-requesting)
        if request {
            let reply = SpiceMessageBuilder.buildAnnounceCapabilities(request: false)
            guard writeToGuest(reply) else { return }
        }

        Self.logger.notice(
            "Guest agent connected (caps: \(caps.map { String($0, radix: 16) }, privacy: .public), byDemand: \(byDemand, privacy: .public))"
        )
    }

    /// Guest announced it has new clipboard data — request it.
    private func handleClipboardGrab(types: [SpiceClipboardType]) {
        Self.logger.debug("Guest clipboard grab: types=\(types.map(\.rawValue), privacy: .public)")

        // We only handle UTF-8 text for now
        guard types.contains(.utf8Text) else {
            Self.logger.debug("Guest clipboard has no UTF-8 text type, ignoring")
            return
        }

        let request = SpiceMessageBuilder.buildClipboardRequest(type: .utf8Text)
        guard writeToGuest(request) else { return }
    }

    /// Guest is requesting clipboard data from us (response to our GRAB).
    private func handleClipboardRequest(type: SpiceClipboardType) {
        Self.logger.debug("Guest requested clipboard data (type: \(type.rawValue, privacy: .public))")

        guard type == .utf8Text else {
            Self.logger.debug("Guest requested non-text type, ignoring")
            return
        }

        guard let text = pendingOutboundText else {
            Self.logger.debug("No pending outbound text for clipboard request")
            return
        }

        // Keep pendingOutboundText intact — the guest agent may retry the request
        sendClipboardText(text)
    }

    /// Guest delivered clipboard data — update our observable state.
    private func handleClipboardData(type: SpiceClipboardType, data: Data) {
        guard type == .utf8Text else {
            Self.logger.debug("Received non-text clipboard data (type: \(type.rawValue, privacy: .public)), ignoring")
            return
        }

        guard let text = String(data: data, encoding: .utf8) else {
            Self.logger.warning("Failed to decode guest clipboard data as UTF-8 (\(data.count, privacy: .public) bytes)")
            return
        }

        clipboardText = text
        lastGrabbedText = nil  // New text is from the guest, not us
        Self.logger.debug("Received guest clipboard text (\(text.count, privacy: .public) characters)")
    }

    // MARK: - Writing

    /// Encodes text as UTF-8 and sends a `CLIPBOARD` data message to the guest.
    @discardableResult
    private func sendClipboardText(_ text: String) -> Bool {
        guard let textData = text.data(using: .utf8) else {
            Self.logger.warning("Failed to encode clipboard text as UTF-8 (\(text.count, privacy: .public) characters)")
            return false
        }
        let dataMessage = SpiceMessageBuilder.buildClipboardData(type: .utf8Text, data: textData)
        return writeToGuest(dataMessage)
    }

    private func writeToGuest(_ data: Data) -> Bool {
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
            return true
        } catch {
            Self.logger.error("Failed to write to SPICE pipe: \(error.localizedDescription, privacy: .public)")
            isConnected = false
            return false
        }
    }

    // MARK: - Capability Helpers

    private func sendCapabilities() {
        let message = SpiceMessageBuilder.buildAnnounceCapabilities(request: true)
        writeToGuest(message)
        Self.logger.debug("Sent ANNOUNCE_CAPABILITIES (requesting guest reply)")
    }

    private func hasCapability(_ caps: [UInt32], _ cap: SpiceAgentCapability) -> Bool {
        let wordIndex = cap.rawValue / 32
        let bitIndex = cap.rawValue % 32
        guard wordIndex < caps.count else { return false }
        return (caps[wordIndex] & (1 << UInt32(bitIndex))) != 0
    }
}
