import Testing
import Foundation
@testable import Kernova

@Suite("SpiceAgentProtocol Tests")
struct SpiceAgentProtocolTests {

    // MARK: - VDI Chunk Header

    @Test("VDI chunk header serializes and deserializes correctly")
    func chunkHeaderRoundTrip() {
        let header = VDIChunkHeader(port: 1, dataSize: 42)
        let data = header.serialize()

        #expect(data.count == VDIChunkHeader.size)

        let decoded = VDIChunkHeader.deserialize(from: data)
        #expect(decoded != nil)
        #expect(decoded?.port == 1)
        #expect(decoded?.dataSize == 42)
    }

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

    @Test("VDI chunk header deserialization fails with insufficient data")
    func chunkHeaderTooShort() {
        let data = Data([0x01, 0x00, 0x00])
        #expect(VDIChunkHeader.deserialize(from: data) == nil)
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
        let protocol_ = data.readLittleEndianUInt32(at: 0)
        #expect(protocol_ == 1)
    }

    @Test("VDAgent message header deserialization fails for unknown type")
    func messageHeaderUnknownType() {
        var data = Data(repeating: 0, count: VDAgentMessageHeader.size)
        // Set type field (offset 4) to an unknown value
        var unknownType: UInt32 = 99
        Swift.withUnsafeBytes(of: &unknownType) { ptr in
            data.replaceSubrange(4..<8, with: ptr)
        }
        #expect(VDAgentMessageHeader.deserialize(from: data) == nil)
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

    @Test("Clipboard data message includes type and payload")
    func buildClipboardData() {
        let text = "Hello, guest!"
        let textData = text.data(using: .utf8)!
        let message = SpiceMessageBuilder.buildClipboardData(type: .utf8Text, data: textData)

        let msgType = message.readLittleEndianUInt32(at: VDIChunkHeader.size + 4)
        #expect(msgType == SpiceAgentMessageType.clipboard.rawValue)

        let clipType = message.readLittleEndianUInt32(at: VDIChunkHeader.size + VDAgentMessageHeader.size)
        #expect(clipType == SpiceClipboardType.utf8Text.rawValue)

        let payloadStart = VDIChunkHeader.size + VDAgentMessageHeader.size + 4
        let payload = message.subdata(in: payloadStart..<message.count)
        #expect(String(data: payload, encoding: .utf8) == text)
    }

    @Test("Clipboard release message has empty payload")
    func buildClipboardRelease() {
        let message = SpiceMessageBuilder.buildClipboardRelease()

        let dataSize = message.readLittleEndianUInt32(at: VDIChunkHeader.size + 16)
        #expect(dataSize == 0)
    }

    // MARK: - Parser

    @Test("Parser handles announce capabilities from guest")
    func parseAnnounceCapabilities() {
        // Build a guest→host capabilities message (port = serverPort)
        var caps: UInt32 = 0
        caps |= 1 << UInt32(SpiceAgentCapability.clipboard.rawValue)
        caps |= 1 << UInt32(SpiceAgentCapability.clipboardByDemand.rawValue)

        let message = buildGuestMessage(type: .announceCapabilities, payload: {
            var data = Data()
            data.appendLittleEndian(UInt32(1)) // request = true
            data.appendLittleEndian(caps)
            return data
        }())

        var parser = SpiceAgentParser()
        let results = parser.feed(message)

        #expect(results.count == 1)
        if case .announceCapabilities(let request, let parsedCaps) = results[0] {
            #expect(request == true)
            #expect(parsedCaps.count == 1)
            #expect(parsedCaps[0] & (1 << UInt32(SpiceAgentCapability.clipboard.rawValue)) != 0)
        } else {
            Issue.record("Expected announceCapabilities message")
        }
    }

    @Test("Parser handles clipboard grab from guest")
    func parseClipboardGrab() {
        var payload = Data()
        payload.appendLittleEndian(SpiceClipboardType.utf8Text.rawValue)

        let message = buildGuestMessage(type: .clipboardGrab, payload: payload)

        var parser = SpiceAgentParser()
        let results = parser.feed(message)

        #expect(results.count == 1)
        if case .clipboardGrab(let types) = results[0] {
            #expect(types == [.utf8Text])
        } else {
            Issue.record("Expected clipboardGrab message")
        }
    }

    @Test("Parser handles clipboard data from guest")
    func parseClipboardData() {
        let text = "Guest clipboard content"
        let textData = text.data(using: .utf8)!

        var payload = Data()
        payload.appendLittleEndian(SpiceClipboardType.utf8Text.rawValue)
        payload.append(textData)

        let message = buildGuestMessage(type: .clipboard, payload: payload)

        var parser = SpiceAgentParser()
        let results = parser.feed(message)

        #expect(results.count == 1)
        if case .clipboardData(let type, let data) = results[0] {
            #expect(type == .utf8Text)
            #expect(String(data: data, encoding: .utf8) == text)
        } else {
            Issue.record("Expected clipboardData message")
        }
    }

    @Test("Parser handles clipboard request from guest")
    func parseClipboardRequest() {
        var payload = Data()
        payload.appendLittleEndian(SpiceClipboardType.utf8Text.rawValue)

        let message = buildGuestMessage(type: .clipboardRequest, payload: payload)

        var parser = SpiceAgentParser()
        let results = parser.feed(message)

        #expect(results.count == 1)
        if case .clipboardRequest(let type) = results[0] {
            #expect(type == .utf8Text)
        } else {
            Issue.record("Expected clipboardRequest message")
        }
    }

    @Test("Parser handles clipboard release from guest")
    func parseClipboardRelease() {
        let message = buildGuestMessage(type: .clipboardRelease, payload: Data())

        var parser = SpiceAgentParser()
        let results = parser.feed(message)

        #expect(results.count == 1)
        if case .clipboardRelease = results[0] {
            // pass
        } else {
            Issue.record("Expected clipboardRelease message")
        }
    }

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

    @Test("Parser handles partial data across multiple feeds")
    func parsePartialData() {
        var payload = Data()
        payload.appendLittleEndian(SpiceClipboardType.utf8Text.rawValue)
        let message = buildGuestMessage(type: .clipboardGrab, payload: payload)

        let splitPoint = message.count / 2

        var parser = SpiceAgentParser()
        let results1 = parser.feed(message.subdata(in: 0..<splitPoint))
        #expect(results1.isEmpty)

        let results2 = parser.feed(message.subdata(in: splitPoint..<message.count))
        #expect(results2.count == 1)
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

    @Test("Parser resets buffer when it exceeds maxBufferSize")
    func bufferOverflowTriggersReset() {
        var parser = SpiceAgentParser()
        let oversized = Data(repeating: 0xFF, count: Self.parserSizeLimit + 1)
        let results = parser.feed(oversized)

        #expect(results.isEmpty)
        #expect(parser.didReset == true)
    }

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

    @Test("Parser returns malformedChunk for invalid payloads",
          arguments: [
              Data(repeating: 0, count: 4),  // truncated: needs 20 bytes, only 4
              Data(),                          // empty payload
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

    @Test("Little-endian UInt32 read/write round-trips")
    func uint32RoundTrip() {
        var data = Data()
        data.appendLittleEndian(UInt32(0xDEADBEEF))
        #expect(data.readLittleEndianUInt32(at: 0) == 0xDEADBEEF)
    }

    @Test("Little-endian UInt64 read/write round-trips")
    func uint64RoundTrip() {
        var data = Data()
        data.appendLittleEndian(UInt64(0x0102030405060708))
        #expect(data.readLittleEndianUInt64(at: 0) == 0x0102030405060708)
    }

    // MARK: - Server Port

    @Test("All builders stamp serverPort in the chunk header")
    func buildersUseServerPort() {
        let capabilities = SpiceMessageBuilder.buildAnnounceCapabilities(request: false)
        #expect(capabilities.readLittleEndianUInt32(at: 0) == SpiceConstants.serverPort)

        let grab = SpiceMessageBuilder.buildClipboardGrab(types: [.utf8Text])
        #expect(grab.readLittleEndianUInt32(at: 0) == SpiceConstants.serverPort)

        let request = SpiceMessageBuilder.buildClipboardRequest(type: .utf8Text)
        #expect(request.readLittleEndianUInt32(at: 0) == SpiceConstants.serverPort)

        let data = SpiceMessageBuilder.buildClipboardData(type: .utf8Text, data: Data([0x41]))
        #expect(data.readLittleEndianUInt32(at: 0) == SpiceConstants.serverPort)

        let release = SpiceMessageBuilder.buildClipboardRelease()
        #expect(release.readLittleEndianUInt32(at: 0) == SpiceConstants.serverPort)
    }

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

    @Test("hasCapability returns false when word index exceeds array length")
    func hasCapabilityOutOfBounds() {
        // clipboardNoReleaseOnRegrab = bit 16 (word 0, bit 16) — fits in single word
        // But if we pass an empty array, wordIndex 0 exceeds bounds
        #expect(!SpiceMessageBuilder.hasCapability([], .clipboardNoReleaseOnRegrab))
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
