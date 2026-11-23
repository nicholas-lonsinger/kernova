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
#endif
