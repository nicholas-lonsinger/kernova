import Foundation
import KernovaKit
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("SpiceClipboardService Tests", .caseScoped)
@MainActor
struct SpiceClipboardServiceTests {
    // MARK: - Helpers

    /// Creates a fresh service with connected pipes.
    ///
    /// The input pipe's read end
    /// is set to non-blocking so `drainPipe` returns immediately when empty.
    private func makeService() -> (service: SpiceClipboardService, inputPipe: Pipe, outputPipe: Pipe) {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let fd = inputPipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        return (SpiceClipboardService(inputPipe: inputPipe, outputPipe: outputPipe), inputPipe, outputPipe)
    }

    /// Builds a guest→host SPICE message with the given type and payload.
    private func buildGuestMessage(type: SpiceAgentMessageType, payload: Data) -> Data {
        let header = VDAgentMessageHeader(type: type, opaque: 0, dataSize: UInt32(payload.count))
        let msgData = header.serialize() + payload
        let chunk = VDIChunkHeader(port: SpiceConstants.serverPort, dataSize: UInt32(msgData.count))
        return chunk.serialize() + msgData
    }

    /// Builds a guest capabilities announce message with the given flags.
    private func buildCapabilities(clipboard: Bool, byDemand: Bool, request: Bool = false) -> Data {
        var caps: UInt32 = 0
        if clipboard { caps |= 1 << UInt32(SpiceAgentCapability.clipboard.rawValue) }
        if byDemand { caps |= 1 << UInt32(SpiceAgentCapability.clipboardByDemand.rawValue) }
        var payload = Data()
        payload.appendLittleEndian(UInt32(request ? 1 : 0))
        payload.appendLittleEndian(caps)
        return buildGuestMessage(type: .announceCapabilities, payload: payload)
    }

    /// Connects the service via a non-requesting capabilities message (no pipe writes).
    private func connect(_ service: SpiceClipboardService, byDemand: Bool = true) async {
        await service.handleIncomingData(buildCapabilities(clipboard: true, byDemand: byDemand))
    }

