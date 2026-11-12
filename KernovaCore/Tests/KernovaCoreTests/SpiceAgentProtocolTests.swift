import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore

@Suite("SpiceAgentProtocol Tests", .caseScoped)
struct SpiceAgentProtocolTests {
    // MARK: - VDI Chunk Header

    @Test("VDI chunk header uses little-endian byte order")
    func chunkHeaderLittleEndian() {
        let header = VDIChunkHeader(port: 0x0100, dataSize: 0x0200)
        let data = header.serialize()

        // Little-endian: LSB first
        #expect(data[0] == 0x00)
        #expect(data[1] == 0x01)
        #expect(data[4] == 0x00)
        #expect(data[5] == 0x02)
    }

    // MARK: - VDAgent Message Header

    @Test("VDAgent message header serializes and deserializes correctly")
    func messageHeaderRoundTrip() {
        let header = VDAgentMessageHeader(
            type: .announceCapabilities,
            opaque: 0,
            dataSize: 8
        )
        let data = header.serialize()

        #expect(data.count == VDAgentMessageHeader.size)

        let decoded = VDAgentMessageHeader.deserialize(from: data)
        #expect(decoded != nil)
        #expect(decoded?.type == .announceCapabilities)
        #expect(decoded?.opaque == 0)
        #expect(decoded?.dataSize == 8)
    }

    @Test("VDAgent message header includes protocol version 1")
    func messageHeaderProtocolVersion() {
        let header = VDAgentMessageHeader(
            type: .clipboard,
            opaque: 0,
            dataSize: 0
        )
        let data = header.serialize()

        // First 4 bytes should be protocol = 1 (little-endian)
        let protocolVersion = data.readLittleEndianUInt32(at: 0)
        #expect(protocolVersion == 1)
    }

    // MARK: - Message Builder

    @Test("Capabilities message has correct structure")
    func buildCapabilitiesMessage() throws {
        let message = SpiceMessageBuilder.buildAnnounceCapabilities(request: true)

        // Total: VDI header (8) + VDAgent header (20) + request (4) + caps (4) = 36
        #expect(message.count == 36)

        // Check chunk port = VDP_SERVER_PORT (2) — destination is the guest agent
        let port = message.readLittleEndianUInt32(at: 0)
        #expect(port == SpiceConstants.serverPort)

        // Check message type = announceCapabilities (6)
        let msgType = message.readLittleEndianUInt32(at: VDIChunkHeader.size + 4)
        #expect(msgType == SpiceAgentMessageType.announceCapabilities.rawValue)

        // Check request field = 1
        let request = message.readLittleEndianUInt32(at: VDIChunkHeader.size + VDAgentMessageHeader.size)
        #expect(request == 1)

        // Check capabilities include clipboard and clipboardByDemand bits
        let caps = try #require(message.readLittleEndianUInt32(at: VDIChunkHeader.size + VDAgentMessageHeader.size + 4))
        let clipboardBit: UInt32 = 1 << UInt32(SpiceAgentCapability.clipboard.rawValue)
        let byDemandBit: UInt32 = 1 << UInt32(SpiceAgentCapability.clipboardByDemand.rawValue)
        #expect(caps & clipboardBit != 0)
        #expect(caps & byDemandBit != 0)
    }

    @Test("Non-requesting capabilities message has request = 0")
    func buildCapabilitiesNoRequest() {
        let message = SpiceMessageBuilder.buildAnnounceCapabilities(request: false)
        let request = message.readLittleEndianUInt32(at: VDIChunkHeader.size + VDAgentMessageHeader.size)
        #expect(request == 0)
    }

    @Test("Clipboard grab message lists types correctly")
    func buildClipboardGrab() {
        let message = SpiceMessageBuilder.buildClipboardGrab(types: [.utf8Text, .png])

        // Payload: 2 × uint32 = 8 bytes
        let msgType = message.readLittleEndianUInt32(at: VDIChunkHeader.size + 4)
        #expect(msgType == SpiceAgentMessageType.clipboardGrab.rawValue)

        let type1 = message.readLittleEndianUInt32(at: VDIChunkHeader.size + VDAgentMessageHeader.size)
        let type2 = message.readLittleEndianUInt32(at: VDIChunkHeader.size + VDAgentMessageHeader.size + 4)
        #expect(type1 == SpiceClipboardType.utf8Text.rawValue)
        #expect(type2 == SpiceClipboardType.png.rawValue)
    }

    @Test("Clipboard request message has correct type field")
    func buildClipboardRequest() {
        let message = SpiceMessageBuilder.buildClipboardRequest(type: .utf8Text)

        let msgType = message.readLittleEndianUInt32(at: VDIChunkHeader.size + 4)
        #expect(msgType == SpiceAgentMessageType.clipboardRequest.rawValue)

        let clipType = message.readLittleEndianUInt32(at: VDIChunkHeader.size + VDAgentMessageHeader.size)
        #expect(clipType == SpiceClipboardType.utf8Text.rawValue)
    }

    // MARK: - Parser

    @Test("Parser handles multiple messages in a single feed")
    func parseMultipleMessages() {
        var payload1 = Data()
        payload1.appendLittleEndian(SpiceClipboardType.utf8Text.rawValue)

        var payload2 = Data()
        payload2.appendLittleEndian(SpiceClipboardType.utf8Text.rawValue)
        payload2.append("test".data(using: .utf8)!)

        let msg1 = buildGuestMessage(type: .clipboardGrab, payload: payload1)
        let msg2 = buildGuestMessage(type: .clipboard, payload: payload2)

        var parser = SpiceAgentParser()
        let results = parser.feed(msg1 + msg2)

        #expect(results.count == 2)
    }

