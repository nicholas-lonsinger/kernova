import Foundation
import KernovaKit
import KernovaLogging
import KernovaWire

/// Manages SPICE clipboard sharing between the host and a single guest VM.
///
/// Speaks the SPICE agent protocol directly over raw pipe I/O rather than using
/// `VZSpiceAgentPortAttachment`, which would sync the guest clipboard straight
/// into the host `NSPasteboard`; the guest's text is held here for passthrough
/// to write instead. This side is the SPICE **client** (host); the guest runs a
/// standard agent (`spice-vdagent` on Linux).
@MainActor
@Observable
final class SpiceClipboardService: ClipboardServicing {
    // MARK: - Observable State

    /// The guest's clipboard text as its agent last sent it; nil until it sends one, and once the guest's
    /// clipboard holds no text or the host grabs it.
    private(set) var guestText: String?

    /// `true` once the guest agent has completed the capabilities handshake.
    private(set) var isConnected: Bool = false

    var supportsBinaryRepresentations: Bool { false }

    /// Bumped once per inbound guest clipboard text.
    private(set) var inboundOfferSeq: UInt64 = 0

    /// Whether this service carries the VM's clipboard, as `ClipboardRoute`
    /// chooses: false while the guest agent's hub carries it, when the guest's
    /// grabs are not asked for and nothing the host grabbed is sent. Turning it
    /// off forgets the host's grab.
    var carriesClipboard = true {
        didSet {
            guard !carriesClipboard else { return }
            outbound = nil
        }
    }

    // MARK: - Private

    private let inputPipe: Pipe  // host writes → guest reads
    private let outputPipe: Pipe  // guest writes → host reads
    private var parser = SpiceAgentParser()

    /// What the host last grabbed, which the guest's `CLIPBOARD_REQUEST` is answered from.
    private var outbound: Outbound?

    /// The source of the host's grab.
    private enum Outbound {
        /// A copy on the Mac passthrough offered, its text read only when the guest requests it.
        case copy(ClipboardOfferSource)
    }

