#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaAgentRuntime
import KernovaWire
import Testing

/// A committed pull's end can follow its connection's: the driver keeps running inputs for it, and ends only
/// once it has.
@Suite("Connection driver: landings in flight")
struct DriverLandingTests {
    @Test("A connection that finishes with a landing in flight shuts the stream at once and ends after its report")
    func endsAfterTheLanding() async {
        let stream = ScriptedStream()
        let ended = Recorder<ConnectionClosure>()
        let events = Recorder<String>()
        let driver = ConnectionDriver(
            endpoint: LandingEndpoint(), stream: stream, scheduler: ManualScheduler(now: Fixture.t0),
            logger: Fixture.logger,
            handlers: ConnectionDriver<LandingEndpoint>.Handlers(
                event: { event, _ in events.record(event) }, ended: { closure, _ in ended.record(closure) }))
        driver.start()
        await flush(driver.queue)

        driver.handle(.finishWithLandingInFlight)
        await flush(driver.queue)
        #expect(stream.shutdowns == 1)
        #expect(events.elements == ["closed"])
        #expect(ended.elements.isEmpty)

        driver.handle(.publishReported)
        await flush(driver.queue)
        #expect(events.elements == ["closed", "pullEnded"])
        #expect(ended.elements == [.transportLost])
        #expect(stream.shutdowns == 1)

        driver.handle(.publishReported)
        await flush(driver.queue)
        #expect(events.elements.count == 2)
        #expect(ended.elements.count == 1)
    }
}

/// An endpoint whose connection finishes, and whose one landing reports, when a test says.
struct LandingEndpoint: DrivenEndpoint {
    enum Input: Sendable {
        /// The connection finishes with a committed pull's report outstanding.
        case finishWithLandingInFlight
        /// The sink reports the publish: the pull ends.
        case publishReported
    }

    let generation = ConnectionGeneration(rawValue: 1)
    private(set) var state = ConnectionState.established
    private(set) var hasLandingsInFlight = false
    private var events: [String] = []

    var nextDeadline: CoreInstant? { nil }

    mutating func receive(_ bytes: Data, now: CoreInstant) {}
    mutating func finalTransmitWritten(now: CoreInstant) {}
    mutating func transportEnded(now: CoreInstant) {}
    mutating func handleTimeout(now: CoreInstant) {}
    mutating func close(_ code: ErrorCode, now: CoreInstant) {}

    mutating func handle(_ input: Input, now: CoreInstant) {
        switch input {
        case .finishWithLandingInFlight:
            state = .finished
            hasLandingsInFlight = true
            events.append("closed")
        case .publishReported:
            guard hasLandingsInFlight else { return }
            hasLandingsInFlight = false
            events.append("pullEnded")
        }
    }

    mutating func pollTransmit(maxBytes: Int) -> Transmit? { nil }
    mutating func pollEffect() -> Never? { nil }

    mutating func pollEvent() -> String? {
        events.isEmpty ? nil : events.removeFirst()
    }

    static func diagnostic(in event: String) -> Diagnostic? { nil }
    static func closure(in event: String) -> ConnectionClosure? { event == "closed" ? .transportLost : nil }
}
