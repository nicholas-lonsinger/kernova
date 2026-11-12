#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaPortableTestSupport
import KernovaWire
import Testing

@Suite("FrameDecoder splits and payload storage")
struct FrameDecoderSplitTests {
    /// One frame of every type, MESSAGE and raw DATA both, and empty payloads.
    static let smallFrames: [Frame] = [
        Frame(streamID: .session, type: .data, flags: .message, payload: Data([0x0A, 0x02, 0x08, 0x01])),
        Frame(streamID: StreamID(rawValue: 2), type: .open, payload: Data([0x08, 0x64])),
        Frame(streamID: StreamID(rawValue: 2), type: .data, payload: Data([1, 2, 3, 4, 5])),
        Frame(streamID: StreamID(rawValue: 2), type: .end),
        Frame(streamID: StreamID(rawValue: 0xFFFF_FFFF), type: .reset, payload: Data([0x08, 0x32])),
        Frame(streamID: .session, type: .window, payload: Data([0x00, 0x01, 0x00, 0x00])),
        Frame(streamID: .session, type: .ping, payload: Data([1, 2, 3, 4, 5, 6, 7, 8])),
        Frame(streamID: StreamID(rawValue: 3), type: .data, flags: .message),
    ]

    @Test("One cut at every byte decodes the same frames")
    func everySingleSplit() throws {
        let bytes = wireBytes(Self.smallFrames)
        for offset in 0...bytes.count {
            #expect(try decodeAll(bytes.split(at: [offset])) == Self.smallFrames, "cut at \(offset)")
        }
    }

    static let largeFrames: [Frame] = {
        var generator = SplitMix64(seed: 0x4B52_4E32)
        return [
            Frame(
                streamID: StreamID(rawValue: 1), type: .data, payload: generator.bytes(WireConstants.maxRawDataPayload)),
            Frame(streamID: StreamID(rawValue: 1), type: .data, flags: .message, payload: generator.bytes(65_536)),
            Frame(
                streamID: StreamID(rawValue: 3), type: .data, payload: generator.bytes(WireConstants.maxRawDataPayload)),
        ]
    }()

    @Test(
        "Cuts at a 1 MiB frame's boundaries and inside its payload decode the same frames",
        arguments: [0, 1, 4, 13, 14, 15, 65_550, 524_302, 1_048_589, 1_048_590, 1_048_591, 1_114_136, 1_114_137]
    )
    func boundedLargeSplit(_ offset: Int) throws {
        let bytes = wireBytes(Self.largeFrames)
        #expect(try decodeAll(bytes.split(at: [offset, offset + (bytes.count - offset) / 2])) == Self.largeFrames)
    }

    @Test("A 1 MiB frame arriving a byte at a time is held as its payload so far, and nothing more")
    func byteAtATimeStorageIsThePayload() throws {
        var generator = SplitMix64(seed: 4)
        let frame = Frame(
            streamID: StreamID(rawValue: 1), type: .data, payload: generator.bytes(WireConstants.maxRawDataPayload))
        let bytes = wireBytes([frame])
        let payloadStart = WireConstants.preamble.count + WireConstants.headerByteCount
        var decoder = FrameDecoder()
        var violations = 0
        for offset in 0..<(bytes.count - 1) {
            decoder.append(bytes[offset...offset])
            let held = decoder.bufferedByteCount
            let expected: Int
            if offset < WireConstants.preamble.count {
                expected = (offset + 1) % WireConstants.preamble.count
            } else if offset < payloadStart {
                expected = (offset + 1 - WireConstants.preamble.count) % WireConstants.headerByteCount
            } else {
                expected = offset + 1 - payloadStart
            }
            if held != expected { violations += 1 }
        }
        #expect(violations == 0)
        #expect(try decoder.nextFrame() == nil)
        decoder.append(bytes.suffix(1))
        #expect(try decoder.nextFrame() == frame)
        #expect(decoder.bufferedByteCount == 0)
    }

    /// Whether `payload`'s bytes lie inside `chunk`'s storage.
    private func shares(_ payload: Data, with chunk: Data) -> Bool {
        payload.withUnsafeBytes { payloadBytes in
            chunk.withUnsafeBytes { chunkBytes in
                guard let payloadStart = payloadBytes.baseAddress, let chunkStart = chunkBytes.baseAddress else {
                    return false
                }
                return payloadStart >= chunkStart && payloadStart < chunkStart + chunkBytes.count
            }
        }
    }

    @Test("A raw DATA payload of 64 KiB or more inside one chunk is a slice of it")
    func largeRawPayloadIsSliced() throws {
        var generator = SplitMix64(seed: 1)
        let frame = Frame(streamID: StreamID(rawValue: 1), type: .data, payload: generator.bytes(65_536))
        let chunk = wireBytes([frame])
        var decoder = FrameDecoder()
        decoder.append(chunk)
        let decoded = try #require(try decoder.nextFrame())
        #expect(decoded == frame)
        #expect(shares(decoded.payload, with: chunk))
    }
}
