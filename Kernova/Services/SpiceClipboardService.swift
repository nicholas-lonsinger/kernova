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

    /// The latest text received from the guest clipboard. Updated on the main actor.
    var guestClipboardText: String = ""

    /// `true` once the guest agent has completed the capabilities handshake.
    var isConnected: Bool = false

    // MARK: - Private

    private let inputPipe: Pipe    // host writes → guest reads
    private let outputPipe: Pipe   // guest writes → host reads
    private var parser = SpiceAgentParser()

    /// Pending clipboard request: when we send a GRAB, the guest replies with a REQUEST,
    /// and we respond with the DATA. This holds the text until the request arrives.
    private var pendingOutboundText: String?

    /// Whether the guest has advertised `VD_AGENT_CAP_CLIPBOARD_BY_DEMAND`.
    private var guestSupportsClipboardByDemand = false

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
        Self.logger.info("SPICE clipboard service stopped")
    }

    // MARK: - Public API

    /// Sends text to the guest clipboard.
    ///
    /// Sends a `CLIPBOARD_GRAB` to announce ownership, then waits for the guest
    /// agent to send a `CLIPBOARD_REQUEST` before delivering the data. The text
    /// is stored in `pendingOutboundText` and kept across multiple requests so
    /// the agent can retry if needed.
    ///
    /// Sending data eagerly (before the REQUEST) does not work — the guest agent's
    /// state machine rejects unsolicited CLIPBOARD data and retries via REQUEST.
    func sendToGuest(_ text: String) {
        guard isConnected else {
            Self.logger.warning("Cannot send clipboard: guest agent not connected")
            return
        }

        guard let textData = text.data(using: .utf8), !textData.isEmpty else {
            Self.logger.debug("sendToGuest: empty or non-encodable text, skipping")
            return
        }

        Self.logger.notice("sendToGuest: sending clipboard grab (\(textData.count, privacy: .public) bytes pending)")

        // Store for the guest's CLIPBOARD_REQUEST response
        pendingOutboundText = text

        // Announce we have clipboard data — the guest will request it when ready
        let grabMessage = SpiceMessageBuilder.buildClipboardGrab(types: [.utf8Text])
        writeToGuest(grabMessage)
    }

    // MARK: - Reading

    /// Hooks the readability handler on the output pipe to receive guest messages.
    private func startReading() {
        // Capture for the closure (runs on a background GCD queue)
        let logger = Self.logger

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            logger.debug("Received \(data.count, privacy: .public) bytes from guest SPICE agent")

            Task { @MainActor [weak self] in
                self?.handleIncomingData(data)
            }
        }
    }

    /// Parses incoming data and dispatches messages.
    private func handleIncomingData(_ data: Data) {
        let messages = parser.feed(data)

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
            }
        }
    }

    // MARK: - Message Handlers

    private func handleCapabilities(request: Bool, caps: [UInt32]) {
        isConnected = true

        // Check if guest supports clipboard-by-demand
        guestSupportsClipboardByDemand = hasCapability(
            caps, .clipboardByDemand
        )

        Self.logger.notice(
            "Guest agent connected (caps: \(caps.map { String($0, radix: 16) }, privacy: .public), byDemand: \(self.guestSupportsClipboardByDemand, privacy: .public))"
        )

        // If the guest requested our capabilities, send them back (non-requesting)
        if request {
            let reply = SpiceMessageBuilder.buildAnnounceCapabilities(request: false)
            writeToGuest(reply)
        }
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
        writeToGuest(request)
    }

    /// Guest is requesting clipboard data from us (response to our GRAB).
    private func handleClipboardRequest(type: SpiceClipboardType) {
        Self.logger.debug("Guest requested clipboard data (type: \(type.rawValue, privacy: .public))")

        guard type == .utf8Text else {
            Self.logger.debug("Guest requested non-text type, ignoring")
            return
        }

        guard let text = pendingOutboundText,
              let textData = text.data(using: .utf8) else {
            Self.logger.debug("No pending outbound text for clipboard request")
            return
        }

        // Keep pendingOutboundText intact — the guest agent may retry the request
        let dataMessage = SpiceMessageBuilder.buildClipboardData(type: .utf8Text, data: textData)
        writeToGuest(dataMessage)
        Self.logger.debug("Sent clipboard data to guest (\(textData.count, privacy: .public) bytes)")
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

        guestClipboardText = text
        Self.logger.debug("Received guest clipboard text (\(text.count, privacy: .public) characters)")
    }

    // MARK: - Writing

    private func writeToGuest(_ data: Data) {
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            Self.logger.error("Failed to write to SPICE pipe: \(error.localizedDescription, privacy: .public)")
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
