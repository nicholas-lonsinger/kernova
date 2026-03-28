import AppKit
import Foundation
import os

/// Guest-side SPICE clipboard agent that communicates with the host's `SpiceClipboardService`.
///
/// Mirrors the host-side `SpiceClipboardService` but with reversed message direction:
/// - Sends messages with `SpiceConstants.clientPort` (VDP_CLIENT_PORT = 1)
/// - Reads messages sent by the host on `SpiceConstants.serverPort` (VDP_SERVER_PORT = 2)
///
/// All mutable state is accessed exclusively on the main dispatch queue.
// RATIONALE: @unchecked Sendable with DispatchQueue.main serialization is used because
// @MainActor is impractical here — the entry point is main.swift top-level code
// (nonisolated in Swift 6), not an @main app.
final class GuestClipboardAgent: @unchecked Sendable {

    // MARK: - Callback

    /// Called when the device becomes unavailable (EOF or write error).
    /// The caller (main.swift) uses this to trigger a reconnect cycle.
    var onDisconnect: (() -> Void)?

    // MARK: - Private State (main queue only)

    private var parser = SpiceAgentParser()
    private var isConnected = false
    private var hostSupportsByDemand = false

    private var lastPasteboardChangeCount: Int = 0
    private var pendingOutboundText: String?
    private var lastGrabbedText: String?

    // MARK: - I/O

    private let deviceHandle: FileHandle
    private var pollingTimer: DispatchSourceTimer?

    // MARK: - Constants

    private static let pollingInterval: TimeInterval = 0.5

    private static let logger = Logger(subsystem: "com.kernova.agent", category: "GuestClipboardAgent")

    // MARK: - Init

    init(deviceHandle: FileHandle) {
        self.deviceHandle = deviceHandle
        self.lastPasteboardChangeCount = NSPasteboard.general.changeCount
    }

    // MARK: - Lifecycle

    /// Begins reading from the device, sends the initial capabilities handshake,
    /// and starts clipboard polling.
    func start() {
        startReading()
        sendCapabilities(request: true)
        startClipboardPolling()
        Self.logger.notice("Guest clipboard agent started")
    }

    /// Stops polling, reading, and releases the device.
    /// Does not invoke `onDisconnect` — used for intentional shutdown, not device loss.
    func stop() {
        tearDown()
        Self.logger.notice("Guest clipboard agent stopped")
    }

    // MARK: - Reading

    private func startReading() {
        let logger = Self.logger

        deviceHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF — device closed (VM paused, device removed, etc.)
                // Nil-out immediately to prevent GCD spin loop.
                handle.readabilityHandler = nil
                DispatchQueue.main.async { [weak self] in
                    self?.handleDeviceEOF()
                }
                return
            }

            logger.debug("Read \(data.count, privacy: .public) bytes from SPICE device")

