import Testing
import Foundation
@testable import KernovaProtocol

@Suite("VsockFrame")
struct VsockFrameTests {

    // MARK: - encode

    @Test("encode prepends a big-endian length prefix")
    func encodePrependsLength() throws {
        let payload = Data([0xAA, 0xBB, 0xCC])
        let framed = try VsockFrame.encode(payload)

        #expect(framed.count == 4 + payload.count)
        #expect(framed.prefix(4) == Data([0x00, 0x00, 0x00, 0x03]))
        #expect(framed.suffix(payload.count) == payload)
    }

    @Test("encode of empty payload produces a 4-byte zero-length frame")
    func encodeEmptyPayload() throws {
        let framed = try VsockFrame.encode(Data())
        #expect(framed == Data([0x00, 0x00, 0x00, 0x00]))
    }

    @Test("encode rejects payloads above maxPayloadSize")
    func encodeRejectsOversize() {
        let oversize = Data(count: VsockFrame.maxPayloadSize + 1)
        #expect(throws: VsockFrameError.frameTooLarge(
            declaredSize: VsockFrame.maxPayloadSize + 1,
            maxAllowed: VsockFrame.maxPayloadSize
        )) {
            try VsockFrame.encode(oversize)
        }
    }

    // MARK: - decode

    @Test("decoder returns nil with empty buffer")
    func decoderEmpty() throws {
        var decoder = VsockFrameDecoder()
        #expect(try decoder.nextFrame() == nil)
    }

    @Test("decoder returns nil with partial length prefix")
    func decoderPartialLength() throws {
        var decoder = VsockFrameDecoder()
        decoder.feed(Data([0x00, 0x00]))
        #expect(try decoder.nextFrame() == nil)
        #expect(decoder.bufferedByteCount == 2)
    }

    @Test("decoder returns nil when full length prefix is read but payload incomplete")
    func decoderPartialPayload() throws {
        var decoder = VsockFrameDecoder()
        decoder.feed(Data([0x00, 0x00, 0x00, 0x05, 0xAA, 0xBB]))   // 5 expected, only 2 present
        #expect(try decoder.nextFrame() == nil)
    }

    @Test("decoder yields a single complete frame")
    func decoderYieldsSingleFrame() throws {
        var decoder = VsockFrameDecoder()
        let payload = Data([0x10, 0x20, 0x30])
        decoder.feed(try VsockFrame.encode(payload))

        let frame = try decoder.nextFrame()
        #expect(frame == payload)

        // Subsequent call returns nil — buffer drained.
        #expect(try decoder.nextFrame() == nil)
        #expect(decoder.isEmpty)
    }

    @Test("decoder reassembles a frame split across many feeds")
    func decoderHandlesSplitFrame() throws {
        var decoder = VsockFrameDecoder()
        let payload = Data((0..<32).map { UInt8($0) })
        let framed = try VsockFrame.encode(payload)

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
        var decoder = VsockFrameDecoder()
        let a = Data([0x01, 0x02])
        let b = Data([0x03, 0x04, 0x05])
        let combined = try VsockFrame.encode(a) + (try VsockFrame.encode(b))

        decoder.feed(combined)
        #expect(try decoder.nextFrame() == a)
        #expect(try decoder.nextFrame() == b)
        #expect(try decoder.nextFrame() == nil)
    }

    @Test("decoder yields a zero-length payload as empty Data")
    func decoderYieldsEmptyPayload() throws {
        var decoder = VsockFrameDecoder()
        decoder.feed(Data([0x00, 0x00, 0x00, 0x00]))
        #expect(try decoder.nextFrame() == Data())
        #expect(decoder.isEmpty)
    }

    @Test("decoder throws frameTooLarge when declared size exceeds the cap")
    func decoderRejectsOversize() {
        var decoder = VsockFrameDecoder()
        // 0xFFFFFFFF declared length — way over the 16 MiB cap.
        decoder.feed(Data([0xFF, 0xFF, 0xFF, 0xFF]))
        #expect(throws: VsockFrameError.self) {
            _ = try decoder.nextFrame()
        }
    }

    // MARK: - compaction

    @Test("decoder remains correct after consuming more than the compaction threshold")
    func decoderSurvivesCompaction() throws {
        var decoder = VsockFrameDecoder()
        let payload = Data(repeating: 0xAB, count: 1024)
        let framed = try VsockFrame.encode(payload)

        // Feed and consume enough frames to cross 64 KiB consumed bytes several times.
        let frameCount = 256  // ~256 KiB of data
        for _ in 0..<frameCount {
            decoder.feed(framed)
            let got = try decoder.nextFrame()
            #expect(got == payload)
        }
        #expect(decoder.isEmpty)
        #expect(decoder.bufferedByteCount == 0)

        // Decoder is still usable for new frames after compaction cycles.
        decoder.feed(try VsockFrame.encode(Data([0x01, 0x02, 0x03])))
        #expect(try decoder.nextFrame() == Data([0x01, 0x02, 0x03]))
    }

    @Test("decoder reports correct bufferedByteCount mid-stream after compaction")
    func decoderBufferedByteCountAfterCompaction() throws {
        var decoder = VsockFrameDecoder()
        // Push enough frames to trip compaction, but leave a partial frame at the tail.
        let smallPayload = Data(repeating: 0x55, count: 4096)
        let smallFramed = try VsockFrame.encode(smallPayload)
        for _ in 0..<32 {  // ~128 KiB consumed
            decoder.feed(smallFramed)
            _ = try decoder.nextFrame()
        }

        // Feed a half-frame to leave unread bytes hanging.
        let halfFrame = smallFramed.prefix(smallFramed.count / 2)
        decoder.feed(halfFrame)
        #expect(try decoder.nextFrame() == nil)
        #expect(decoder.bufferedByteCount == halfFrame.count)
    }

    // MARK: - round trip

    @Test("encode/decode round-trip preserves arbitrary bytes")
    func roundTrip() throws {
        let payloads: [Data] = [
            Data(),
            Data([0x42]),
            Data((0..<1024).map { UInt8($0 & 0xFF) }),
            Data(repeating: 0xAB, count: 65_535),
        ]

        var decoder = VsockFrameDecoder()
        for payload in payloads {
            decoder.feed(try VsockFrame.encode(payload))
        }

        for expected in payloads {
            #expect(try decoder.nextFrame() == expected)
        }
        #expect(try decoder.nextFrame() == nil)
    }
}
