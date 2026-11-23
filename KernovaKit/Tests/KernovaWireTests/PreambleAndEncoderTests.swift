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
        #expect(WireConstants.vsockPort == 0xC008)
    }
}
