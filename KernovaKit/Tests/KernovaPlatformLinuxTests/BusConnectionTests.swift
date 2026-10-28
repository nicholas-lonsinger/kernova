#if os(Linux)
import KernovaDBus
import KernovaPlatformLinux
import Testing

@Suite("DBusBusConnection against a private dbus-daemon")
struct BusConnectionTests {
    static let serviceName = "org.kernova.Test"
    static let servicePath: DBusObjectPath = "/org/kernova/Test"
    static let serviceInterface = "org.kernova.Test"

    /// Echoes `Echo`'s arguments and fails `Fail`.
    static func service(_ call: DBusReceivedMessage) -> DBusMessage? {
        switch call.header.member {
        case "Echo": .methodReturn(replyingTo: call, body: (try? call.decodeBody()) ?? [])
        case "Fail": .error(replyingTo: call, name: "org.kernova.Test.Error.Failed", message: "As asked")
        default: .error(replyingTo: call, name: "org.freedesktop.DBus.Error.UnknownMethod", message: "")
        }
    }

    static func tick(_ label: String) -> DBusMessage {
        .signal(path: servicePath, interface: serviceInterface, member: "Tick", body: [.string(label)])
    }

    static let tickRule = DBusMatchRule(
        sender: serviceName, path: servicePath, interface: serviceInterface, member: "Tick")

    @Test("Hello gives each connection its own unique name")
    func hello() throws {
        let bus = try PrivateBus()
        let first = try bus.connect()
        let second = try bus.connect()
        #expect(first.uniqueName.hasPrefix(":"))
        #expect(first.uniqueName != second.uniqueName)
    }

    @Test("A call returns its reply; an ERROR reply throws its name and message")
    func callReplyAndError() throws {
        let bus = try PrivateBus()
        let service = try bus.connect(onMethodCall: Self.service)
        try requestName(Self.serviceName, on: service)
        let client = try bus.connect()

        let body: [DBusValue] = [
            .string("hi"), .uint32(5),
            .dictionary(
                key: .string, value: .variant, [(.string("k"), .variant(.array(elementType: .byte, [.byte(1)])))]),
        ]
        let reply = try client.call(
            .methodCall(
                destination: Self.serviceName, path: Self.servicePath, interface: Self.serviceInterface,
                member: "Echo", body: body))
        #expect(try reply.decodeBody() == body)
        #expect(reply.header.sender == service.uniqueName)

        #expect(
            throws: DBusCallError.remote(DBusRemoteError(name: "org.kernova.Test.Error.Failed", message: "As asked"))
        ) {
            try client.call(
                .methodCall(
                    destination: Self.serviceName, path: Self.servicePath, interface: Self.serviceInterface,
                    member: "Fail"))
        }
    }

    @Test("A connection with no method-call handler answers UnknownMethod")
    func unknownMethod() throws {
        let bus = try PrivateBus()
        let silent = try bus.connect()
        let client = try bus.connect()
        do {
            _ = try client.call(.methodCall(destination: silent.uniqueName, path: "/", interface: nil, member: "Hi"))
            Issue.record("The call returned")
        } catch DBusCallError.remote(let error) {
            #expect(error.name == "org.freedesktop.DBus.Error.UnknownMethod")
        }
    }

    @Test("The bus's own errors arrive as remote errors")
    func busError() throws {
        let bus = try PrivateBus()
        let client = try bus.connect()
        do {
            _ = try client.call(.methodCall(destination: "org.kernova.Nobody", path: "/", interface: nil, member: "Hi"))
            Issue.record("The call returned")
        } catch DBusCallError.remote(let error) {
            #expect(error.name == "org.freedesktop.DBus.Error.ServiceUnknown")
        }
    }

    @Test("A subscribed signal arrives from the name's owner, and a peer posing as it is ignored")
    func signals() throws {
        let bus = try PrivateBus()
        let service = try bus.connect(onMethodCall: Self.service)
        try requestName(Self.serviceName, on: service)
        let impostor = try bus.connect()
        let client = try bus.connect()
        let inbox = Inbox<String>()
        let subscription = try client.subscribe(Self.tickRule) { signal in
            if case .string(let label)? = try? signal.decodeBody().first {
                inbox.put(label)
            }
        }

        // Unicast to the client, which a bus delivers whatever its rules.
        var forged = Self.tick("forged")
        forged.header.destination = client.uniqueName
        try impostor.send(forged)
        try impostor.send(Self.tick("broadcast by another"))
        try sync(impostor)
        try service.send(Self.tick("real"))
        #expect(try inbox.next() == "real")

        // Once the bus has the RemoveMatch, nothing more is delivered; a second
        // subscription shows the stream still flows.
        subscription.cancel()
        try sync(client)
        try service.send(Self.tick("after cancel"))
        try sync(service)
        let after = Inbox<String>()
        let second = try client.subscribe(Self.tickRule) { signal in
            if case .string(let label)? = try? signal.decodeBody().first {
                after.put(label)
            }
        }
        try service.send(Self.tick("second"))
        #expect(try after.next() == "second")
        #expect(inbox.isEmpty)
        second.cancel()
    }

    @Test("A subscription follows the name to its next owner")
    func ownerChange() throws {
        let bus = try PrivateBus()
        let first = try bus.connect(onMethodCall: Self.service)
        try requestName(Self.serviceName, on: first)
        let client = try bus.connect()
        let inbox = Inbox<String>()
        let subscription = try client.subscribe(Self.tickRule) { signal in
            if case .string(let label)? = try? signal.decodeBody().first {
                inbox.put(label)
            }
        }
        try first.send(Self.tick("first"))
        #expect(try inbox.next() == "first")

        first.close()
        let next = try bus.connect(onMethodCall: Self.service)
        try requestName(Self.serviceName, on: next)
        try next.send(Self.tick("next"))
        #expect(try inbox.next() == "next")
        subscription.cancel()
    }

    @Test("Closing fails a call in progress and every later one")
    func close() throws {
        let bus = try PrivateBus()
        let client = try bus.connect()
        client.close()
        #expect(throws: DBusCallError.disconnected(.closed)) {
            try client.call(
                .methodCall(
                    destination: DBusBus.name, path: DBusBus.path, interface: DBusBus.interface, member: "GetId"))
        }
    }

    @Test("Connecting to an address nobody listens on throws")
    func noListener() {
        #expect(throws: DBusConnectError.self) {
            try DBusBusConnection(address: "unix:abstract=/kernova/nobody-listens-here")
        }
        #expect(throws: DBusConnectError.noConnectableAddress("tcp:host=127.0.0.1,port=1")) {
            try DBusBusConnection(address: "tcp:host=127.0.0.1,port=1")
        }
    }
}
#endif
