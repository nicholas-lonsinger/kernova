#if os(Linux)
import Foundation
import KernovaDBus
import KernovaPlatformLinux
import Testing

@Suite("Handlers run only while their subscription and connection stand")
struct DeliveryTests {
    /// A service owning the test name, a client subscribed to its Ticks, and
    /// the bus they share.
    struct Setup {
        let bus: PrivateBus
        let service: DBusBusConnection
        let client: DBusBusConnection

        init() throws {
            bus = try PrivateBus()
            service = try bus.connect(onMethodCall: BusConnectionTests.service)
            try requestName(BusConnectionTests.serviceName, on: service)
            client = try bus.connect()
        }

        func tick(_ label: String) throws {
            try service.send(BusConnectionTests.tick(label))
        }
    }

    @Test("A subscription cancelled while another's handler runs is not called for that signal")
    func cancelledBeforeItsTurn() throws {
        let setup = try Setup()
        let events = Inbox<String>()
        let gate = Inbox<String>()
        let first = try setup.client.subscribe(BusConnectionTests.tickRule) { signal in
            guard case .string(let label)? = try? signal.decodeBody().first else { return }
            events.put("first \(label)")
            if label == "one" {
                _ = try? gate.next()
            }
        }
        let later = Inbox<String>()
        let second = try setup.client.subscribe(
            BusConnectionTests.tickRule, handler: BusConnectionTests.collect(into: later))

        try setup.tick("one")
        #expect(try events.next() == "first one")
        second.cancel()
        gate.put("go")
        try setup.tick("two")
        #expect(try events.next() == "first two")
        // The reader delivers in order, so "one" would have reached the second
        // handler before "two" reached the first.
        #expect(later.isEmpty)
        first.cancel()
    }

    @Test("cancel() returns only once its handler has finished", arguments: [false, true])
    func cancelWaitsForTheHandler(byClosing: Bool) throws {
        let setup = try Setup()
        let events = Inbox<String>()
        let gate = Inbox<String>()
        let subscription = try setup.client.subscribe(BusConnectionTests.tickRule) { _ in
            events.put("started")
            _ = try? gate.next()
            events.put("finished")
        }
        try setup.tick("one")
        #expect(try events.next() == "started")
        let client = setup.client
        Thread {
            if byClosing {
                client.close()
            } else {
                subscription.cancel()
            }
            events.put("returned")
        }.start()
        gate.put("go")
        #expect(try [events.next(), events.next()] == ["finished", "returned"])
    }

    @Test("A handler may cancel its own subscription, and close its own connection, without waiting on itself")
    func cancelFromTheHandler() throws {
        let setup = try Setup()
        let events = Inbox<String>()
        let box = SubscriptionBox()
        let client = setup.client
        box.subscription = try client.subscribe(BusConnectionTests.tickRule) { _ in
            box.subscription?.cancel()
            client.close()
            events.put("handled")
        }
        try setup.tick("one")
        #expect(try events.next() == "handled")
    }

    @Test("Once the bus is gone, a call from any later thread fails as disconnected")
    func laterThreadsAfterTheReader() throws {
        let setup = try Setup()
        setup.bus.killDaemon()
        let client = setup.client
        // A thread started after the reader exits may be given its pthread_t.
        for _ in 0..<8 {
            let outcome = try BusConnectionTests.callElsewhere(client, BusConnectionTests.serviceCall("Echo")).next()
            guard case .disconnected? = outcome else {
                Issue.record("The call ended with \(String(describing: outcome))")
                return
            }
        }
    }
}

/// Holds a subscription its own handler reaches.
final class SubscriptionBox: @unchecked Sendable {
    var subscription: DBusSubscription?
}
#endif
