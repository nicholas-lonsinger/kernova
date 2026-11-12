#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire
import Testing

@Suite("Preamble and frame encoding")
struct PreambleAndEncoderTests {
    @Test("The preamble is ASCII KRN2, and the layout constants are the spec's")
    func constants() {
        #expect(WireConstants.preamble == Data("KRN2".utf8))
        #expect(WireConstants.headerByteCount == 10)
        #expect(WireConstants.maxRawDataPayload == 1 << 20)
        #expect(WireConstants.maxControlPayload == 1 << 16)
        #expect(WireConstants.windowPayloadByteCount == 4)
        #expect(WireConstants.pingPayloadByteCount == 8)
        #expect(WireConstants.maxWindow == UInt32(Int32.max))
        #expect(WireConstants.maxPingIntervalNanoseconds == 5_000_000_000)
        #expect(WireConstants.vsockPort == 0xC008)
    }

    static let wrongPreambles: [Data] = [
        Data("KRN1".utf8), Data("XRN2".utf8), Data("KXN2".utf8), Data("KRX2".utf8), Data("krn2".utf8),
        Data([0x00, 0x00, 0x00, 0x2A]),  // a generation-1 length prefix
        Data([0, 0, 0, 0]),
    ]

    @Test("Any other first 4 bytes are a bad preamble, at any split", arguments: wrongPreambles)
    func wrongPreamble(_ preamble: Data) {
        let bytes = preamble + rawHeader(type: 0x05, length: 8) + Data(count: 8)
        for offset in 0...bytes.count {
            #expect(throws: FrameError.badPreamble) { try decodeAll(bytes.split(at: [offset])) }
        }
    }

    @Test("The header is big-endian stream id, type, flags, length, and the payload is passed through")
    func headerLayout() throws {
        let payload = Data([9, 8, 7])
        let parts = FrameEncoder.encode(
            Frame(streamID: StreamID(rawValue: 0x0102_0304), type: .data, flags: .message, payload: payload))
        #expect(parts.count == 2)
        #expect(parts.first == Data([0x01, 0x02, 0x03, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x03]))
        #expect(parts.last == payload)
        let empty = FrameEncoder.encode(Frame(streamID: .session, type: .end))
        #expect(empty == [Data([0, 0, 0, 0, 0x02, 0, 0, 0, 0, 0]), Data()])
    }

    @Test("Frame types carry the spec's numbers, and stream ids order by value")
    func vocabulary() {
        #expect(
            [FrameType.data, .open, .end, .reset, .window, .ping].map(\.rawValue) == [0, 1, 2, 3, 4, 5])
        #expect(FrameFlags.message.rawValue == 0x01)
        #expect(StreamID.session.rawValue == 0)
        #expect(StreamID(rawValue: 2) < StreamID(rawValue: 3))
    }
}