            DispatchQueue.main.async { [weak self] in
                self?.handleIncomingData(data)
            }
        }
    }

    private func handleDeviceEOF() {
        Self.logger.notice("SPICE device closed (EOF)")
        disconnect()
    }

    private func tearDown() {
        pollingTimer?.cancel()
        pollingTimer = nil
        deviceHandle.readabilityHandler = nil
        isConnected = false
    }

    /// Tears down and notifies the caller to trigger reconnection.
    private func disconnect() {
        tearDown()
        onDisconnect?()
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
                Self.logger.debug("Host released clipboard")

            case .other(let type):
                Self.logger.debug("Ignoring unhandled SPICE message type: \(type.rawValue, privacy: .public)")

            case .malformedChunk:
                Self.logger.warning("Skipping malformed SPICE chunk")
            }
        }
    }

    // MARK: - Message Handlers

    private func handleCapabilities(request: Bool, caps: [UInt32]) {
        let hasClipboard = SpiceMessageBuilder.hasCapability(caps, .clipboard)
        let byDemand = SpiceMessageBuilder.hasCapability(caps, .clipboardByDemand)

        guard hasClipboard || byDemand else {
            Self.logger.warning("Host does not support clipboard (caps: \(caps.map { String($0, radix: 16) }, privacy: .public))")
            return
        }

        isConnected = true
        hostSupportsByDemand = byDemand

        // If the host requested our capabilities, send them back (non-requesting)
        if request {
            sendCapabilities(request: false)
        }

        Self.logger.notice(
            "Host connected (caps: \(caps.map { String($0, radix: 16) }, privacy: .public), byDemand: \(byDemand, privacy: .public))"
        )
    }

    /// Host announced it has new clipboard data — request it.
    private func handleClipboardGrab(types: [SpiceClipboardType]) {
        Self.logger.debug("Host clipboard grab: types=\(types.map(\.rawValue), privacy: .public)")

        guard types.contains(.utf8Text) else {
            Self.logger.debug("Host clipboard has no UTF-8 text type, ignoring")
            return
        }

        let request = SpiceMessageBuilder.buildClipboardRequest(
            type: .utf8Text,
            port: SpiceConstants.clientPort
        )
        writeToHost(request)
    }

    /// Host is requesting clipboard data from us (response to our GRAB).
    private func handleClipboardRequest(type: SpiceClipboardType) {
        Self.logger.debug("Host requested clipboard data (type: \(type.rawValue, privacy: .public))")

        guard type == .utf8Text else {
            Self.logger.debug("Host requested non-text type, ignoring")
            return
        }

        guard let text = pendingOutboundText else {
            Self.logger.debug("No pending outbound text for clipboard request")
            return
        }

        sendClipboardText(text)
    }

    /// Host delivered clipboard data — write to the guest pasteboard.
    private func handleClipboardData(type: SpiceClipboardType, data: Data) {
        guard type == .utf8Text else {
            Self.logger.debug("Received non-text clipboard data (type: \(type.rawValue, privacy: .public)), ignoring")
            return
        }

        guard let text = String(data: data, encoding: .utf8) else {
            Self.logger.warning("Failed to decode host clipboard data as UTF-8 (\(data.count, privacy: .public) bytes)")
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Record the change count and text to suppress echo detection in the polling timer
        lastPasteboardChangeCount = pasteboard.changeCount
        lastGrabbedText = text

        Self.logger.debug("Wrote host clipboard to pasteboard (\(text.count, privacy: .public) chars)")
    }

    // MARK: - Clipboard Polling

    private func startClipboardPolling() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.pollingInterval, repeating: Self.pollingInterval)
        timer.setEventHandler { [weak self] in
            self?.checkClipboardChange()
        }
        timer.resume()
        pollingTimer = timer
    }

    private func checkClipboardChange() {
        guard isConnected else { return }

        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount

        guard currentCount != lastPasteboardChangeCount else { return }

        guard let text = pasteboard.string(forType: .string),
              !text.isEmpty else {
            lastPasteboardChangeCount = currentCount
            return
        }

        // Avoid echoing back text we just wrote to the pasteboard from the host
        guard text != lastGrabbedText else {
            lastPasteboardChangeCount = currentCount
            return
        }

        pendingOutboundText = text
        lastGrabbedText = text

        let grabMessage = SpiceMessageBuilder.buildClipboardGrab(
            types: [.utf8Text],
            port: SpiceConstants.clientPort
        )
        guard writeToHost(grabMessage) else { return }

        if !hostSupportsByDemand {
            // Legacy mode: host won't send REQUEST, deliver data immediately.
            if !sendClipboardText(text) {
                lastGrabbedText = nil
                return
            }
        }

        // Update change count only after successfully initiating the sync
        lastPasteboardChangeCount = currentCount

        Self.logger.debug("Sent clipboard grab (\(text.utf8.count, privacy: .public) bytes pending, byDemand: \(self.hostSupportsByDemand, privacy: .public))")
    }

    // MARK: - Writing

    @discardableResult
    private func sendClipboardText(_ text: String) -> Bool {
        guard let textData = text.data(using: .utf8) else {
            Self.logger.warning("Failed to encode clipboard text as UTF-8 (\(text.count, privacy: .public) characters)")
            return false
        }
        let dataMessage = SpiceMessageBuilder.buildClipboardData(
            type: .utf8Text,
            data: textData,
            port: SpiceConstants.clientPort
        )
        return writeToHost(dataMessage)
    }

    @discardableResult
    private func writeToHost(_ data: Data) -> Bool {
        do {
            try deviceHandle.write(contentsOf: data)
            return true
        } catch {
            Self.logger.error("Write to SPICE device failed: \(error.localizedDescription, privacy: .public)")
            disconnect()
            return false
        }
    }

    // MARK: - Capability Helpers

    private func sendCapabilities(request: Bool) {
        let message = SpiceMessageBuilder.buildAnnounceCapabilities(
            request: request,
            port: SpiceConstants.clientPort
        )
        writeToHost(message)
        Self.logger.debug("Sent ANNOUNCE_CAPABILITIES (request: \(request, privacy: .public))")
    }
}
