#if os(Linux)
import Foundation
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

    /// A handler putting each signal's first argument into `inbox`.
    static func collect(into inbox: Inbox<String>) -> @Sendable (DBusReceivedMessage) -> Void {
        { signal in
            if case .string(let label)? = try? signal.decodeBody().first {
                inbox.put(label)
            }
        }
    }

    @Test("A subscribed signal arrives from the name's owner only; a peer posing as the owner is ignored")
    func signals() throws {
        let bus = try PrivateBus()
        let service = try bus.connect(onMethodCall: Self.service)
        try requestName(Self.serviceName, on: service)
        let impostor = try bus.connect()
        let client = try bus.connect()
        let inbox = Inbox<String>()
        let subscription = try client.subscribe(Self.tickRule, handler: Self.collect(into: inbox))
        // Names no sender, so it shows what the bus delivered to the client.
        let witness = Inbox<String>()
        let witnessRule = DBusMatchRule(path: Self.servicePath, interface: Self.serviceInterface, member: "Tick")
        let witnessing = try client.subscribe(witnessRule, handler: Self.collect(into: witness))

        // A NameOwnerChanged naming the impostor the name's owner, broadcast
        // and unicast; a bus delivers a unicast signal whatever the rules.
        var takeover = DBusMessage.signal(
            path: DBusBus.path, interface: DBusBus.interface, member: "NameOwnerChanged",
            body: [.string(Self.serviceName), .string(service.uniqueName), .string(impostor.uniqueName)])
        try impostor.send(takeover)
        takeover.header.destination = client.uniqueName
        try impostor.send(takeover)
        var forged = Self.tick("forged unicast")
        forged.header.destination = client.uniqueName
        try impostor.send(forged)
        try impostor.send(Self.tick("forged broadcast"))
        try sync(impostor)
        try service.send(Self.tick("real"))
        #expect(try inbox.next() == "real")
        #expect(inbox.isEmpty)
        #expect(
            try [witness.next(), witness.next(), witness.next()] == ["forged unicast", "forged broadcast", "real"])
        witnessing.cancel()

        // A cancelled subscription's handler is never called again; a second
        // subscription shows the stream still flows. The round trip puts the
        // RemoveMatch ahead of the next Tick, so the second subscription
        // cannot receive it.
        subscription.cancel()
        try sync(client)
        try service.send(Self.tick("after cancel"))
        try sync(service)
        let after = Inbox<String>()
        let second = try client.subscribe(Self.tickRule, handler: Self.collect(into: after))
        try service.send(Self.tick("second"))
        #expect(try after.next() == "second")
        #expect(inbox.isEmpty)
        second.cancel()
    }

    @Test("A subscription made before the name has an owner gets the owner's signals once it takes the name")
    func noOwnerYet() throws {
        let bus = try PrivateBus()
        let client = try bus.connect()
        let inbox = Inbox<String>()
        let subscription = try client.subscribe(Self.tickRule, handler: Self.collect(into: inbox))
        let service = try bus.connect(onMethodCall: Self.service)
        try service.send(Self.tick("before"))
        try requestName(Self.serviceName, on: service)
        try service.send(Self.tick("after"))
        #expect(try inbox.next() == "after")
        #expect(inbox.isEmpty)
        subscription.cancel()
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

    /// `service`, plus `Hang`, which reports its arrival to `arrived` and
    /// answers nothing once `release` lets it go, and `Silent`, which answers
    /// nothing at once.
    static func stalling(arrived: Inbox<String>, release: Inbox<String>)
        -> @Sendable (DBusReceivedMessage) -> DBusMessage?
    {
        { call in
            switch call.header.member {
            case "Hang":
                arrived.put("arrived")
                _ = try? release.next()
                return nil
            case "Silent":
                return nil
            default:
                return service(call)
            }
        }
    }

    static func serviceCall(_ member: String, _ body: [DBusValue] = []) -> DBusMessage {
        .methodCall(
            destination: serviceName, path: servicePath, interface: serviceInterface, member: member, body: body)
    }

    /// Makes `call` on another thread, putting how it failed into the inbox
    /// returned, or nil if it returned.
    static func callElsewhere(_ connection: DBusBusConnection, _ call: DBusMessage) -> Inbox<DBusCallError?> {
        let outcome = Inbox<DBusCallError?>()
        Thread {
            do throws(DBusCallError) {
                _ = try connection.call(call)
                outcome.put(nil)
            } catch {
                outcome.put(error)
            }
        }.start()
        return outcome
    }

    @Test("Closing fails a call in progress, and every later one")
    func closeDuringCall() throws {
        let bus = try PrivateBus()
        let arrived = Inbox<String>()
        let release = Inbox<String>()
        let service = try bus.connect(onMethodCall: Self.stalling(arrived: arrived, release: release))
        defer { release.put("go") }
        try requestName(Self.serviceName, on: service)
        let client = try bus.connect()
        let outcome = Self.callElsewhere(client, Self.serviceCall("Hang"))
        #expect(try arrived.next() == "arrived")
        client.close()
        #expect(try outcome.next() == .disconnected(.closed))
        #expect(throws: DBusCallError.disconnected(.closed)) {
            try client.call(
                .methodCall(
                    destination: DBusBus.name, path: DBusBus.path, interface: DBusBus.interface, member: "GetId"))
        }
    }

    @Test("A bus that goes away fails the call in progress with the end of the stream")
    func busGoneDuringCall() throws {
        let bus = try PrivateBus()
        let arrived = Inbox<String>()
        let release = Inbox<String>()
        let service = try bus.connect(onMethodCall: Self.stalling(arrived: arrived, release: release))
        defer { release.put("go") }
        try requestName(Self.serviceName, on: service)
        let client = try bus.connect()
        let outcome = Self.callElsewhere(client, Self.serviceCall("Hang"))
        #expect(try arrived.next() == "arrived")
        bus.killDaemon()
        #expect(try outcome.next() == .disconnected(.endOfStream))
    }

    @Test("A call that times out throws, and the connection still answers the next call with its own reply")
    func timeout() throws {
        let bus = try PrivateBus()
        let release = Inbox<String>()
        let service = try bus.connect(onMethodCall: Self.stalling(arrived: Inbox<String>(), release: release))
        try requestName(Self.serviceName, on: service)
        let client = try bus.connect()
        #expect(throws: DBusCallError.timedOut) {
            try client.call(Self.serviceCall("Silent"), timeout: .milliseconds(200))
        }
        let reply = try client.call(Self.serviceCall("Echo", [.string("after the timeout")]))
        #expect(try reply.decodeBody() == [.string("after the timeout")])
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
