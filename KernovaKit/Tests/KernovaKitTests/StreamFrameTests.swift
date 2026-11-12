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

    // MARK: - decode

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