    /// Whether the guest advertised `VD_AGENT_CAP_CLIPBOARD_BY_DEMAND`.
    ///
    /// When `false` (legacy mode), clipboard data is sent immediately after GRAB
    /// instead of waiting for a REQUEST.
    private var guestSupportsByDemand = false

    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "SpiceClipboardService")

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
        Self.logger.log(.info, "SPICE clipboard service started")
    }

    /// Stops reading, marks the connection inactive, and releases resources.
    func stop() {
        disconnect()
        outputPipe.fileHandleForReading.readabilityHandler = nil
        outbound = nil
        guestSupportsByDemand = false
        Self.logger.log(.info, "SPICE clipboard service stopped")
    }

    // MARK: - ClipboardServicing

    /// The guest's text, as the one representation it is.
    func guestClipboardItems() -> [CopyToMacItem] {
        guard let guestText else { return [] }
        return ClipboardContent(text: guestText).representations.map { .resolved($0) }
    }

    /// Grabs the guest's clipboard for `snapshot`'s text, the one thing this transport carries; the guest's
    /// agent asks for it at paste, and it is answered from the snapshot, which nothing on the Mac changes.
    func copyMacClipboardToGuest(_ snapshot: ClipboardOfferSource) -> ClipboardTransferFailure? {
        guard snapshot.offersUTF8Text else { return .noTextToCopy }
        guard isConnected, carriesClipboard,
            writeToGuest(SpiceMessageBuilder.buildClipboardGrab(types: [.utf8Text]))
        else { return .transferFailed }
        outbound = .copy(snapshot)
        guestText = nil
        if !guestSupportsByDemand {
            Task { [weak self] in await self?.reply(from: .copy(snapshot)) }
        }
        Self.logger.log(.notice, "Grabbed the guest's clipboard for the Mac's copy")
        return nil
    }

    /// The text the guest's agent sent at its last grab: the guest's clipboard as it stands, since each change
    /// of it grabs anew.
    func guestClipboardCopy() async -> GuestClipboardCopy {
        guard let guestText else { return .nothing }
        var text = Representation()
        text.type = TypeDescriptor(appleUTI: ClipboardContent.utf8TextUTI)
        text.storage = .inline
        text.sizeEstimate = UInt64(guestText.utf8.count)
        var item = OfferedItem()
        item.representations = [text]
        let bytes = Data(guestText.utf8)
        var generator = SystemRandomNumberGenerator()
        return .copy(
            GuestCopyContents(
                token: Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }), items: [item],
                concealed: false, plan: .whole, landed: { _, _ in bytes }, puller: NoFilesPuller(), release: {}))
    }

    /// Grabs the copy's UTF-8 text, the one representation this transport carries, reading it only when the
    /// guest requests it; a legacy guest, which never requests, is sent it now. A copy with no text has nothing
    /// to send.
    func offerHostCopy(_ copy: ClipboardOfferSource) async -> ClipboardGrabOutcome {
        guard copy.offersUTF8Text else { return .settled }
        guard isConnected, carriesClipboard else { return .undelivered }
        guard writeToGuest(SpiceMessageBuilder.buildClipboardGrab(types: [.utf8Text])) else { return .undelivered }
        outbound = .copy(copy)
        guestText = nil
        if !guestSupportsByDemand {
            guard await reply(from: .copy(copy)) else { return .undelivered }
        }
        Self.logger.log(
            .notice, "Grabbed the Mac's copy (byDemand: \(self.guestSupportsByDemand, privacy: .public))")
        return .settled
    }

    // MARK: - Reading

    /// Hooks the readability handler on the output pipe to receive guest messages.
    private func startReading() {
        // Captured for the closure, which runs on a background GCD queue.
        let logger = Self.logger

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF — pipe closed. Nil-out immediately to prevent GCD spin loop.
                handle.readabilityHandler = nil
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.disconnect()
                    Self.logger.log(.notice, "SPICE pipe closed (EOF)")
                }
                return
            }

            logger.log(.debug, "Received \(data.count, privacy: .public) bytes from guest SPICE agent")

            Task { @MainActor [weak self] in
                await self?.handleIncomingData(data)
            }
        }
    }

    func handleIncomingData(_ data: Data) async {
        let messages = parser.feed(data)

        if parser.didReset {
            Self.logger.log(.error, "SPICE parser buffer reset — stream may be corrupted")
        }

        for message in messages {
            switch message {
            case .announceCapabilities(let request, let caps):
                handleCapabilities(request: request, caps: caps)

            case .clipboardGrab(let types):
                handleClipboardGrab(types: types)

            case .clipboardRequest(let type):
                await handleClipboardRequest(type: type)

            case .clipboardData(let type, let data):
                handleClipboardData(type: type, data: data)

            case .clipboardRelease:
                handleClipboardRelease()

            case .other(let type):
                Self.logger.log(.debug, "Ignoring unhandled SPICE message type: \(type.rawValue, privacy: .public)")

            case .malformedChunk:
                Self.logger.log(.warning, "Skipping malformed SPICE chunk")
            }
        }
    }

    // MARK: - Message Handlers

    // Either capability bit counts as clipboard support: a guest advertising only
    // `VD_AGENT_CAP_CLIPBOARD_BY_DEMAND` (bit 5) and not the always-sync
    // `VD_AGENT_CAP_CLIPBOARD` (bit 3) must still connect.
    private func handleCapabilities(request: Bool, caps: [UInt32]) {
        let hasClipboard = SpiceMessageBuilder.hasCapability(caps, .clipboard)
        let byDemand = SpiceMessageBuilder.hasCapability(caps, .clipboardByDemand)

        guard hasClipboard || byDemand else {
            Self.logger.log(
                .warning,
                "Guest agent does not support clipboard (caps: \(caps.map { String($0, radix: 16) }, privacy: .public))"
            )
            return
        }

        isConnected = true
        guestSupportsByDemand = byDemand

        if request {
            let reply = SpiceMessageBuilder.buildAnnounceCapabilities(request: false)
            guard writeToGuest(reply) else { return }
        }

        Self.logger.log(
            .notice,
            "Guest agent connected (caps: \(caps.map { String($0, radix: 16) }, privacy: .public), byDemand: \(byDemand, privacy: .public))"
        )
    }

    /// The guest's clipboard let go of what it grabbed: the text it sent is its clipboard no more.
    private func handleClipboardRelease() {
        Self.logger.log(.debug, "Guest released clipboard")
        guard carriesClipboard else { return }
        guestText = nil
    }

    /// Guest announced it has new clipboard data — request it. The guest's grab ends the host's.
    private func handleClipboardGrab(types: [SpiceClipboardType]) {
        Self.logger.log(.debug, "Guest clipboard grab: types=\(types.map(\.rawValue), privacy: .public)")

        guard carriesClipboard else {
            Self.logger.log(.debug, "Guest clipboard grab ignored: the guest agent carries the clipboard")
            return
        }
        outbound = nil
        guestText = nil
        guard types.contains(.utf8Text) else {
            Self.logger.log(.debug, "Guest clipboard has no UTF-8 text type, ignoring")
            return
        }

        let request = SpiceMessageBuilder.buildClipboardRequest(type: .utf8Text)
        guard writeToGuest(request) else { return }
    }

    /// Guest is requesting clipboard data from us (response to our GRAB).
    private func handleClipboardRequest(type: SpiceClipboardType) async {
        Self.logger.log(.debug, "Guest requested clipboard data (type: \(type.rawValue, privacy: .public))")

        guard type == .utf8Text else {
            Self.logger.log(.debug, "Guest requested non-text type, ignoring")
            return
        }

        guard carriesClipboard, let outbound else {
            Self.logger.log(.debug, "No pending outbound text for clipboard request")
            return
        }

        // Keep outbound intact — the guest agent may retry the request
        await reply(from: outbound)
    }

    /// Sends the guest `outbound`'s text, or — a copy whose clipboard has moved on — `VD_AGENT_CLIPBOARD_NONE`,
    /// SPICE's answer that no data is available.
    @discardableResult
    private func reply(from outbound: Outbound) async -> Bool {
        switch outbound {
        case .copy(let copy):
            if let text = await copy.utf8Text() { return sendClipboardText(text) }
            Self.logger.log(.notice, "The Mac's copy moved on before the guest requested it")
            return writeToGuest(SpiceMessageBuilder.buildClipboardData(type: .none, data: Data()))
        }
    }

    /// Guest delivered clipboard data: the guest's clipboard text now.
    private func handleClipboardData(type: SpiceClipboardType, data: Data) {
        guard carriesClipboard else { return }
        guard type == .utf8Text else {
            Self.logger.log(
                .debug,
                "Received non-text clipboard data (type: \(type.rawValue, privacy: .public)), ignoring")
            return
        }

        guard let text = String(data: data, encoding: .utf8) else {
            Self.logger.log(
                .warning,
                "Failed to decode guest clipboard data as UTF-8 (\(data.count, privacy: .public) bytes)")
            return
        }

        guestText = text
        inboundOfferSeq &+= 1
        Self.logger.log(.debug, "Received guest clipboard text (\(text.count, privacy: .public) characters)")
    }

    // MARK: - Writing

    /// Encodes text as UTF-8 and sends a `CLIPBOARD` data message to the guest.
    @discardableResult
    private func sendClipboardText(_ text: String) -> Bool {
        guard let textData = text.data(using: .utf8) else {
            Self.logger.log(
                .warning,
                "Failed to encode clipboard text as UTF-8 (\(text.count, privacy: .public) characters)")
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
            Self.logger.log(.error, "Failed to write to SPICE pipe: \(error.localizedDescription, privacy: .public)")
            disconnect()
            return false
        }
    }

    /// Marks the connection as inactive.
    private func disconnect() {
        isConnected = false
    }

    // MARK: - Capability Helpers

    private func sendCapabilities() {
        let message = SpiceMessageBuilder.buildAnnounceCapabilities(request: true)
        _ = writeToGuest(message)
        Self.logger.log(.debug, "Sent ANNOUNCE_CAPABILITIES (requesting guest reply)")
    }
}

/// The puller of a copy with no files, which nothing asks.
private struct NoFilesPuller: ClipboardItemPulling {
    func pullBytes(item: Int, representation: Int, completion: @escaping @Sendable (Data?) -> Void) {
        completion(nil)
    }

    func pullFile(item: Int, representation: Int, completion: @escaping @Sendable (URL?) -> Void) {
        completion(nil)
    }
}

extension ClipboardOfferSource {
    /// Whether the offer has an INLINE UTF-8 text representation, from its metadata alone.
    var offersUTF8Text: Bool { utf8TextIndex != nil }

    /// The first INLINE UTF-8 text representation's text, read now; nil when the offer has none or it can no
    /// longer be served.
    func utf8Text() async -> String? {
        guard let (item, index) = utf8TextIndex,
            case .bytes(let data)? = try? await serve(item: item, representation: index)
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private var utf8TextIndex: (item: Int, representation: Int)? {
        for (item, offered) in items.enumerated() {
            if let index = offered.representations.firstIndex(where: {
                $0.storage == .inline && $0.type.appleUTI == ClipboardContent.utf8TextUTI
            }) {
                return (item, index)
            }
        }
        return nil
    }
}
