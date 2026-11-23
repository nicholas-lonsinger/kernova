#if os(Linux)
import Foundation
import KernovaDBus
import KernovaPlatformLinux
import KernovaPortableTestSupport
import Testing

@Suite("DBusBusConnection against a private dbus-daemon", .offTaskWaitsReported)
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

    /// A handler putting each signal's first argument into `inbox`.
    static func collect(into inbox: BlockingInbox<String>) -> @Sendable (DBusReceivedMessage) -> Void {
        { signal in
            if case .string(let label)? = try? signal.decodeBody().first {
                inbox.put(label)
            }
        }
    }

    @Test("A subscribed signal arrives from the name's owner only; a peer posing as the owner is ignored")
    func signals() async throws {
        try await PrivateBus.with { bus in
            let service = try bus.connect(onMethodCall: Self.service)
            try requestName(Self.serviceName, on: service)
            let impostor = try bus.connect()
            let client = try bus.connect()
            let inbox = BlockingInbox<String>()
            let subscription = try client.subscribe(Self.tickRule, handler: Self.collect(into: inbox))
            // Names no sender, so it shows what the bus delivered to the client.
            let witness = BlockingInbox<String>()
            let witnessRule = DBusMatchRule(path: Self.servicePath, interface: Self.serviceInterface, member: "Tick")
            let witnessing = try client.subscribe(witnessRule, handler: Self.collect(into: witness))

            // A NameOwnerChanged naming the impostor the name's owner, broadcast
            // and unicast; a bus delivers a unicast signal whatever the rules.
            var takeover = DBusMessage.signal(
                path: DBusBus.path, interface: DBusBus.interface, member: "NameOwnerChanged",
                body: [.string(Self.serviceName), .string(service.uniqueName), .string(impostor.uniqueName)])
            try impostor.sendForTesting(takeover)
            takeover.header.destination = client.uniqueName
            try impostor.sendForTesting(takeover)
            var forged = Self.tick("forged unicast")
            forged.header.destination = client.uniqueName
            try impostor.sendForTesting(forged)
            try impostor.sendForTesting(Self.tick("forged broadcast"))
            try sync(impostor)
            try service.sendForTesting(Self.tick("real"))
            #expect(try await inbox.next() == "real")
            #expect(inbox.isEmpty)
            #expect(
                try await [witness.next(), witness.next(), witness.next()] == [
                    "forged unicast", "forged broadcast", "real",
                ])
            witnessing.cancel()

            // A cancelled subscription's handler is never called again; a second
            // subscription shows the stream still flows. The round trip puts the
            // RemoveMatch ahead of the next Tick, so the second subscription
            // cannot receive it.
            subscription.cancel()
            try sync(client)
            try service.sendForTesting(Self.tick("after cancel"))
            try sync(service)
            let after = BlockingInbox<String>()
            let second = try client.subscribe(Self.tickRule, handler: Self.collect(into: after))
            try service.sendForTesting(Self.tick("second"))
            #expect(try await after.next() == "second")
            #expect(inbox.isEmpty)
            second.cancel()
        }
    }

    @Test("A subscription follows the name to its next owner")
    func ownerChange() async throws {
        try await PrivateBus.with { bus in
            var first: DBusBusConnection? = try bus.connect(onMethodCall: Self.service)
            try requestName(Self.serviceName, on: try #require(first))
            let client = try bus.connect()
            let inbox = BlockingInbox<String>()
            let subscription = try client.subscribe(Self.tickRule) { signal in
                if case .string(let label)? = try? signal.decodeBody().first {
                    inbox.put(label)
                }
            }
            try #require(first).sendForTesting(Self.tick("first"))
            #expect(try await inbox.next() == "first")

            // Its last reference gone, the first owner's connection ends.
            first = nil
            let next = try bus.connect(onMethodCall: Self.service)
            try requestName(Self.serviceName, on: next)
            try next.sendForTesting(Self.tick("next"))
            #expect(try await inbox.next() == "next")
            subscription.cancel()
        }
    }

    /// `service`, plus `Hang`, which reports its arrival to `arrived` and
    /// answers nothing once `release` lets it go, and `Silent`, which answers
    /// nothing at once.
    static func stalling(arrived: BlockingInbox<String>, release: BlockingInbox<String>)
        -> @Sendable (DBusReceivedMessage) -> DBusMessage?
    {
        let waits = OffTaskWaits()
        return { call in
            switch call.header.member {
            case "Hang":
                arrived.put("arrived")
                waits.run { _ = try release.next() }
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
    static func callElsewhere(_ connection: DBusBusConnection, _ call: DBusMessage) -> BlockingInbox<DBusCallError?> {
        let outcome = BlockingInbox<DBusCallError?>()
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

    @Test("A call that times out throws, and the connection still answers the next call with its own reply")
    func timeout() async throws {
        try await PrivateBus.with { bus in
            let release = BlockingInbox<String>()
            let service = try bus.connect(
                onMethodCall: Self.stalling(arrived: BlockingInbox<String>(), release: release))
            try requestName(Self.serviceName, on: service)
            let client = try bus.connect()
            #expect(throws: DBusCallError.timedOut) {
                try client.call(Self.serviceCall("Silent"), timeout: .milliseconds(200))
            }
            let reply = try client.call(Self.serviceCall("Echo", [.string("after the timeout")]))
            #expect(try reply.decodeBody() == [.string("after the timeout")])
        }
    }
}
#endif
