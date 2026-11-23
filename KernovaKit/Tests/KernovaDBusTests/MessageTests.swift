import Testing

@testable import KernovaDBus

/// One message of each type, every header field set somewhere.
let sampleMessages: [DBusMessage] = {
    var call = DBusMessage.methodCall(
        destination: "org.freedesktop.login1", path: "/org/freedesktop/login1",
        interface: "org.freedesktop.login1.Manager", member: "PowerOff", body: [.boolean(false)])
    call.header.flags = [.noAutoStart, .allowInteractiveAuthorization]
    call.header.sender = ":1.42"

    var reply = DBusMessage(header: DBusMessageHeader(kind: .methodReturn))
    reply.header.replySerial = 7
    reply.header.destination = ":1.42"
    reply.body = [
        .array(
            elementType: .struct([.string, .string, .string, .string, .uint32, .uint32]),
            [
                .struct([
                    .string("shutdown"), .string("GNOME"), .string("unsaved"), .string("block"), .uint32(1000),
                    .uint32(1234),
                ])
            ])
    ]

    var error = DBusMessage(header: DBusMessageHeader(kind: .error))
    error.header.replySerial = 8
    error.header.errorName = "org.freedesktop.DBus.Error.AccessDenied"
    error.body = [.string("No.")]

    let signal = DBusMessage.signal(
        path: "/org/freedesktop/login1/session/_32", interface: "org.freedesktop.DBus.Properties",
        member: "PropertiesChanged",
        body: [
            .string("org.freedesktop.login1.Session"),
            .dictionary(key: .string, value: .variant, [(.string("Active"), .variant(.boolean(true)))]),
            .array(elementType: .string, [.string("State")]),
        ])
    return [call, reply, error, signal, .methodCall(destination: nil, path: "/", interface: nil, member: "Ping")]
}()

@Suite("DBusMessage encoding and decoding")
struct MessageTests {
    @Test("A message type the specification does not define decodes to nil")
    func unknownType() throws {
        var bytes = try sampleMessages[1].encoded(serial: 1)
        bytes[1] = 9
        #expect(try DBusReceivedMessage.decode(bytes) == nil)
        bytes[1] = 0
        #expect(throws: DBusProtocolError.invalidMessageType) { try DBusReceivedMessage.decode(bytes) }
    }

    @Test("Flag bits the specification does not define are dropped")
    func unknownFlags() throws {
        var bytes = try sampleMessages[4].encoded(serial: 1)
        bytes[2] = 0xF1
        #expect(try #require(try DBusReceivedMessage.decode(bytes)).header.flags == .noReplyExpected)
    }

    @Test("An unknown header field is skipped; a known one with the wrong type, or twice, is refused")
    func headerFields() throws {
        // The MEMBER field rewritten as code 0x63 makes it unknown; the call
        // then lacks a member.
        let call = DBusMessage.methodCall(destination: nil, path: "/a", interface: nil, member: "M")
        var bytes = try call.encoded(serial: 1, byteOrder: .littleEndian)
        let memberField = 32
        #expect(bytes[memberField] == 3)
        bytes[memberField] = 0x63
        #expect(throws: DBusProtocolError.missingHeaderField(3)) { try DBusReceivedMessage.decode(bytes) }

        bytes[memberField] = 1  // A second PATH, holding a string.
        #expect(throws: DBusProtocolError.invalidHeaderField(1)) { try DBusReceivedMessage.decode(bytes) }

        bytes[memberField] = 0
        #expect(throws: DBusProtocolError.invalidHeaderField(0)) { try DBusReceivedMessage.decode(bytes) }

        // REPLY_SERIAL in a signal, which has no use for it, is accepted.
        var signal = sampleMessages[3]
        signal.header.replySerial = 4
        #expect(try #require(try DBusReceivedMessage.decode(signal.encoded(serial: 1))).header.replySerial == 4)

        // Two DESTINATION fields: the first one's code rewritten as SENDER's,
        // then SENDER duplicated by also setting it.
        var twice = call
        twice.header.destination = ":1.1"
        twice.header.sender = ":1.2"
        var duplicated = try twice.encoded(serial: 1, byteOrder: .littleEndian)
        let destinationField = try #require(fieldOffset(code: 6, in: duplicated))
        duplicated[destinationField] = 7
        #expect(throws: DBusProtocolError.duplicateHeaderField(7)) { try DBusReceivedMessage.decode(duplicated) }
    }

    @Test("decodeBody(expecting:) checks the signature before decoding")
    func expectingSignature() throws {
        let decoded = try #require(try DBusReceivedMessage.decode(sampleMessages[0].encoded(serial: 1)))
        #expect(try decoded.decodeBody(expecting: "b") == [.boolean(false)])
        #expect(throws: DBusProtocolError.signatureMismatch(expected: "s", actual: "b")) {
            try decoded.decodeBody(expecting: "s")
        }
    }
}

/// The offset of the header field with `code`, in a little-endian message.
func fieldOffset(code: UInt8, in bytes: [UInt8]) -> Int? {
    let end = 16 + (Int(bytes[12]) | Int(bytes[13]) << 8)
    var index = 16
    while index < end {
        index = (index + 7) & ~7
        if bytes[index] == code { return index }
        // code, signature length, signature, NUL, then the value.
        let signatureLength = Int(bytes[index + 1])
        let signatureCode = bytes[index + 2]
        index += 3 + signatureLength
        switch signatureCode {
        case UInt8(ascii: "u"):
            index = (index + 3) & ~3 + 4
        case UInt8(ascii: "g"):
            index += Int(bytes[index]) + 2
        default:
            index = (index + 3) & ~3
            let length = Int(bytes[index]) | Int(bytes[index + 1]) << 8
            index += 4 + length + 1
        }
    }
    return nil
}
