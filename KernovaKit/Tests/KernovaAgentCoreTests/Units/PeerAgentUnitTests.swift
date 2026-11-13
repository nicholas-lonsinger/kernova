#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaWire
import Testing

extension CoreUnits {
    @Suite("PeerAgent: the dial schedule")
    struct PeerAgentUnitTests {
        /// An agent driven on a timeline of milliseconds, with what it asked for so far.
        struct Driver {
            var agent: PeerAgent
            var now: Int64 = 0
            var effects: [AgentEffect] = []

            init(parked: Bool = false) {
                agent = PeerAgent(now: Unit.at(0), parked: parked)
                collect()
            }

            mutating func park() {
                agent.park(now: Unit.at(now))
                collect()
            }

            mutating func unpark() {
                agent.unpark(now: Unit.at(now))
                collect()
            }

            mutating func collect() {
                while let effect = agent.pollEffect() { effects.append(effect) }
            }

            /// Milliseconds from now to the agent's next deadline.
            var wait: Int64? {
                agent.nextDeadline.map { Unit.at(now).duration(to: $0).milliseconds }
            }

            mutating func step(to milliseconds: Int64) {
                now = milliseconds
                agent.handleTimeout(now: Unit.at(now))
                collect()
            }

            /// Fails the pending dial, then runs to the next one; the delays waited.
            mutating func failDials(_ count: Int) -> [Int64] {
                (0..<count).map { _ in
                    agent.dialFailed(.transient, now: Unit.at(now))
                    let delay = wait ?? -1
                    step(to: now + delay)
                    return delay / 1_000
                }
            }

            mutating func connect(after milliseconds: Int64 = 0) -> ConnectionGeneration {
                now += milliseconds
                guard let generation = agent.dialSucceeded(now: Unit.at(now)) else {
                    Issue.record("a running agent refused a connected dial")
                    return ConnectionGeneration(rawValue: 0)
                }
                return generation
            }

            mutating func policy(_ generation: ConnectionGeneration, after milliseconds: Int64) {
                now += milliseconds
                agent.policyReceived(generation, now: Unit.at(now))
            }

            mutating func end(
                _ generation: ConnectionGeneration, _ closure: ConnectionClosure, after milliseconds: Int64
            ) {
                now += milliseconds
                agent.connectionEnded(generation, closure, now: Unit.at(now))
                collect()
            }
        }

        static func byPeer(_ code: ErrorCode, retryAfterSeconds: Int64? = nil) -> ConnectionClosure {
            .closedByPeer(WireError(code, retryAfter: retryAfterSeconds.map { .seconds($0) }))
        }

        @Test("Shut down: no deadline, no effect, and every later dial result and end does nothing")
        func shutDownStops() {
            var driver = Driver()
            driver.agent.dialFailed(.transient, now: Unit.at(0))
            driver.agent.shutDown(now: Unit.at(10))
            #expect(driver.agent.nextDeadline == nil)
            driver.step(to: 60_000)
            #expect(driver.agent.dialSucceeded(now: Unit.at(60_000)) == nil)
            driver.agent.dialFailed(.permanent, now: Unit.at(60_000))
            driver.agent.connectionEnded(
                ConnectionGeneration(rawValue: 0), .closedByPeer(WireError(.superseded)), now: Unit.at(60_000))
            driver.collect()
            #expect(driver.effects == [.dial])
            #expect(driver.agent.nextDeadline == nil)
        }

        @Test("A connection that received its policy and then stayed up 30 s resets the sequence")
        func resetsAfterLastingSession() {
            var driver = Driver()
            _ = driver.failDials(2)
            let generation = driver.connect()
            driver.policy(generation, after: 1_000)
            driver.end(generation, .transportLost, after: 30_000)
            #expect(driver.wait == 1_000)
        }

        @Test("A close under 30 s after the policy continues the sequence")
        func closeSoonAfterPolicy() {
            var driver = Driver()
            _ = driver.failDials(2)
            let generation = driver.connect()
            driver.policy(generation, after: 1_000)
            driver.end(generation, .transportLost, after: 29_999)
            #expect(driver.wait == 4_000)
        }

        @Test("A policy reported for another generation resets nothing")
        func policyOfAnotherGeneration() {
            var driver = Driver()
            _ = driver.failDials(2)
            let generation = driver.connect()
            driver.policy(ConnectionGeneration(rawValue: generation.rawValue + 1), after: 1_000)
            driver.end(generation, .transportLost, after: 60_000)
            #expect(driver.wait == 4_000)
        }

        @Test("retry_after shorter than the next delay waits the delay")
        func retryAfterShorterThanBackoff() {
            var driver = Driver()
            _ = driver.failDials(6)
            let generation = driver.connect()
            driver.end(generation, Self.byPeer(.duplicatePeer, retryAfterSeconds: 20), after: 100)
            #expect(driver.wait == 30_000)
        }

        @Test("A permanent dial failure stops: no transport")
        func permanent() {
            var driver = Driver()
            driver.agent.dialFailed(.permanent, now: Unit.at(0))
            driver.collect()
            #expect(driver.effects == [.dial, .stop(.noTransport)])
            #expect(driver.agent.nextDeadline == nil)
        }

        @Test("Parked while connected: the connection's end schedules nothing, and unparking dials at once")
        func parkWhileConnected() {
            var driver = Driver()
            let generation = driver.connect()
            driver.park()
            driver.end(generation, .closedLocally(WireError(.shuttingDown)), after: 100)
            #expect(driver.agent.nextDeadline == nil)
            driver.step(to: 600_000)
            #expect(driver.effects == [.dial])
            driver.unpark()
            #expect(driver.effects == [.dial, .dial])
        }

        @Test("Parked and unparked while connected: the connection's end redials at once, with no backoff")
        func reparkWhileConnected() {
            var driver = Driver()
            _ = driver.failDials(3)
            let generation = driver.connect()
            driver.park()
            driver.unpark()
            #expect(driver.effects.count == 4)
            driver.end(generation, .closedLocally(WireError(.shuttingDown)), after: 100)
            #expect(driver.effects.count == 5)
            #expect(driver.agent.nextDeadline == nil)
            #expect(driver.failDials(1) == [8])
        }

        @Test("Parked during a dial: its connection is refused, and a failure schedules nothing")
        func parkWhileDialing() {
            var driver = Driver()
            driver.park()
            #expect(driver.agent.dialSucceeded(now: Unit.at(0)) == nil)
            driver.unpark()
            #expect(driver.effects == [.dial, .dial])
            driver.park()
            driver.agent.dialFailed(.transient, now: Unit.at(0))
            #expect(driver.agent.nextDeadline == nil)
        }

        @Test("Unparked during a dial: that dial's connection serves, and its end backs off as usual")
        func unparkWhileDialing() {
            var driver = Driver()
            driver.park()
            driver.unpark()
            #expect(driver.effects == [.dial])
            let generation = driver.connect()
            driver.end(generation, .transportLost, after: 100)
            #expect(driver.wait == 1_000)
        }

        @Test("A clock stepping backwards does not delay a dial")
        func backwardStep() {
            var driver = Driver()
            _ = driver.failDials(1)
            driver.now = 10_000
            driver.agent.dialFailed(.transient, now: Unit.at(10_000))
            #expect(driver.wait == 2_000)
            driver.step(to: 5_000)
            #expect(driver.effects.count == 2)
            #expect(driver.agent.nextDeadline == Unit.at(7_000))
            driver.step(to: 7_000)
            #expect(driver.effects.count == 3)
        }
    }
}
