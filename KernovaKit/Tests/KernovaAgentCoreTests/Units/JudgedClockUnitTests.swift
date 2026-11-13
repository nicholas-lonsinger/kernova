#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@testable import KernovaAgentCore
import KernovaAgentSimulation
import KernovaWire
import Testing

extension CoreUnits {
    @Suite("JudgedClock and JudgedDeadline")
    struct JudgedClockUnitTests {
        static func clock() -> JudgedClock {
            JudgedClock(now: Unit.t0, suspendedStep: .seconds(10))
        }

        /// Advances `clock` to each instant in turn and records whether `deadline` fires there.
        static func evaluations(
            _ deadline: inout JudgedDeadline, _ clock: inout JudgedClock, at instants: [Int64]
        ) -> [Bool] {
            instants.map { milliseconds in
                clock.advance(to: Unit.at(milliseconds))
                return deadline.evaluate(clock)
            }
        }

        // MARK: A frozen far side

        @Test("A frozen clock evaluates no deadline, needs no wake, and restarts a confirmation")
        func frozenDeadline() {
            var clock = Self.clock()
            var deadline = JudgedDeadline(after: .seconds(3), on: clock, confirmation: .seconds(1))
            var fired = Self.evaluations(&deadline, &clock, at: [3_000])
            #expect(deadline.wake(clock) == Unit.at(4_000))
            clock.setFrozen(true)
            fired.append(deadline.evaluate(clock))
            #expect(deadline.wake(clock) == nil)
            fired += Self.evaluations(&deadline, &clock, at: [10_000])
            clock.setFrozen(false)
            fired.append(deadline.evaluate(clock))
            fired += Self.evaluations(&deadline, &clock, at: [10_900, 11_000])
            #expect(fired == [false, false, false, false, false, true])
        }

        // MARK: Suspension

        @Test("A forward step of at most 10 s is charged; a longer one charges 0 (this side was suspended)")
        func suspendedStep() {
            var clock = Self.clock()
            clock.advance(to: Unit.at(10_000))
            #expect(clock.judged == Unit.at(10_000))
            clock.advance(to: Unit.at(20_001))
            #expect(clock.raw == Unit.at(20_001))
            #expect(clock.judged == Unit.at(10_000))
            clock.advance(to: Unit.at(21_001))
            #expect(clock.judged == Unit.at(11_000))
        }

        // MARK: In a connection

        @Test(
            "A backward clock step charges nothing and stops no PING; deadlines stay on the caller's timeline"
        )
        func backwardStepKeepsPinging() {
            var wire = Wire.host()
            wire.establish()
            wire.advance(to: Unit.at(3_000))
            #expect(wire.flush().isEmpty)
            wire.advance(to: Unit.at(2_000))
            #expect(wire.connection.nextDeadline == Unit.at(3_000))
            wire.advance(to: Unit.at(3_000))
            #expect(wire.flush().shape == ["0:ping"])
            #expect(wire.connection.clock.judged == Unit.at(4_000))
        }

        @Test("Freezing the far side queues no PING and judges nothing; unfreezing queues a PING at once")
        func frozenPeer() {
            var wire = Wire.host()
            wire.establish()
            wire.connection.setPeerFrozen(true, now: wire.now)
            for second in stride(from: Int64(5), through: 120, by: 5) {
                wire.advance(to: Unit.at(second * 1_000))
            }
            #expect(wire.flush().isEmpty)
            #expect(wire.connection.state == .established)
            #expect(!wire.takeEvents().contains { if case .liveness = $0 { true } else { false } })
            wire.connection.setPeerFrozen(false, now: Unit.at(120_500))
            #expect(wire.flush().shape == ["0:ping"])
            #expect(wire.connection.clock.judged == Unit.t0)
        }
    }
}