    @Test("Parser ignores unknown message types gracefully")
    func parseUnknownMessageType() {
        let message = buildGuestMessage(type: .mouseState, payload: Data(repeating: 0, count: 16))

        var parser = SpiceAgentParser()
        let results = parser.feed(message)

        #expect(results.count == 1)
        if case .other(let type) = results[0] {
            #expect(type == .mouseState)
        } else {
            Issue.record("Expected other message type")
        }
    }

    // MARK: - Buffer Overflow and Corruption Guards

    /// Must match SpiceAgentParser.maxBufferSize / maxChunkDataSize (both 1 MB).
    private static let parserSizeLimit = 1_048_576

    @Test("Parser accepts chunk header with dataSize at exactly maxChunkDataSize")
    func chunkDataSizeAtExactLimitDoesNotReset() {
        var parser = SpiceAgentParser()

        let header = VDIChunkHeader(port: SpiceConstants.serverPort, dataSize: UInt32(Self.parserSizeLimit))
        // Don't supply the full payload — parser will wait for more data, not reset
        let results = parser.feed(header.serialize())

        #expect(results.isEmpty)
        #expect(parser.didReset == false)
    }

    @Test("Parser resets buffer when chunk header claims unreasonable dataSize")
    func corruptChunkHeaderTriggersReset() {
        var parser = SpiceAgentParser()

        let corruptHeader = VDIChunkHeader(port: SpiceConstants.serverPort, dataSize: UInt32(Self.parserSizeLimit + 1))
        var data = corruptHeader.serialize()
        // Extra bytes so the parser can read the full chunk header
        data.append(Data(repeating: 0, count: 8))

        let results = parser.feed(data)

        #expect(results.isEmpty)
        #expect(parser.didReset == true)
    }

    @Test("Parser recovers and parses correctly after a reset")
    func parserRecoveryAfterReset() {
        var parser = SpiceAgentParser()

        // Trigger a reset via buffer overflow
        _ = parser.feed(Data(repeating: 0xFF, count: Self.parserSizeLimit + 1))
        #expect(parser.didReset == true)

        // Parser should recover on next valid feed
        var payload = Data()
        payload.appendLittleEndian(SpiceClipboardType.utf8Text.rawValue)
        let validMessage = buildGuestMessage(type: .clipboardGrab, payload: payload)
        let results = parser.feed(validMessage)

        #expect(parser.didReset == false)
        #expect(results.count == 1)
        if case .clipboardGrab(let types) = results[0] {
            #expect(types == [.utf8Text])
        } else {
            Issue.record("Expected clipboardGrab message after recovery")
        }
    }

    @Test(
        "Parser returns malformedChunk for invalid payloads",
        arguments: [
            Data(repeating: 0, count: 4),  // truncated: needs 20 bytes, only 4
            Data(),  // empty payload
        ])
    func malformedPayloadReturnsMalformed(payload: Data) {
        var parser = SpiceAgentParser()

        let chunk = VDIChunkHeader(
            port: SpiceConstants.serverPort,
            dataSize: UInt32(payload.count)
        )
        let message = chunk.serialize() + payload

        let results = parser.feed(message)

        #expect(results.count == 1)
        if case .malformedChunk = results[0] {
            // pass
        } else {
            Issue.record("Expected malformedChunk")
        }
    }

    // MARK: - Data Extension Helpers

    @Test("Little-endian UInt64 read/write round-trips")
    func uint64RoundTrip() {
        var data = Data()
        data.appendLittleEndian(UInt64(0x0102030405060708))
        #expect(data.readLittleEndianUInt64(at: 0) == 0x0102030405060708)
    }

    // MARK: - Server Port

    // MARK: - Capability Checking

    @Test("hasCapability detects set capability bits")
    func hasCapabilityDetectsSetBits() {
        // clipboard = bit 3, clipboardByDemand = bit 5
        let caps: [UInt32] = [(1 << 3) | (1 << 5)]
        #expect(SpiceMessageBuilder.hasCapability(caps, .clipboard))
        #expect(SpiceMessageBuilder.hasCapability(caps, .clipboardByDemand))
    }

    @Test("hasCapability returns false for unset bits")
    func hasCapabilityReturnsFalseForUnsetBits() {
        let caps: [UInt32] = [(1 << 3)]  // only clipboard set
        #expect(!SpiceMessageBuilder.hasCapability(caps, .clipboardByDemand))
        #expect(!SpiceMessageBuilder.hasCapability(caps, .monitorsConfig))
    }

    @Test("hasCapability returns false for empty caps array")
    func hasCapabilityEmptyCaps() {
        #expect(!SpiceMessageBuilder.hasCapability([], .clipboard))
    }

    // MARK: - Test Helpers

    /// Builds a fake guest→host message with the given type and payload.
    private func buildGuestMessage(type: SpiceAgentMessageType, payload: Data) -> Data {
        let header = VDAgentMessageHeader(
            type: type,
            opaque: 0,
            dataSize: UInt32(payload.count)
        )
        let msgData = header.serialize() + payload
        let chunk = VDIChunkHeader(
            port: SpiceConstants.serverPort,
            dataSize: UInt32(msgData.count)
        )
        return chunk.serialize() + msgData
    }
}
