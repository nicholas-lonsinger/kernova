import Testing
import Foundation
import KernovaTestSupport

@testable import KernovaKit

@Suite("ControlLivenessMonitor")
struct ControlLivenessMonitorTests {
    /// Windows wide apart so a test can sit between them unambiguously.
    private static let cadence = ControlChannelCadence(
        heartbeatInterval: 1, unresponsiveAfter: 10, terminateAfter: 20)

    private func makeMonitor() -> (ControlLivenessMonitor, TestEngineClock) {
        (ControlLivenessMonitor(cadence: Self.cadence), TestEngineClock())
    }

    @Test("A channel that never spoke is not judged silent")
    func noSignalBeforeAnyFrame() {
        let (monitor, clock) = makeMonitor()

        clock.advance(seconds: 600)

        #expect(monitor.evaluate(at: clock.now) == .noSignal)
        #expect(!monitor.isUnresponsive)
    }

    @Test("Silence inside the unresponsive window changes nothing")
    func healthyInsideTheWindow() {
        let (monitor, clock) = makeMonitor()
        monitor.record(at: clock.now)

        clock.advance(seconds: 9)

        #expect(monitor.evaluate(at: clock.now) == .unchanged)
        #expect(!monitor.isUnresponsive)
    }

    @Test("Crossing the unresponsive window reports the silence once")
    func becomesUnresponsiveOnlyOnce() {
        let (monitor, clock) = makeMonitor()
        monitor.record(at: clock.now)

        clock.advance(seconds: 11)
        #expect(monitor.evaluate(at: clock.now) == .becameUnresponsive(silentFor: 11))
        #expect(monitor.isUnresponsive)

        // Still silent, still inside the terminate window: no second edge.
        clock.advance(seconds: 1)
        #expect(monitor.evaluate(at: clock.now) == .unchanged)
        #expect(monitor.isUnresponsive)
    }

    @Test("A recorded frame is what leaves the unresponsive stage")
    func recordRecovers() {
        let (monitor, clock) = makeMonitor()
        monitor.record(at: clock.now)
        clock.advance(seconds: 11)
        #expect(monitor.evaluate(at: clock.now) == .becameUnresponsive(silentFor: 11))

        #expect(monitor.record(at: clock.now) == .recovered)
        #expect(!monitor.isUnresponsive)

        // The recovery edge fires once, and the refreshed deadline holds.
        #expect(monitor.record(at: clock.now) == .unchanged)
        clock.advance(seconds: 9)
        #expect(monitor.evaluate(at: clock.now) == .unchanged)
    }

    @Test("A peer that was never unresponsive does not recover")
    func recordDoesNotRecoverAHealthyPeer() {
        let (monitor, clock) = makeMonitor()

        #expect(monitor.record(at: clock.now) == .unchanged)
        clock.advance(seconds: 5)
        #expect(monitor.record(at: clock.now) == .unchanged)
    }

    @Test("An evaluation back inside the window leaves the unresponsive stage")
    func evaluateRecovers() {
        let (monitor, clock) = makeMonitor()
        monitor.record(at: clock.now)
        clock.advance(seconds: 11)
        #expect(monitor.evaluate(at: clock.now) == .becameUnresponsive(silentFor: 11))

        // `evaluate` is total over the monitor's own state, so an evaluation
        // point inside the window lifts the stage. Both peers evaluate at
        // `clock.now` against a monotonic instant and leave the stage through
        // `record`/`hold` instead, so this arm answers for the type rather than
        // for a path either peer takes.
        let insideTheWindow = EngineInstant(nanoseconds: clock.now.nanoseconds - 10_000_000_000)
        #expect(monitor.evaluate(at: insideTheWindow) == .recovered)
        #expect(!monitor.isUnresponsive)
    }

    @Test("A hold never stands in for the first signal")
    func holdBeforeAnySignalRecordsNothing() {
        let (monitor, clock) = makeMonitor()

        // A guest live-paused before it ever spoke: every tick holds, and none
        // of them may arm a deadline the peer would then be judged against.
        for _ in 0..<5 {
            clock.advance(seconds: 30)
            #expect(monitor.hold(at: clock.now) == .noSignal)
        }

        // Resumed, and still judged as never having spoken.
        clock.advance(seconds: 30)
        #expect(monitor.evaluate(at: clock.now) == .noSignal)
    }

    @Test("A hold defers the deadline of a peer that has spoken")
    func holdDefersTheDeadline() {
        let (monitor, clock) = makeMonitor()
        monitor.record(at: clock.now)

        // Held every 9 s across three terminate windows.
        for _ in 0..<7 {
            clock.advance(seconds: 9)
            #expect(monitor.hold(at: clock.now) == .unchanged)
        }

        #expect(monitor.evaluate(at: clock.now) == .unchanged)
    }

    @Test("A hold lifts the unresponsive stage of a peer it starts judging again")
    func holdRecovers() {
        let (monitor, clock) = makeMonitor()
        monitor.record(at: clock.now)
        clock.advance(seconds: 11)
        #expect(monitor.evaluate(at: clock.now) == .becameUnresponsive(silentFor: 11))

        #expect(monitor.hold(at: clock.now) == .recovered)
        #expect(!monitor.isUnresponsive)
    }

    @Test("Silence past the terminate window expires with its measured span")
    func expiresPastTerminate() {
        let (monitor, clock) = makeMonitor()
        monitor.record(at: clock.now)

        clock.advance(seconds: 21)

        #expect(monitor.evaluate(at: clock.now) == .expired(silentFor: 21))
    }

    @Test("Expiry outranks the unresponsive stage from a standing start")
    func expiresWithoutPassingThroughUnresponsive() {
        let (monitor, clock) = makeMonitor()
        monitor.record(at: clock.now)

        clock.advance(seconds: 60)

        #expect(monitor.evaluate(at: clock.now) == .expired(silentFor: 60))
        #expect(!monitor.isUnresponsive)
    }

    @Test("Reset drops the recorded signal and the unresponsive stage")
    func resetForgetsEverything() {
        let (monitor, clock) = makeMonitor()
        monitor.record(at: clock.now)
        clock.advance(seconds: 11)
        #expect(monitor.evaluate(at: clock.now) == .becameUnresponsive(silentFor: 11))

        monitor.reset()

        #expect(!monitor.isUnresponsive)
        clock.advance(seconds: 600)
        #expect(monitor.evaluate(at: clock.now) == .noSignal)
    }
}
