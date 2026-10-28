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
    @Suite("JudgedClock and JudgedDeadline: §5.2 rules 1–4")
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

        // MARK: Rule 1

        @Test("Rule 1: a step backwards charges nothing and moves neither clock")
        func backwardStepChargesNothing() {
            var clock = Self.clock()
            clock.advance(to: Unit.at(2_000))
            clock.advance(to: Unit.at(1_000))
            #expect(clock.raw == Unit.at(2_000))
            #expect(clock.judged == Unit.at(2_000))
            #expect(clock.lastInput == Unit.at(1_000))
        }

        @Test("Rule 1: after a step backwards, both clocks advance by each forward step from the caller's latest now")
        func forwardAfterBackward() {
            var clock = Self.clock()
            clock.advance(to: Unit.at(2_000))
            clock.advance(to: Unit.at(1_000))
            clock.advance(to: Unit.at(3_000))
            #expect(clock.raw == Unit.at(4_000))
            #expect(clock.judged == Unit.at(4_000))
        }

        @Test("external(_:) maps a raw instant back onto the caller's timeline")
        func externalMapsBack() {
            var clock = Self.clock()
            clock.advance(to: Unit.at(2_000))
            clock.advance(to: Unit.at(1_000))
            #expect(clock.external(Unit.at(5_000)) == Unit.at(4_000))
            #expect(clock.external(Unit.at(2_000)) == Unit.at(1_000))
            #expect(clock.external(nil) == nil)
        }

        // MARK: Rule 2

        @Test("Rule 2: while the far side is frozen judged time does not advance; raw time does")
        func frozenJudgesNothing() {
            var clock = Self.clock()
            clock.setFrozen(true)
            clock.advance(to: Unit.at(5_000))
            #expect(clock.raw == Unit.at(5_000))
            #expect(clock.judged == Unit.t0)
            clock.setFrozen(false)
            clock.advance(to: Unit.at(6_000))
            #expect(clock.judged == Unit.at(1_000))
        }

        @Test("Rule 2: a frozen clock evaluates no deadline, needs no wake, and restarts a confirmation")
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

        // MARK: Rule 3

        @Test("Rule 3: a step of at most 10 s is charged; a longer one charges 0 (this side was suspended)")
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

        // MARK: Rule 4

        @Test("Rule 4: a passed deadline fires only at a later evaluation at least 1 s of raw time on")
        func confirmedExpiry() {
            var clock = Self.clock()
            var deadline = JudgedDeadline(after: .seconds(3), on: clock, confirmation: .seconds(1))
            #expect(deadline.expiry == Unit.at(3_000))
            #expect(deadline.wake(clock) == Unit.at(3_000))
            var fired = Self.evaluations(&deadline, &clock, at: [2_999, 3_200])
            #expect(deadline.wake(clock) == Unit.at(4_200))
            fired += Self.evaluations(&deadline, &clock, at: [4_199, 4_200])
            #expect(fired == [false, false, false, true])
        }

        @Test("Rule 4: the confirmation runs on raw time, so it completes across a suspended step")
        func confirmationOnRawTime() {
            var clock = Self.clock()
            var deadline = JudgedDeadline(after: .seconds(3), on: clock, confirmation: .seconds(1))
            #expect(Self.evaluations(&deadline, &clock, at: [3_000, 60_000]) == [false, true])
        }

        @Test("A deadline's wake is the raw instant judged time reaches its expiry")
        func wakeTracksJudgedTime() {
            var clock = Self.clock()
            let deadline = JudgedDeadline(after: .seconds(15), on: clock, confirmation: .seconds(1))
            clock.advance(to: Unit.at(30_000))
            #expect(clock.judged == Unit.t0)
            #expect(deadline.wake(clock) == Unit.at(45_000))
        }

        // MARK: In a connection

        @Test("The Hello timeout fires 1 s after it is found passed, on judged time")
        func helloTimeoutConfirmed() {
            var wire = Wire.host()
            for step: Int64 in [5_000, 10_000, 10_500] {
                wire.advance(to: Unit.at(step))
                #expect(wire.connection.state == .handshaking)
            }
            wire.advance(to: Unit.at(11_000))
            #expect(wire.connection.state == .closing)
            #expect(
                wire.takeEvents().contains { event in
                    if case .closed(.closedLocally(let error)) = event { return error.code == .helloTimeout }
                    return false
                })
        }

        @Test("A suspended step charges nothing toward the Hello timeout")
        func helloTimeoutSkipsSuspension() {
            var wire = Wire.peer()
            for step: Int64 in [5_000, 65_000, 69_000, 70_000] {
                wire.advance(to: Unit.at(step))
                #expect(wire.connection.state == .handshaking)
            }
            wire.advance(to: Unit.at(71_000))
            #expect(wire.connection.state == .closing)
        }

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
