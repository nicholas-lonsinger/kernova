#if os(Linux)
import Foundation
import KernovaDBus
import KernovaPlatformLinux
import KernovaPortableTestSupport
import Testing

@Suite("Handlers run only while their subscription and connection stand", .offTaskWaitsReported)
struct DeliveryTests {
    /// A service owning the test name, a client subscribed to its Ticks, and
    /// the bus they share.
    struct Setup {
        let bus: PrivateBus
        let service: DBusBusConnection
        let client: DBusBusConnection

        /// Runs `body` with a setup on a bus of its own, for the length of a ``PrivateBus/with(_:)``.
        static func with(_ body: (Setup) async throws -> Void) async throws {
            try await PrivateBus.with { bus in try await body(try Setup(on: bus)) }
        }

        private init(on bus: PrivateBus) throws {
            self.bus = bus
            service = try bus.connect(onMethodCall: BusConnectionTests.service)
            try requestName(BusConnectionTests.serviceName, on: service)
            client = try bus.connect()
        }

        func tick(_ label: String) throws {
            try service.sendForTesting(BusConnectionTests.tick(label))
        }
    }

    @Test("A subscription cancelled while another's handler runs is not called for that signal")
    func cancelledBeforeItsTurn() async throws {
        try await Setup.with { setup in
            let events = BlockingInbox<String>()
            let gate = BlockingInbox<String>()
            let waits = OffTaskWaits()
            let first = try setup.client.subscribe(BusConnectionTests.tickRule) { signal in
                guard case .string(let label)? = try? signal.decodeBody().first else { return }
                events.put("first \(label)")
                if label == "one" {
                    waits.run { _ = try gate.next() }
                }
            }
            let later = BlockingInbox<String>()
            let second = try setup.client.subscribe(
                BusConnectionTests.tickRule, handler: BusConnectionTests.collect(into: later))

            try setup.tick("one")
            #expect(try await events.next() == "first one")
            second.cancel()
            gate.put("go")
            try setup.tick("two")
            #expect(try await events.next() == "first two")
            // The reader delivers in order, so "one" would have reached the second
            // handler before "two" reached the first.
            #expect(later.isEmpty)
            first.cancel()
        }
    }

    @Test(
        "cancel() and releasing the connection wait for the handler in flight, and return once it has finished",
        arguments: [false, true])
    func cancelWaitsForTheHandler(byReleasing: Bool) async throws {
        try await Setup.with { setup in
            let events = BlockingInbox<String>()
            let gate = BlockingInbox<String>()
            let waits = OffTaskWaits()
            // The box holds the client's only reference, so emptying it ends the
            // connection on the thread that does.
            let held = ConnectionBox(try setup.bus.connect())
            held.connection?.observeDeliveryWaitsForTesting { events.put("waiting") }
            let subscription = try #require(
                try held.connection?.subscribe(BusConnectionTests.tickRule) { _ in
                    events.put("started")
                    waits.run { _ = try gate.next() }
                    events.put("finished")
                })
            try setup.tick("one")
            #expect(try await events.next() == "started")
            Thread {
                if byReleasing {
                    held.connection = nil
                } else {
                    subscription.cancel()
                }
                events.put("returned")
            }.start()
            // The handler is held at the gate, so a caller that did not wait would
            // put "returned" here instead.
            try #require(try await events.next() == "waiting")
            gate.put("go")
            #expect(try await [events.next(), events.next()] == ["finished", "returned"])
        }
    }

    @Test(
        "A handler may cancel its own subscription, and release its connection's last reference, without waiting on itself"
    )
    func cancelFromTheHandler() async throws {
        try await Setup.with { setup in
            let events = BlockingInbox<String>()
            let box = SubscriptionBox()
            let held = ConnectionBox(try setup.bus.connect())
            box.subscription = try held.connection?.subscribe(BusConnectionTests.tickRule) { _ in
                box.subscription?.cancel()
                held.connection = nil
                events.put("handled")
            }
            try setup.tick("one")
            #expect(try await events.next() == "handled")
        }
    }

    @Test("Once the bus is gone, a call from any later thread fails as disconnected")
    func laterThreadsAfterTheReader() async throws {
        try await Setup.with { setup in
            await setup.bus.killDaemon()
            let client = setup.client
            // A thread started after the reader exits may be given its pthread_t.
            for _ in 0..<8 {
                let outcome = try await BusConnectionTests.callElsewhere(client, BusConnectionTests.serviceCall("Echo"))
                    .next()
                guard case .disconnected? = outcome else {
                    Issue.record("The call ended with \(String(describing: outcome))")
                    return
                }
            }
        }
    }
}

/// Holds a subscription its own handler reaches.
final class SubscriptionBox: @unchecked Sendable {
    var subscription: DBusSubscription?
}

/// Holds a connection's only reference, for a test that ends the connection
/// by letting that reference go.
final class ConnectionBox: @unchecked Sendable {
    var connection: DBusBusConnection?

    init(_ connection: DBusBusConnection) {
        self.connection = connection
    }
}
#endif
