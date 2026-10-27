#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

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

    @Test("Every pair of cuts decodes the same frames")
    func everyPairOfSplits() throws {
        let bytes = wireBytes(Array(Self.smallFrames.prefix(4)))
        for first in 0...bytes.count {
            for second in first...bytes.count {
                #expect(try decodeAll(bytes.split(at: [first, second])) == Array(Self.smallFrames.prefix(4)))
            }
        }
    }

    @Test("One byte at a time decodes the same frames, each as soon as its last byte arrives")
    func byteAtATime() throws {
        let bytes = wireBytes(Self.smallFrames)
        var decoder = FrameDecoder()
        var frames: [Frame] = []
        var frameEnds: [Int] = []
        for index in bytes.indices {
            decoder.append(bytes[index...index])
            while let frame = try decoder.nextFrame() {
                frames.append(frame)
                frameEnds.append(index + 1)
            }
        }
        #expect(frames == Self.smallFrames)
        var expectedEnds: [Int] = []
        var end = WireConstants.preamble.count
        for frame in Self.smallFrames {
            end += WireConstants.headerByteCount + frame.payload.count
            expectedEnds.append(end)
        }
        #expect(frameEnds == expectedEnds)
        #expect(decoder.bufferedByteCount == 0)
    }

    static let largeFrames: [Frame] = {
        var generator = SeededGenerator(seed: 0x4B52_4E32)
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

    @Test("256 KiB reads, the largest a ByteStream delivers, decode 1 MiB frames", arguments: [262_144, 100_003])
    func streamedLargeFrames(_ readSize: Int) throws {
        let bytes = wireBytes(Self.largeFrames)
        let offsets = Array(stride(from: readSize, to: bytes.count, by: readSize))
        #expect(try decodeAll(bytes.split(at: offsets)) == Self.largeFrames)
    }

    @Test("Nothing is buffered past the frame being assembled and the latest read")
    func bufferIsBounded() throws {
        let bytes = wireBytes(Self.largeFrames)
        let readSize = 262_144
        var decoder = FrameDecoder()
        var start = 0
        var peak = 0
        while start < bytes.count {
            let end = min(start + readSize, bytes.count)
            decoder.append(bytes[start..<end])
            peak = max(peak, decoder.bufferedByteCount)
            while try decoder.nextFrame() != nil {}
            start = end
        }
        #expect(peak <= WireConstants.headerByteCount + WireConstants.maxRawDataPayload + readSize)
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test("A 1 MiB frame arriving a byte at a time is held as its payload so far, and nothing more")
    func byteAtATimeStorageIsThePayload() throws {
        var generator = SeededGenerator(seed: 4)
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

    @Test("Frames decoded before an error are returned before it is thrown")
    func framesBeforeAnErrorComeFirst() throws {
        let ping = Frame(streamID: .session, type: .ping, payload: Data(count: 8))
        var decoder = FrameDecoder()
        decoder.append(wireBytes([ping]) + rawHeader(type: 0x07, length: 0))
        #expect(try decoder.nextFrame() == ping)
        #expect(throws: FrameError.unknownType(0x07)) { try decoder.nextFrame() }
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
        var generator = SeededGenerator(seed: 1)
        let frame = Frame(streamID: StreamID(rawValue: 1), type: .data, payload: generator.bytes(65_536))
        let chunk = wireBytes([frame])
        var decoder = FrameDecoder()
        decoder.append(chunk)
        let decoded = try #require(try decoder.nextFrame())
        #expect(decoded == frame)
        #expect(shares(decoded.payload, with: chunk))
    }

    @Test("Every payload under 64 KiB, and every message or control payload, is copied")
    func smallAndControlPayloadsAreCopied() throws {
        var generator = SeededGenerator(seed: 2)
        let frames = [
            Frame(streamID: StreamID(rawValue: 1), type: .data, payload: generator.bytes(65_535)),
            Frame(streamID: StreamID(rawValue: 1), type: .data, flags: .message, payload: generator.bytes(65_536)),
            Frame(streamID: StreamID(rawValue: 1), type: .open, payload: generator.bytes(65_536)),
            Frame(streamID: StreamID(rawValue: 1), type: .end, payload: generator.bytes(100)),
            Frame(streamID: StreamID(rawValue: 1), type: .reset, payload: generator.bytes(65_536)),
        ]
        let chunk = wireBytes(frames)
        var decoder = FrameDecoder()
        decoder.append(chunk)
        for frame in frames {
            let decoded = try #require(try decoder.nextFrame())
            #expect(decoded == frame)
            #expect(!shares(decoded.payload, with: chunk), "\(frame.type) of \(frame.payload.count) bytes")
        }
    }

    @Test("A large raw DATA payload spanning chunks is assembled into storage of its own")
    func spanningPayloadIsAssembled() throws {
        var generator = SeededGenerator(seed: 3)
        let frame = Frame(streamID: StreamID(rawValue: 1), type: .data, payload: generator.bytes(200_000))
        let pieces = wireBytes([frame]).split(at: [100_000])
        var decoder = FrameDecoder()
        decoder.append(pieces[0])
        #expect(try decoder.nextFrame() == nil)
        decoder.append(pieces[1])
        let decoded = try #require(try decoder.nextFrame())
        #expect(decoded == frame)
        #expect(decoded.payload.startIndex == 0)
        #expect(!shares(decoded.payload, with: pieces[0]) && !shares(decoded.payload, with: pieces[1]))
    }
}
