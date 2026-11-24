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
    @Test("decodeBody(expecting:) checks the signature before decoding")
    func expectingSignature() throws {
        let decoded = try #require(try DBusReceivedMessage.decode(sampleMessages[0].encoded(serial: 1)))
        #expect(try decoded.decodeBody(expecting: "b") == [.boolean(false)])
        #expect(throws: DBusProtocolError.signatureMismatch(expected: "s", actual: "b")) {
            try decoded.decodeBody(expecting: "s")
        }
    }
}
