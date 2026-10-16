import Testing
import Foundation
import KernovaTestSupport
@testable import KernovaKit

@Suite("StreamFrame", .caseScoped)
struct StreamFrameTests {
    // MARK: - encode

    @Test("encode prepends a big-endian length prefix")
    func encodePrependsLength() throws {
        let payload = Data([0xAA, 0xBB, 0xCC])
        let framed = try StreamFrame.encode(payload)

        #expect(framed.count == 4 + payload.count)
        #expect(framed.prefix(4) == Data([0x00, 0x00, 0x00, 0x03]))
        #expect(framed.suffix(payload.count) == payload)
    }

    @Test("encode rejects payloads above maxPayloadSize")
    func encodeRejectsOversize() {
        let oversize = Data(count: StreamFrame.maxPayloadSize + 1)
        #expect(
            throws: StreamFrameError.frameTooLarge(
                declaredSize: StreamFrame.maxPayloadSize + 1,
                maxAllowed: StreamFrame.maxPayloadSize
            )
        ) {
            try StreamFrame.encode(oversize)
        }
    }

    // MARK: - decode

    @Test("decoder returns nil with partial length prefix")
    func decoderPartialLength() throws {
        var decoder = StreamFrameDecoder()
        decoder.feed(Data([0x00, 0x00]))
        #expect(try decoder.nextFrame() == nil)
        #expect(decoder.bufferedByteCount == 2)
    }

    @Test("decoder returns nil when full length prefix is read but payload incomplete")
    func decoderPartialPayload() throws {
        var decoder = StreamFrameDecoder()
        decoder.feed(Data([0x00, 0x00, 0x00, 0x05, 0xAA, 0xBB]))  // 5 expected, only 2 present
        #expect(try decoder.nextFrame() == nil)
    }

    @Test("decoder yields a single complete frame")
    func decoderYieldsSingleFrame() throws {
        var decoder = StreamFrameDecoder()
        let payload = Data([0x10, 0x20, 0x30])
        decoder.feed(try StreamFrame.encode(payload))

        let frame = try decoder.nextFrame()
        #expect(frame == payload)

        // Subsequent call returns nil — buffer drained.
        #expect(try decoder.nextFrame() == nil)
        #expect(decoder.isEmpty)
    }

    @Test("decoder reassembles a frame split across many feeds")
    func decoderHandlesSplitFrame() throws {
        var decoder = StreamFrameDecoder()
        let payload = Data((0..<32).map { UInt8($0) })
        let framed = try StreamFrame.encode(payload)

        // Feed one byte at a time.
        for byte in framed.dropLast() {
            decoder.feed(Data([byte]))
            #expect(try decoder.nextFrame() == nil)
        }
        // Last byte completes the frame.
        decoder.feed(Data([framed.last!]))
        #expect(try decoder.nextFrame() == payload)
    }

    @Test("decoder yields multiple frames from one chunk")
    func decoderYieldsMultipleFrames() throws {
        var decoder = StreamFrameDecoder()
        let a = Data([0x01, 0x02])
        let b = Data([0x03, 0x04, 0x05])
        let combined = try StreamFrame.encode(a) + (try StreamFrame.encode(b))

        decoder.feed(combined)
        #expect(try decoder.nextFrame() == a)
        #expect(try decoder.nextFrame() == b)
        #expect(try decoder.nextFrame() == nil)
    }

    @Test("decoder yields a zero-length payload as empty Data")
    func decoderYieldsEmptyPayload() throws {
        var decoder = StreamFrameDecoder()
        decoder.feed(Data([0x00, 0x00, 0x00, 0x00]))
        #expect(try decoder.nextFrame() == Data())
        #expect(decoder.isEmpty)
    }

    @Test("decoder throws frameTooLarge when declared size exceeds the cap")
    func decoderRejectsOversize() {
        var decoder = StreamFrameDecoder()
        // 0xFFFFFFFF declared length — way over the 16 MiB cap.
        decoder.feed(Data([0xFF, 0xFF, 0xFF, 0xFF]))
        #expect(throws: StreamFrameError.self) {
            _ = try decoder.nextFrame()
        }
    }

    // MARK: - compaction

    @Test("decoder remains correct after consuming more than the compaction threshold")
    func decoderSurvivesCompaction() throws {
        var decoder = StreamFrameDecoder()
        let payload = Data(repeating: 0xAB, count: 1024)
        let framed = try StreamFrame.encode(payload)

        // Enough frames to cross the compaction threshold several times.
        let frameCount = 256
        for _ in 0..<frameCount {
            decoder.feed(framed)
            let got = try decoder.nextFrame()
            #expect(got == payload)
        }
        #expect(decoder.isEmpty)
        #expect(decoder.bufferedByteCount == 0)

        // Decoder is still usable for new frames after compaction cycles.
        decoder.feed(try StreamFrame.encode(Data([0x01, 0x02, 0x03])))
        #expect(try decoder.nextFrame() == Data([0x01, 0x02, 0x03]))
    }

    @Test("decoder yields correct payloads while draining across a compaction boundary")
    func decoderDrainsAcrossCompactionBoundary() throws {
        var decoder = StreamFrameDecoder()
        // Build a single chunk large enough to trigger compaction mid-drain.
        let payload = Data((0..<64).map { UInt8($0 & 0xFF) })
        let framed = try StreamFrame.encode(payload)
        // Enough frames to cross the compaction threshold several times in one feed.
        let frameCount = 1100
        var bulk = Data()
        bulk.reserveCapacity(framed.count * frameCount)
        for _ in 0..<frameCount { bulk.append(framed) }

        decoder.feed(bulk)

        for i in 0..<frameCount {
            let got = try decoder.nextFrame()
            #expect(got == payload, "payload mismatch at frame \(i)")
        }
        #expect(try decoder.nextFrame() == nil)
    }

    // MARK: - chunk-sized frames (#377)

    @Test("retained payload slices stay valid across later decoder mutations")
    func retainedPayloadSlicesSurviveLaterMutations() throws {
        var decoder = StreamFrameDecoder()
        // `nextFrame` returns a slice aliasing the decoder buffer; a caller holding
        // it past the next feed/nextFrame relies on Data's copy-on-write to keep the
        // bytes correct. Retain the first two chunk-sized payloads, then drain the
        // third (which mutates and compacts the aliased buffer) and confirm the
        // retained slices are still byte-correct.
        let chunkSize = 64 * 1024
        let p0 = Data((0..<chunkSize).map { UInt8($0 & 0xFF) })
        let p1 = Data((0..<chunkSize).map { UInt8(($0 &+ 1) & 0xFF) })
        let p2 = Data((0..<chunkSize).map { UInt8(($0 &+ 2) & 0xFF) })
        var bulk = try StreamFrame.encode(p0)
        bulk.append(try StreamFrame.encode(p1))
        bulk.append(try StreamFrame.encode(p2))
        decoder.feed(bulk)

        let first = try decoder.nextFrame()
        let second = try decoder.nextFrame()
        let third = try decoder.nextFrame()

        #expect(first == p0)
        #expect(second == p1)
        #expect(third == p2)
        #expect(try decoder.nextFrame() == nil)
    }
}
