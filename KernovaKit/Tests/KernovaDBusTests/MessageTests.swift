import KernovaDBus
import Testing

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
    @Test("Each message type round-trips in both byte orders", arguments: [DBusByteOrder.littleEndian, .bigEndian])
    func roundTrip(byteOrder: DBusByteOrder) throws {
        for (index, message) in sampleMessages.enumerated() {
            let serial = UInt32(index + 1)
            let bytes = try message.encoded(serial: serial, byteOrder: byteOrder)
            #expect(bytes[0] == byteOrder.rawValue)
            #expect(bytes.count % 8 == 0 || !message.body.isEmpty)
            let decoded = try #require(try DBusReceivedMessage.decode(bytes))
            #expect(decoded.header == message.header)
            #expect(decoded.serial == serial)
            #expect(decoded.signature == (try DBusSignature(message.body.map(\.type))))
            #expect(try decoded.decodeBody() == message.body)
        }
    }

    @Test("The fixed header and field layout match the specification")
    func layout() throws {
        let message = DBusMessage.methodCall(
            destination: nil, path: "/a", interface: nil, member: "M", body: [.byte(9)])
        let bytes = try message.encoded(serial: 0x0102_0304, byteOrder: .bigEndian)
        #expect(
            bytes == [
                0x42, 1, 0, 1, 0, 0, 0, 1, 1, 2, 3, 4,
                0, 0, 0, 0x27,  // fields: 39 bytes
                1, 1, 0x6F, 0, 0, 0, 0, 2, 0x2F, 0x61, 0,  // PATH "/a"
                0, 0, 0, 0, 0,  // padding to 8
                3, 1, 0x73, 0, 0, 0, 0, 1, 0x4D, 0,  // MEMBER "M"
                0, 0, 0, 0, 0, 0,  // padding to 8
                8, 1, 0x67, 0, 1, 0x79, 0,  // SIGNATURE "y"
                0,  // padding the header to 8
                9,  // the body
            ])
    }

    @Test("Encoding refuses what the specification refuses")
    func encodeRefusals() {
        let call = DBusMessage.methodCall(destination: nil, path: "/", interface: nil, member: "M")
        #expect(throws: DBusProtocolError.zeroSerial) { try call.encoded(serial: 0) }

        var noMember = call
        noMember.header.member = nil
        #expect(throws: DBusProtocolError.missingHeaderField(3)) { try noMember.encoded(serial: 1) }

        var badInterface = call
        badInterface.header.interface = "nodots"
        #expect(throws: DBusProtocolError.invalidName(.interface, "nodots")) { try badInterface.encoded(serial: 1) }

        var signalWithoutInterface = DBusMessage(header: DBusMessageHeader(kind: .signal))
        signalWithoutInterface.header.path = "/"
        signalWithoutInterface.header.member = "S"
        #expect(throws: DBusProtocolError.missingHeaderField(2)) { try signalWithoutInterface.encoded(serial: 1) }

        let errorWithoutName = DBusMessage(
            header: {
                var header = DBusMessageHeader(kind: .error)
                header.replySerial = 1
                return header
            }())
        #expect(throws: DBusProtocolError.missingHeaderField(4)) { try errorWithoutName.encoded(serial: 1) }

        let returnWithoutSerial = DBusMessage(header: DBusMessageHeader(kind: .methodReturn))
        #expect(throws: DBusProtocolError.missingHeaderField(5)) { try returnWithoutSerial.encoded(serial: 1) }

        var withDescriptor = call
        withDescriptor.body = [.unixFD(0)]
        #expect(throws: DBusProtocolError.unixFDsNotNegotiated) { try withDescriptor.encoded(serial: 1) }
    }

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

    @Test("The fixed header alone refuses bad byte orders, versions and sizes")
    func fixedHeader() throws {
        var bytes = try sampleMessages[4].encoded(serial: 1)
        bytes[0] = 0x58
        #expect(throws: DBusProtocolError.invalidByteOrder(0x58)) { try DBusReceivedMessage.decode(bytes) }
        bytes[0] = DBusByteOrder.littleEndian.rawValue
        bytes[3] = 2
        #expect(throws: DBusProtocolError.unsupportedProtocolVersion(2)) { try DBusReceivedMessage.decode(bytes) }
        bytes[3] = 1
        bytes[8..<12] = [0, 0, 0, 0]
        #expect(throws: DBusProtocolError.zeroSerial) { try DBusReceivedMessage.decode(bytes) }

        // 2^27 bytes in all is the most; the body length alone claims more.
        var huge = try sampleMessages[4].encoded(serial: 1)
        let headerLength = huge.count
        let bodyLength = UInt32(DBusLimits.maximumMessageLength - headerLength + 1)
        huge[4..<8] = withUnsafeBytes(of: bodyLength.littleEndian) { ArraySlice($0) }
        #expect(throws: DBusProtocolError.messageTooLong(DBusLimits.maximumMessageLength + 1)) {
            try DBusReceivedMessage.decode(huge)
        }
        let fieldsLength = UInt32(DBusLimits.maximumArrayLength + 1)
        huge[12..<16] = withUnsafeBytes(of: fieldsLength.littleEndian) { ArraySlice($0) }
        #expect(throws: DBusProtocolError.arrayTooLong(DBusLimits.maximumArrayLength + 1)) {
            try DBusReceivedMessage.decode(huge)
        }
    }

    @Test("Unix descriptors declared in the header are refused")
    func unixFDs() throws {
        let call = DBusMessage.methodCall(destination: nil, path: "/a", interface: nil, member: "M")
        let encoded = try call.encoded(serial: 1, byteOrder: .littleEndian)
        // PATH and MEMBER end at 42; padding to 48, then UNIX_FDS = 1.
        var bytes = Array(encoded[0..<42]) + [0, 0, 0, 0, 0, 0] + [9, 1, UInt8(ascii: "u"), 0, 1, 0, 0, 0]
        bytes[12] = 40
        #expect(throws: DBusProtocolError.unixFDsNotNegotiated) { try DBusReceivedMessage.decode(bytes) }
        bytes[52] = 0
        #expect(try DBusReceivedMessage.decode(bytes) != nil)
    }

    @Test("decodeBody(expecting:) checks the signature before decoding")
    func expectingSignature() throws {
        let decoded = try #require(try DBusReceivedMessage.decode(sampleMessages[0].encoded(serial: 1)))
        #expect(try decoded.decodeBody(expecting: "b") == [.boolean(false)])
        #expect(throws: DBusProtocolError.signatureMismatch(expected: "s", actual: "b")) {
            try decoded.decodeBody(expecting: "s")
        }
    }

    @Test("An ERROR's name and message make its remote error")
    func remoteError() throws {
        let decoded = try #require(try DBusReceivedMessage.decode(sampleMessages[2].encoded(serial: 1)))
        #expect(decoded.remoteError == DBusRemoteError(name: "org.freedesktop.DBus.Error.AccessDenied", message: "No."))
        let call = try #require(try DBusReceivedMessage.decode(sampleMessages[0].encoded(serial: 1)))
        #expect(call.remoteError == nil)
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