    /// Reads all currently buffered data from the pipe (non-blocking).
    @discardableResult
    private func drainPipe(_ pipe: Pipe) -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        let fd = pipe.fileHandleForReading.fileDescriptor
        while true {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            result.append(contentsOf: buffer[..<n])
        }
        return result
    }

    /// Extracts SPICE agent message types from concatenated wire data.
    private func messageTypes(in data: Data) -> [SpiceAgentMessageType] {
        var types: [SpiceAgentMessageType] = []
        var offset = 0
        while offset + VDIChunkHeader.size + VDAgentMessageHeader.size <= data.count {
            let chunkSlice = data.subdata(in: offset..<offset + VDIChunkHeader.size)
            guard let chunk = VDIChunkHeader.deserialize(from: chunkSlice) else { break }
            if let rawType = data.readLittleEndianUInt32(at: offset + VDIChunkHeader.size + 4),
                let type = SpiceAgentMessageType(rawValue: rawType)
            {
                types.append(type)
            }
            offset += VDIChunkHeader.size + Int(chunk.dataSize)
        }
        return types
    }

    // MARK: - Capability Handshake

    @Test("Stays disconnected when guest lacks clipboard capability")
    func rejectWithoutClipboard() async {
        let (service, _, _) = makeService()
        await service.handleIncomingData(buildCapabilities(clipboard: false, byDemand: false))
        #expect(!service.isConnected)
    }

    @Test("Sends capabilities reply when guest requests it")
    func capabilitiesReply() async {
        let (service, inputPipe, _) = makeService()
        await service.handleIncomingData(buildCapabilities(clipboard: true, byDemand: true, request: true))

        let types = messageTypes(in: drainPipe(inputPipe))
        #expect(types.contains(.announceCapabilities))
    }

    // MARK: - Failure Recovery

    @Test("Write failure disconnects the service")
    func writeFailureDisconnects() async throws {
        let (service, inputPipe, _) = makeService()
        await connect(service)
        drainPipe(inputPipe)

        try inputPipe.fileHandleForWriting.close()

        // The write never left, so the copy is owed to the next connection.
        let (copy, _) = try await macCopy("Hello")
        #expect(await service.offerHostCopy(copy) == .undelivered)

        #expect(!service.isConnected)
    }

    @Test("Pipe EOF disconnects the service")
    func pipeEOFDisconnects() async throws {
        let (service, inputPipe, outputPipe) = makeService()
        service.start()
        drainPipe(inputPipe)
        await connect(service)
        #expect(service.isConnected)

        try outputPipe.fileHandleForWriting.close()

        // `isConnected` is a stored property on the `@Observable` service, and the
        // reader loop flips it through the observed setter on EOF — so this is an
        // event-driven `waitForChange`, not a poll (matching VsockControlServiceTests).
        try await waitForChange { !service.isConnected }
        #expect(!service.isConnected)
        service.stop()
    }

    // MARK: - Inbound Message Handling

    @Test("Guest clipboard data is the guest's text, until a grab of either side's replaces it")
    func clipboardDataUpdatesState() async throws {
        let (service, inputPipe, _) = makeService()
        await connect(service)
        drainPipe(inputPipe)

        var payload = Data()
        payload.appendLittleEndian(SpiceClipboardType.utf8Text.rawValue)
        await service.handleIncomingData(
            buildGuestMessage(type: .clipboard, payload: payload + Data("From guest".utf8)))
        #expect(service.guestText == "From guest")
        #expect(service.inboundOfferSeq == 1)
        guard case .resolved(let text)? = service.guestClipboardItems().first else {
            Issue.record("the guest's text is not offered to the Mac")
            return
        }
        #expect(text.inMemoryData == Data("From guest".utf8))

        // The guest grabbing again ends the text it sent before.
        await service.handleIncomingData(buildGuestMessage(type: .clipboardGrab, payload: payload))
        #expect(service.guestText == nil)

        await service.handleIncomingData(buildGuestMessage(type: .clipboard, payload: payload + Data("Later".utf8)))
        let (copy, _) = try await macCopy("from the Mac")
        #expect(await service.offerHostCopy(copy) == .settled)
        // The Mac's grab replaces the guest's clipboard.
        #expect(service.guestText == nil)
        #expect(service.guestClipboardItems().isEmpty)
    }

    @Test("The guest releasing its clipboard ends the text it sent: Copy to Mac then has nothing to copy")
    func clipboardReleaseEndsTheGuestsText() async throws {
        let (service, inputPipe, _) = makeService()
        await connect(service)
        drainPipe(inputPipe)
        var payload = Data()
        payload.appendLittleEndian(SpiceClipboardType.utf8Text.rawValue)
        await service.handleIncomingData(
            buildGuestMessage(type: .clipboard, payload: payload + Data("From guest".utf8)))
        #expect(service.guestText == "From guest")

        await service.handleIncomingData(buildGuestMessage(type: .clipboardRelease, payload: Data()))
        #expect(service.guestText == nil)
        guard case .nothing = await service.guestClipboardCopy({ _ in }) else {
            Issue.record("the released text is still the guest's clipboard")
            return
        }
    }

    // MARK: - Another route carrying the clipboard

    @Test(
        "The guest agent taking the clipboard over releases the host's grab; SPICE then asks for no grab, answers no request and takes no data"
    )
    func notCarryingSendsNothing() async throws {
        let (service, inputPipe, _) = makeService()
        await connect(service, byDemand: true)
        let (copy, _) = try await macCopy("Hello")
        #expect(await service.offerHostCopy(copy) == .settled)
        drainPipe(inputPipe)

        service.carriesClipboard = false
        #expect(messageTypes(in: drainPipe(inputPipe)) == [.clipboardRelease])
        var text = Data()
        text.appendLittleEndian(SpiceClipboardType.utf8Text.rawValue)
        await service.handleIncomingData(buildGuestMessage(type: .clipboardGrab, payload: text))
        await service.handleIncomingData(buildGuestMessage(type: .clipboardRequest, payload: text))
        await service.handleIncomingData(buildGuestMessage(type: .clipboard, payload: text + Data("From guest".utf8)))
        let (later, _) = try await macCopy("Later")

        #expect(await service.offerHostCopy(later) == .undelivered)
        #expect(drainPipe(inputPipe).isEmpty)
        #expect(service.inboundOfferSeq == 0)
    }

    // MARK: - A copy on the Mac

    /// The Mac's copy of `text`, read from a pasteboard as passthrough reads it.
    private func macCopy(_ text: String) async throws -> (copy: ClipboardOfferSource, pasteboard: FakePasteboard) {
        let pasteboard = FakePasteboard()
        pasteboard.setText(text)
        let outcome = await ClipboardPasteboardReader.readOffer(from: pasteboard, sizeOf: nil)
        guard case .offer(let copy, _) = outcome else {
            Issue.record("expected an offer, got \(outcome)")
            throw CancellationError()
        }
        return (copy, pasteboard)
    }

    /// The guest's `CLIPBOARD_REQUEST` for UTF-8 text.
    private var textRequest: Data {
        var payload = Data()
        payload.appendLittleEndian(SpiceClipboardType.utf8Text.rawValue)
        return buildGuestMessage(type: .clipboardRequest, payload: payload)
    }

    /// The payload of each `CLIPBOARD` data message in `data`: its clipboard type and bytes.
    private func clipboardData(in data: Data) -> [(type: UInt32, bytes: Data)] {
        var replies: [(type: UInt32, bytes: Data)] = []
        var offset = 0
        while offset + VDIChunkHeader.size + VDAgentMessageHeader.size <= data.count {
            let chunkSlice = data.subdata(in: offset..<offset + VDIChunkHeader.size)
            guard let chunk = VDIChunkHeader.deserialize(from: chunkSlice) else { break }
            let message = offset + VDIChunkHeader.size
            let end = message + Int(chunk.dataSize)
            if data.readLittleEndianUInt32(at: message + 4) == SpiceAgentMessageType.clipboard.rawValue,
                let type = data.readLittleEndianUInt32(at: message + VDAgentMessageHeader.size)
            {
                replies.append((type, data.subdata(in: message + VDAgentMessageHeader.size + 4..<end)))
            }
            offset = end
        }
        return replies
    }

    @Test("A copy on the Mac is grabbed unread, its text read only when the guest requests it")
    func hostCopyIsReadOnRequest() async throws {
        let (service, inputPipe, _) = makeService()
        await connect(service, byDemand: true)
        drainPipe(inputPipe)
        let (copy, pasteboard) = try await macCopy("from the Mac")

        #expect(await service.offerHostCopy(copy) == .settled)
        #expect(messageTypes(in: drainPipe(inputPipe)) == [.clipboardGrab])
        // The copy read nothing, so a privacy prompt can come only with a paste in the guest.
        #expect(pasteboard.residentReadTypes.isEmpty)

        await service.handleIncomingData(textRequest)
        let replies = clipboardData(in: drainPipe(inputPipe))
        #expect(replies.map(\.type) == [SpiceClipboardType.utf8Text.rawValue])
        #expect(replies.map(\.bytes) == [Data("from the Mac".utf8)])
        #expect(pasteboard.residentReadTypes == [ClipboardContent.utf8TextUTI])
    }

    @Test("A request after the Mac's clipboard moved on is answered with no data")
    func requestAfterTheCopyMovedOn() async throws {
        let (service, inputPipe, _) = makeService()
        await connect(service, byDemand: true)
        let (copy, pasteboard) = try await macCopy("from the Mac")
        #expect(await service.offerHostCopy(copy) == .settled)
        drainPipe(inputPipe)

        // A newer copy, not yet polled: the grab still stands, but what it was read from is gone.
        pasteboard.setText("copied since")
        await service.handleIncomingData(textRequest)

        let replies = clipboardData(in: drainPipe(inputPipe))
        #expect(replies.map(\.type) == [SpiceClipboardType.none.rawValue])
        #expect(replies.map(\.bytes) == [Data()])
    }

    @Test("A legacy guest, which never requests, is sent the Mac's copy with its grab")
    func hostCopyToLegacyGuest() async throws {
        let (service, inputPipe, _) = makeService()
        await connect(service, byDemand: false)
        drainPipe(inputPipe)
        let (copy, _) = try await macCopy("from the Mac")

        #expect(await service.offerHostCopy(copy) == .settled)
        let wire = drainPipe(inputPipe)
        #expect(messageTypes(in: wire) == [.clipboardGrab, .clipboard])
        #expect(clipboardData(in: wire).map(\.bytes) == [Data("from the Mac".utf8)])
    }

    @Test("A copy on the Mac with no text grabs nothing")
    func hostCopyWithoutTextGrabsNothing() async throws {
        let (service, inputPipe, _) = makeService()
        await connect(service)
        drainPipe(inputPipe)
        let pasteboard = FakePasteboard()
        pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47]), forTypeIdentifier: "public.png")
        guard case .offer(let copy, _) = await ClipboardPasteboardReader.readOffer(from: pasteboard, sizeOf: nil)
        else {
            Issue.record("the image copy offers nothing")
            return
        }

        #expect(await service.offerHostCopy(copy) == .settled)
        #expect(drainPipe(inputPipe).isEmpty)
    }

    @Test("Passthrough stopping releases its grab in the guest: the guest's request after gets no data")
    func passthroughOffReleasesTheGrab() async throws {
        let (service, inputPipe, _) = makeService()
        await connect(service, byDemand: true)
        let (copy, _) = try await macCopy("from the Mac")
        #expect(await service.offerHostCopy(copy) == .settled)
        drainPipe(inputPipe)

        service.passthroughStopped()
        #expect(messageTypes(in: drainPipe(inputPipe)) == [.clipboardRelease])
        await service.handleIncomingData(textRequest)
        #expect(drainPipe(inputPipe).isEmpty)
    }

    // MARK: - The clipboard commands

    /// The Mac's clipboard as a copy command snapshots it.
    private func macSnapshot(_ pasteboard: FakePasteboard) async throws -> ClipboardOfferSource {
        guard
            case .snapshot(let snapshot, _) = await ClipboardPasteboardReader.readSnapshot(
                from: pasteboard, copyingTo: nil, sizeOf: nil)
        else {
            Issue.record("the Mac's clipboard gave no snapshot")
            throw CancellationError()
        }
        return snapshot
    }

    @Test("Passthrough stopping leaves a command's grab: it crossed by the user's command")
    func passthroughOffKeepsACommandsGrab() async throws {
        let (service, inputPipe, _) = makeService()
        await connect(service, byDemand: true)
        let pasteboard = FakePasteboard()
        pasteboard.setText("by command")
        #expect(service.copyMacClipboardToGuest(try await macSnapshot(pasteboard)) == nil)
        drainPipe(inputPipe)

        service.passthroughStopped()
        #expect(drainPipe(inputPipe).isEmpty)
        await service.handleIncomingData(textRequest)
        #expect(clipboardData(in: drainPipe(inputPipe)).map(\.bytes) == [Data("by command".utf8)])
    }

    @Test("Copy to Mac takes the text the guest's agent last sent, as data; nothing before it sends any")
    func copyToMacTakesTheGuestsText() async throws {
        let (service, _, _) = makeService()
        await connect(service)
        guard case .nothing = await service.guestClipboardCopy({ _ in }) else {
            Issue.record("a copy before the guest sent any text")
            return
        }
        var payload = Data()
        payload.appendLittleEndian(SpiceClipboardType.utf8Text.rawValue)
        await service.handleIncomingData(
            buildGuestMessage(type: .clipboard, payload: payload + Data("From guest".utf8)))

        var written: GuestCopyContents?
        guard case .landed = await service.guestClipboardCopy({ written = $0 }), let contents = written else {
            Issue.record("no copy of the guest's text")
            return
        }
        #expect(contents.items.map { $0.representations.map(\.storage) } == [[.inline]])
        #expect(contents.held(0, 0) == .bytes(Data("From guest".utf8)))
    }

    // MARK: - Lifecycle

    @Test("stop() clears connected state")
    func stopClearsState() async {
        let (service, _, _) = makeService()
        await connect(service)
        #expect(service.isConnected)

        service.stop()
        #expect(!service.isConnected)
    }
}
