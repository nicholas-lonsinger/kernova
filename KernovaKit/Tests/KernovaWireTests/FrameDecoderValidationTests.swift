#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire
import Testing

@Suite("FrameDecoder header validation")
struct FrameDecoderValidationTests {
    struct Rejection: Sendable, CustomTestStringConvertible {
        var header: Data
        var error: FrameError
        var code: ErrorCode
        var testDescription: String { "\(error)" }
    }

    static let rejections: [Rejection] = [
        Rejection(header: rawHeader(type: 0x06, length: 0), error: .unknownType(0x06), code: .protocolError),
        Rejection(header: rawHeader(type: 0xFF, length: 4), error: .unknownType(0xFF), code: .protocolError),
        Rejection(
            header: rawHeader(type: 0x00, flags: 0x02, length: 1), error: .undefinedFlags(.data, 0x02),
            code: .protocolError),
        Rejection(
            header: rawHeader(type: 0x00, flags: 0x81, length: 1), error: .undefinedFlags(.data, 0x81),
            code: .protocolError),
        Rejection(
            header: rawHeader(type: 0x01, flags: 0x01, length: 0), error: .undefinedFlags(.open, 0x01),
            code: .protocolError),
        Rejection(
            header: rawHeader(type: 0x02, flags: 0x01, length: 0), error: .undefinedFlags(.end, 0x01),
            code: .protocolError),
        Rejection(
            header: rawHeader(type: 0x03, flags: 0x01, length: 0), error: .undefinedFlags(.reset, 0x01),
            code: .protocolError),
        Rejection(
            header: rawHeader(type: 0x04, flags: 0x01, length: 4), error: .undefinedFlags(.window, 0x01),
            code: .protocolError),
        Rejection(
            header: rawHeader(type: 0x05, flags: 0x40, length: 8), error: .undefinedFlags(.ping, 0x40),
            code: .protocolError),
        Rejection(
            header: rawHeader(type: 0x00, length: 1_048_577), error: .payloadTooLarge(.data, declared: 1_048_577),
            code: .frameTooLarge),
        Rejection(
            header: rawHeader(type: 0x00, length: UInt32.max), error: .payloadTooLarge(.data, declared: UInt32.max),
            code: .frameTooLarge),
        Rejection(
            header: rawHeader(type: 0x00, flags: 0x01, length: 65_537),
            error: .payloadTooLarge(.data, declared: 65_537), code: .frameTooLarge),
        Rejection(
            header: rawHeader(type: 0x01, length: 65_537), error: .payloadTooLarge(.open, declared: 65_537),
            code: .frameTooLarge),
        Rejection(
            header: rawHeader(type: 0x02, length: 65_537), error: .payloadTooLarge(.end, declared: 65_537),
            code: .frameTooLarge),
        Rejection(
            header: rawHeader(type: 0x03, length: 65_537), error: .payloadTooLarge(.reset, declared: 65_537),
            code: .frameTooLarge),
        Rejection(
            header: rawHeader(type: 0x04, length: 0), error: .wrongFixedLength(.window, declared: 0),
            code: .protocolError),
        Rejection(
            header: rawHeader(type: 0x04, length: 3), error: .wrongFixedLength(.window, declared: 3),
            code: .protocolError),
        Rejection(
            header: rawHeader(type: 0x04, length: 5), error: .wrongFixedLength(.window, declared: 5),
            code: .protocolError),
        Rejection(
            header: rawHeader(type: 0x05, length: 0), error: .wrongFixedLength(.ping, declared: 0),
            code: .protocolError),
        Rejection(
            header: rawHeader(type: 0x05, length: 7), error: .wrongFixedLength(.ping, declared: 7),
            code: .protocolError),
        Rejection(
            header: rawHeader(type: 0x05, length: 9), error: .wrongFixedLength(.ping, declared: 9),
            code: .protocolError),
        Rejection(header: rawHeader(type: 0x00, length: 0), error: .emptyRawData, code: .protocolError),
    ]

    @Test("A header the table rejects throws once its 10 bytes arrive, before any payload", arguments: rejections)
    func rejectsHeader(_ rejection: Rejection) {
        var decoder = FrameDecoder()
        decoder.append(WireConstants.preamble)
        decoder.append(rejection.header.prefix(9))
        #expect(throws: Never.self) { try decoder.nextFrame() }
        decoder.append(rejection.header.suffix(1))
        #expect(throws: rejection.error) { try decoder.nextFrame() }
        #expect(rejection.error.closeCode == rejection.code)
    }

    @Test("The first error is final, and nothing appended after it is buffered")
    func errorIsSticky() {
        var decoder = FrameDecoder()
        decoder.append(WireConstants.preamble + rawHeader(type: 0x09, length: 0))
        #expect(throws: FrameError.unknownType(0x09)) { try decoder.nextFrame() }
        decoder.append(wireBytes([Frame(streamID: .session, type: .ping, payload: Data(count: 8))], preamble: false))
        #expect(decoder.bufferedByteCount == 0)
        #expect(throws: FrameError.unknownType(0x09)) { try decoder.nextFrame() }
    }

    @Test("A preamble mismatch has no close code: the transport closes with no RESET")
    func badPreambleHasNoCloseCode() {
        #expect(FrameError.badPreamble.closeCode == nil)
    }

    struct Acceptance: Sendable, CustomTestStringConvertible {
        var type: FrameType
        var flags: FrameFlags
        var length: Int
        var testDescription: String { "\(type) flags \(flags.rawValue) length \(length)" }
    }

    static let acceptances: [Acceptance] = [
        Acceptance(type: .data, flags: [], length: 1),
        Acceptance(type: .data, flags: [], length: WireConstants.maxRawDataPayload),
        Acceptance(type: .data, flags: .message, length: 0),
        Acceptance(type: .data, flags: .message, length: WireConstants.maxControlPayload),
        Acceptance(type: .open, flags: [], length: 0),
        Acceptance(type: .open, flags: [], length: WireConstants.maxControlPayload),
        Acceptance(type: .end, flags: [], length: 0),
        Acceptance(type: .end, flags: [], length: WireConstants.maxControlPayload),
        Acceptance(type: .reset, flags: [], length: 0),
        Acceptance(type: .reset, flags: [], length: WireConstants.maxControlPayload),
        Acceptance(type: .window, flags: [], length: WireConstants.windowPayloadByteCount),
        Acceptance(type: .ping, flags: [], length: WireConstants.pingPayloadByteCount),
    ]

    @Test("Every length at a type's bounds decodes", arguments: acceptances)
    func acceptsBounds(_ acceptance: Acceptance) throws {
        var generator = SeededGenerator(seed: UInt64(acceptance.length))
        let frame = Frame(
            streamID: StreamID(rawValue: 7), type: acceptance.type, flags: acceptance.flags,
            payload: generator.bytes(acceptance.length))
        let frames = try decodeAll([wireBytes([frame])])
        #expect(frames == [frame])
    }
}
