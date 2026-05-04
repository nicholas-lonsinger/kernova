import Testing
import Foundation
@testable import Kernova

@Suite("SpiceClipboardService Tests")
@MainActor
struct SpiceClipboardServiceTests {

    // MARK: - Helpers

    /// Creates a fresh service with connected pipes. The input pipe's read end
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
    private func connect(_ service: SpiceClipboardService, byDemand: Bool = true) {
        service.handleIncomingData(buildCapabilities(clipboard: true, byDemand: byDemand))
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
               let type = SpiceAgentMessageType(rawValue: rawType) {
                types.append(type)
            }
            offset += VDIChunkHeader.size + Int(chunk.dataSize)
        }
        return types
    }

    // MARK: - Capability Handshake

    @Test("Connects when guest advertises clipboard-by-demand")
    func connectWithByDemand() {
        let (service, _, _) = makeService()
        connect(service, byDemand: true)
        #expect(service.isConnected)
    }

    @Test("Connects when guest advertises only legacy clipboard capability")
    func connectLegacy() {
        let (service, _, _) = makeService()
        connect(service, byDemand: false)
        #expect(service.isConnected)
    }

    @Test("Stays disconnected when guest lacks clipboard capability")
    func rejectWithoutClipboard() {
        let (service, _, _) = makeService()
        service.handleIncomingData(buildCapabilities(clipboard: false, byDemand: false))
        #expect(!service.isConnected)
    }

    @Test("agentStatus is .waiting before the capabilities handshake")
    func agentStatusBeforeHandshake() {
        let (service, _, _) = makeService()
        #expect(service.agentStatus == .waiting)
    }

    @Test("agentStatus is .current after the handshake")
    func agentStatusAfterHandshake() {
        let (service, _, _) = makeService()
        connect(service, byDemand: true)
        // Linux guests install spice-vdagent themselves, so the host has
        // nothing to install/update — .current suppresses install affordances.
        #expect(service.agentStatus == .current(version: "spice-vdagent"))
    }

    @Test("Sends capabilities reply when guest requests it")
    func capabilitiesReply() {
        let (service, inputPipe, _) = makeService()
        service.handleIncomingData(buildCapabilities(clipboard: true, byDemand: true, request: true))

        let types = messageTypes(in: drainPipe(inputPipe))
        #expect(types.contains(.announceCapabilities))
    }

    // MARK: - grabIfChanged Guards

    @Test("grabIfChanged does nothing when disconnected")
    func grabWhileDisconnected() {
        let (service, inputPipe, _) = makeService()
        service.clipboardText = "Hello"
        service.grabIfChanged()
        #expect(drainPipe(inputPipe).isEmpty)
    }

    @Test("grabIfChanged does nothing when clipboard text is empty")
    func grabWithEmptyText() {
        let (service, inputPipe, _) = makeService()
        connect(service)
        drainPipe(inputPipe)

        service.grabIfChanged()
        #expect(drainPipe(inputPipe).isEmpty)
    }

    @Test("grabIfChanged skips duplicate grab for unchanged text")
    func grabDeduplication() {
        let (service, inputPipe, _) = makeService()
        connect(service)

        service.clipboardText = "Hello"
        service.grabIfChanged()
        drainPipe(inputPipe)

        service.grabIfChanged()
        #expect(drainPipe(inputPipe).isEmpty)
    }

    // MARK: - grabIfChanged Modes

    @Test("By-demand grab sends only CLIPBOARD_GRAB")
    func grabByDemandMode() {
        let (service, inputPipe, _) = makeService()
        connect(service, byDemand: true)
        drainPipe(inputPipe)

        service.clipboardText = "Hello"
        service.grabIfChanged()

        let types = messageTypes(in: drainPipe(inputPipe))
        #expect(types == [.clipboardGrab])
    }

    @Test("Legacy grab sends CLIPBOARD_GRAB followed by CLIPBOARD data")
    func grabLegacyMode() {
        let (service, inputPipe, _) = makeService()
        connect(service, byDemand: false)
        drainPipe(inputPipe)

        service.clipboardText = "Hello"
        service.grabIfChanged()

        let types = messageTypes(in: drainPipe(inputPipe))
        #expect(types == [.clipboardGrab, .clipboard])
    }

    // MARK: - Failure Recovery

    @Test("Write failure disconnects the service")
    func writeFailureDisconnects() throws {
        let (service, inputPipe, _) = makeService()
        connect(service)
        drainPipe(inputPipe)

        try inputPipe.fileHandleForWriting.close()

        service.clipboardText = "Hello"
        service.grabIfChanged()

        #expect(!service.isConnected)
    }

    @Test("Pipe EOF disconnects the service")
    func pipeEOFDisconnects() async throws {
        let (service, inputPipe, outputPipe) = makeService()
        service.start()
        drainPipe(inputPipe)
        connect(service)
        #expect(service.isConnected)

        try outputPipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(5.0)
        while service.isConnected && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(!service.isConnected)
        service.stop()
    }

    // MARK: - Inbound Message Handling

    @Test("Guest clipboard data updates text and resets grab tracking")
    func clipboardDataUpdatesState() {
        let (service, inputPipe, _) = makeService()
        connect(service)
        drainPipe(inputPipe)

        // Grab "Hello" — sets lastGrabbedText
        service.clipboardText = "Hello"
        service.grabIfChanged()
        drainPipe(inputPipe)

        // Guest sends its own data → resets lastGrabbedText
        var payload = Data()
        payload.appendLittleEndian(SpiceClipboardType.utf8Text.rawValue)
        payload.append(Data("From guest".utf8))
        service.handleIncomingData(buildGuestMessage(type: .clipboard, payload: payload))

        #expect(service.clipboardText == "From guest")

        // Re-grabbing "Hello" should succeed because lastGrabbedText was reset
        service.clipboardText = "Hello"
        service.grabIfChanged()
        let types = messageTypes(in: drainPipe(inputPipe))
        #expect(types.contains(.clipboardGrab))
    }

    @Test("Guest clipboard request sends pending outbound text")
    func clipboardRequestWithPending() {
        let (service, inputPipe, _) = makeService()
        connect(service, byDemand: true)
        drainPipe(inputPipe)

        // Grab sets pendingOutboundText
        service.clipboardText = "Hello"
        service.grabIfChanged()
        drainPipe(inputPipe)

        // Guest requests the data
        var requestPayload = Data()
        requestPayload.appendLittleEndian(SpiceClipboardType.utf8Text.rawValue)
        service.handleIncomingData(buildGuestMessage(type: .clipboardRequest, payload: requestPayload))

        let types = messageTypes(in: drainPipe(inputPipe))
        #expect(types == [.clipboard])
    }

    @Test("Guest clipboard request with no pending text sends nothing")
    func clipboardRequestWithoutPending() {
        let (service, inputPipe, _) = makeService()
        connect(service, byDemand: true)
        drainPipe(inputPipe)

        var requestPayload = Data()
        requestPayload.appendLittleEndian(SpiceClipboardType.utf8Text.rawValue)
        service.handleIncomingData(buildGuestMessage(type: .clipboardRequest, payload: requestPayload))

        #expect(drainPipe(inputPipe).isEmpty)
    }

    // MARK: - Lifecycle

    @Test("stop() clears connected state")
    func stopClearsState() {
        let (service, _, _) = makeService()
        connect(service)
        #expect(service.isConnected)

        service.stop()
        #expect(!service.isConnected)
    }
}
