#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaWire
import Testing

extension CoreUnits {
    @Suite("PeerAgent: §9.3's dial schedule")
    struct PeerAgentUnitTests {
        /// An agent driven on a timeline of milliseconds, with what it asked for so far.
        struct Driver {
            var agent: PeerAgent
            var now: Int64 = 0
            var effects: [AgentEffect] = []

            init() {
                agent = PeerAgent(now: Unit.at(0))
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
                return agent.dialSucceeded(now: Unit.at(now))
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

        @Test("A new agent dials at once and waits on nothing")
        func dialsAtOnce() {
            let driver = Driver()
            #expect(driver.effects == [.dial])
            #expect(driver.agent.nextDeadline == nil)
        }

        @Test("Failed dials back off 1, 2, 4, 8, 16, then 30 s for every later attempt")
        func backoffSequence() {
            var driver = Driver()
            #expect(driver.failDials(9) == [1, 2, 4, 8, 16, 30, 30, 30, 30])
            #expect(driver.effects == Array(repeating: .dial, count: 10))
        }

        @Test("A timeout before the deadline dials nothing")
        func earlyTimeout() {
            var driver = Driver()
            driver.agent.dialFailed(.transient, now: Unit.at(0))
            driver.step(to: 999)
            #expect(driver.effects == [.dial])
            driver.step(to: 1_000)
            #expect(driver.effects == [.dial, .dial])
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

        @Test("A long connection that never received its policy continues the sequence")
        func longWithoutPolicy() {
            var driver = Driver()
            _ = driver.failDials(2)
            let generation = driver.connect()
            driver.end(generation, .transportLost, after: 120_000)
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

        @Test("Each dial that connects gets the next generation")
        func generations() {
            var driver = Driver()
            let first = driver.connect()
            driver.end(first, .transportLost, after: 100)
            driver.step(to: driver.now + (driver.wait ?? 0))
            let second = driver.connect()
            #expect(first == ConnectionGeneration(rawValue: 1))
            #expect(second == ConnectionGeneration(rawValue: 2))
        }

        @Test("DUPLICATE_PEER waits max(retry_after, the next delay) and continues the sequence")
        func duplicatePeer() {
            var driver = Driver()
            _ = driver.failDials(2)
            let generation = driver.connect()
            driver.end(generation, Self.byPeer(.duplicatePeer, retryAfterSeconds: 20), after: 100)
            #expect(driver.wait == 20_000)
            driver.step(to: driver.now + 20_000)
            #expect(driver.failDials(1) == [8])
        }

        @Test("retry_after shorter than the next delay waits the delay")
        func retryAfterShorterThanBackoff() {
            var driver = Driver()
            _ = driver.failDials(6)
            let generation = driver.connect()
            driver.end(generation, Self.byPeer(.duplicatePeer, retryAfterSeconds: 20), after: 100)
            #expect(driver.wait == 30_000)
        }

        @Test("A fatal close code continues the sequence")
        func fatalCloseContinues() {
            var driver = Driver()
            _ = driver.failDials(1)
            let generation = driver.connect()
            driver.end(generation, Self.byPeer(.protocolError), after: 100)
            #expect(driver.wait == 2_000)
        }

        @Test("SUPERSEDED on the current generation stops for good")
        func superseded() {
            var driver = Driver()
            let generation = driver.connect()
            driver.end(generation, Self.byPeer(.superseded), after: 100)
            #expect(driver.effects == [.dial, .stop(.superseded)])
            #expect(driver.agent.nextDeadline == nil)
            driver.agent.dialFailed(.transient, now: Unit.at(driver.now))
            driver.step(to: driver.now + 600_000)
            #expect(driver.effects == [.dial, .stop(.superseded)])
        }

        @Test("SUPERSEDED on an older generation is ignored")
        func supersededOlderGeneration() {
            var driver = Driver()
            let first = driver.connect()
            driver.end(first, .transportLost, after: 100)
            driver.step(to: driver.now + (driver.wait ?? 0))
            let second = driver.connect()
            driver.end(first, Self.byPeer(.superseded), after: 100)
            #expect(!driver.effects.contains(.stop(.superseded)))
            #expect(driver.agent.nextDeadline == nil)
            driver.end(second, .transportLost, after: 100)
            #expect(driver.wait != nil)
        }

        @Test("A permanent dial failure stops: no transport")
        func permanent() {
            var driver = Driver()
            driver.agent.dialFailed(.permanent, now: Unit.at(0))
            driver.collect()
            #expect(driver.effects == [.dial, .stop(.noTransport)])
            #expect(driver.agent.nextDeadline == nil)
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
