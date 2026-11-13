#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@testable import KernovaAgentCore
import KernovaAgentSimulation
import KernovaWire
import SwiftProtobuf
import Testing

extension CoreUnits {
    @Suite("PowerResponder")
    struct PowerResponderUnitTests {
        static let id = PowerRequestID(generation: ConnectionGeneration(rawValue: 1), rawValue: 2)

        /// A real session peer, its Hello answered by a host.
        static func peer() -> HostileRun {
            let run = HostileRun(local: .peer, seed: 7)
            run.feed([WireFrames.hello(role: .host)], preamble: true)
            return run
        }

        /// The host's OPEN of POWER_REQUEST on `stream`, END at once.
        static func request(
            _ run: HostileRun, _ action: PowerAction = .shutdown, deadlineMs: UInt32 = 10_000, stream: UInt32 = 2,
            ignoreApps: Bool = false
        ) {
            run.feed([
                WireFrames.open(
                    stream, .powerRequest,
                    body: Unit.powerRequest(action, deadlineMs: deadlineMs, ignoreApps: ignoreApps)),
                Unit.end(stream),
            ])
        }

        static func stages(_ frames: [Frame], stream: UInt32 = 2) -> [Kernova_V2_PowerProgress.Stage] {
            frames.on(stream).filter { $0.type == .data }.compactMap {
                try? Kernova_V2_PowerProgress(serializedBytes: $0.payload).stage
            }
        }

        static func outcomes(_ frames: [Frame], stream: UInt32 = 2) -> [Kernova_V2_PowerOutcome] {
            frames.on(stream).filter { $0.type == .end }.compactMap {
                try? Kernova_V2_PowerOutcome(serializedBytes: $0.payload)
            }
        }

        static func powerEffects(_ run: HostileRun) -> [PowerEffect] {
            run.peerEffects.compactMap { if case .power(let effect) = $0 { effect } else { nil } }
        }

        static func localFaults(_ run: HostileRun) -> Int {
            run.peerEvents.count(where: { if case .diagnostic(.localFault) = $0 { true } else { false } })
        }

        // MARK: new

        @Test("new + OPEN of an action not in the current advert → END REFUSED POWER_ACTION_UNSUPPORTED")
        func unsupportedAction() {
            let run = Self.peer()
            run.input(.power(.availability(.available(PowerOffer(actions: [.shutdown])))))
            Self.request(run, .restart)
            let outcomes = Self.outcomes(run.written)
            #expect(outcomes.map(\.kind) == [.refused])
            #expect(outcomes.first?.error.code == .powerActionUnsupported)
            #expect(Self.powerEffects(run).isEmpty)
        }

        @Test("An acceptance deadline of 0 sets no deadline")
        func noDeadline() {
            let run = Self.peer()
            Self.request(run, deadlineMs: 0)
            run.advanceLive(.sec(30))
            #expect(Self.powerEffects(run) == [.perform(Self.id, .shutdown)])
        }

        // MARK: asked

        @Test("asked + .refused → END REFUSED with the adapter's error")
        func askedRefused() {
            let run = Self.peer()
            Self.request(run)
            run.input(.power(.refused(Self.id, WireError(.powerOsFailed, posixErrno: 5))))
            let outcome = Self.outcomes(run.written).first
            #expect(outcome?.kind == .refused)
            #expect(outcome?.error.code == .powerOsFailed)
            #expect(outcome?.error.posixErrno == 5)
        }

        @Test("asked + host RESET → .cancel; cancelling + .cancelled on a closed stream → nothing")
        func resetThenCancelled() {
            let run = Self.peer()
            Self.request(run)
            run.feed([WireFrames.reset(2, code: ErrorCode.cancelled.rawValue)])
            #expect(Self.powerEffects(run) == [.perform(Self.id, .shutdown), .cancel(Self.id)])
            let mark = run.written.count
            run.input(.power(.cancelled(Self.id)))
            #expect(run.written(since: mark).on(2).isEmpty)
            #expect(Self.localFaults(run) == 0)
        }

        // MARK: Coalescing

        @Test("ACCEPTED is queued at once; a later unsendable progress is held, a newer one replacing it")
        func progressCoalesces() {
            let run = Self.peer()
            Self.request(run)
            run.writerStalled = true
            run.input(.power(.accepted(Self.id)))
            run.input(.power(.askingApps(Self.id)))
            run.input(.power(.waitingOnApps(Self.id, [AppValue(displayName: "Editor")])))
            run.writerStalled = false
            run.drain()
            #expect(Self.stages(run.written) == [.accepted, .waitingOnApps])
        }

        // MARK: Adapter order

        @Test("An out-of-order adapter report is dropped with a diagnostic")
        func outOfOrderReport() {
            let run = Self.peer()
            Self.request(run)
            run.input(.power(.askingApps(Self.id)))
            #expect(run.written.on(2).isEmpty)
            #expect(Self.localFaults(run) == 1)
        }

        @Test(
            "asked or cancelling + .unconfirmed on an open stream → END UNSPECIFIED; the next OPEN performs",
            arguments: [false, true])
        func unconfirmedOpenStream(_ cancelling: Bool) {
            let run = Self.peer()
            Self.request(run)
            if cancelling { run.advanceLive(.sec(11)) }
            #expect(Self.powerEffects(run).count == (cancelling ? 2 : 1))
            run.input(.power(.unconfirmed(Self.id)))
            #expect(Self.outcomes(run.written).map(\.kind) == [.unspecified])
            #expect(Self.localFaults(run) == 0)
            Self.request(run, stream: 4)
            #expect(
                Self.powerEffects(run).last
                    == .perform(PowerRequestID(generation: Self.id.generation, rawValue: 4), .shutdown))
        }
    }

    @Suite("PowerRequester")
    struct PowerRequesterUnitTests {
        static let id = PowerRequestID(generation: ConnectionGeneration(rawValue: 1), rawValue: 7)

        /// A real host with an established session peer and one request sent.
        static func host() -> HostileRun {
            let run = HostileRun(local: .host, seed: 11)
            run.feed([WireFrames.hello(role: .sessionPeer)], preamble: true)
            run.command(.requestPower(id, .shutdown))
            return run
        }

        static func results(_ run: HostileRun) -> [PowerRequestResult] {
            run.hostEvents.compactMap { event in
                guard case .power(let id, let result) = event, id == Self.id else { return nil }
                return result
            }
        }

        static func resets(_ frames: [Frame]) -> [ErrorCode] {
            frames.on(2).filter { $0.type == .reset }.map { Unit.error($0.payload).code }
        }

        static func progress(_ stage: Kernova_V2_PowerProgress.Stage, apps: Int = 0) -> Frame {
            WireFrames.message(2, Unit.progress(stage, apps: apps))
        }

        static func end(_ kind: Kernova_V2_PowerOutcome.Kind, _ code: ErrorCode? = nil, apps: Int = 0) -> Frame {
            Unit.end(2, Unit.outcome(kind, code, apps: apps))
        }

        static let accepted = progress(.accepted)

        struct Row: Sendable, CustomTestStringConvertible {
            var name: String
            var afterAccepted = false
            var frames: [Frame]
            var result: PowerRequestResult
            var reset: ErrorCode?

            var testDescription: String { "\(afterAccepted ? "accepted" : "waiting") + \(name)" }
        }

        static let rows: [Row] = [
            Row(name: "ACCEPTED", frames: [accepted], result: .accepted),
            Row(
                name: "END REFUSED NOT_ON_CONSOLE", frames: [end(.refused, .powerNotOnConsole)],
                result: .refused(WireError(.powerNotOnConsole))),
            Row(
                name: "END REFUSED TIMEOUT", frames: [end(.refused, .timeout)], result: .refused(WireError(.timeout))),
            Row(
                name: "RESET UNSUPPORTED_KIND", frames: [WireFrames.reset(2, code: 51)],
                result: .refused(WireError(.unsupportedKind))),
            Row(
                name: "RESET FEATURE_UNAVAILABLE", frames: [WireFrames.reset(2, code: 52)],
                result: .refused(WireError(.featureUnavailable))),
            Row(
                name: "RESET TOO_MANY_STREAMS", frames: [WireFrames.reset(2, code: 55)],
                result: .refused(WireError(.tooManyStreams))),
            Row(
                name: "RESET MALFORMED_MESSAGE", frames: [WireFrames.reset(2, code: 54)],
                result: .refused(WireError(.malformedMessage))),
            Row(
                name: "END REFUSED POWER_IN_PROGRESS", frames: [end(.refused, .powerInProgress)], result: .indeterminate
            ),
            Row(name: "END HANDED_OFF", frames: [end(.handedOff)], result: .indeterminate),
            Row(name: "END UNSPECIFIED", frames: [end(.unspecified)], result: .indeterminate),
            Row(
                name: "ASKING_APPS before ACCEPTED", frames: [progress(.askingApps)], result: .indeterminate,
                reset: .streamProtocolError),
            Row(
                name: "WAITING_ON_APPS before ACCEPTED", frames: [progress(.waitingOnApps, apps: 1)],
                result: .indeterminate, reset: .streamProtocolError),
            Row(name: "RESET CANCELLED", frames: [WireFrames.reset(2, code: 50)], result: .indeterminate),
            Row(name: "RESET STREAM_PROTOCOL_ERROR", frames: [WireFrames.reset(2, code: 53)], result: .indeterminate),
            Row(name: "RESET POWER_OS_FAILED", frames: [WireFrames.reset(2, code: 104)], result: .indeterminate),
            Row(name: "RESET of an unknown code", frames: [WireFrames.reset(2, code: 999)], result: .indeterminate),
            Row(
                name: "ASKING_APPS", afterAccepted: true, frames: [progress(.askingApps)],
                result: .progress(.askingApps, [])),
            Row(
                name: "WAITING_ON_APPS", afterAccepted: true, frames: [progress(.waitingOnApps, apps: 2)],
                result: .progress(.waitingOnApps, [AppValue(displayName: "App 0"), AppValue(displayName: "App 1")])),
            Row(name: "END HANDED_OFF", afterAccepted: true, frames: [end(.handedOff)], result: .finished(.handedOff)),
            Row(
                name: "END BLOCKED", afterAccepted: true, frames: [end(.blocked, apps: 2)],
                result: .finished(.blocked([AppValue(displayName: "App 0"), AppValue(displayName: "App 1")]))),
            Row(
                name: "END CANCELLED_IN_GUEST", afterAccepted: true, frames: [end(.cancelledInGuest)],
                result: .finished(.cancelledInGuest)),
            Row(
                name: "END FAILED", afterAccepted: true, frames: [end(.failed, .powerOsFailed)],
                result: .finished(.failed(WireError(.powerOsFailed)))),
            Row(
                name: "END REFUSED", afterAccepted: true, frames: [end(.refused, .powerNotPermitted)],
                result: .finished(.failed(WireError(.powerNotPermitted)))),
            Row(
                name: "END UNSPECIFIED", afterAccepted: true, frames: [end(.unspecified)],
                result: .finished(.failed(WireError(.unspecified)))),
            Row(
                name: "END of an unknown kind", afterAccepted: true, frames: [end(.UNRECOGNIZED(77))],
                result: .finished(.failed(WireError(.unspecified)))),
            Row(
                name: "a second ACCEPTED", afterAccepted: true, frames: [accepted], result: .indeterminate,
                reset: .streamProtocolError),
            Row(
                name: "RESET from the peer", afterAccepted: true, frames: [WireFrames.reset(2, code: 50)],
                result: .indeterminate),
        ]

        @Test("PowerRequester row", arguments: rows)
        func row(_ row: Row) {
            let run = Self.host()
            if row.afterAccepted { run.feed([Self.accepted]) }
            let mark = run.written.count
            run.feed(row.frames)
            #expect(Self.results(run) == (row.afterAccepted ? [.accepted] : []) + [row.result])
            #expect(Self.resets(run.written(since: mark)) == (row.reset.map { [$0] } ?? []))
        }

        @Test("waiting + 15 s of judged time → RESET TIMEOUT, .indeterminate (confirmed 1 s after it passes)")
        func hostDeadline() {
            let run = Self.host()
            run.advanceLive(.sec(15), pingEvery: .ms(500))
            #expect(Self.results(run).isEmpty)
            run.advanceLive(.ms(500), pingEvery: .ms(500))
            #expect(Self.results(run).isEmpty)
            run.advanceLive(.ms(500), pingEvery: .ms(500))
            #expect(Self.results(run) == [.indeterminate])
            #expect(Self.resets(run.written) == [.timeout])
        }

        @Test("WAITING_ON_APPS lists are clipped to 32 apps")
        func appsClipped() {
            let run = Self.host()
            run.feed([Self.accepted, Self.progress(.waitingOnApps, apps: 40)])
            guard case .progress(_, let apps) = Self.results(run).last else {
                Issue.record("no progress result")
                return
            }
            #expect(apps.count == 32)
        }

        @Test("The hub's cancel in waiting → RESET CANCELLED, .indeterminate")
        func cancelWaiting() {
            let run = Self.host()
            run.command(.cancelPower(Self.id))
            #expect(Self.results(run) == [.indeterminate])
            #expect(Self.resets(run.written) == [.cancelled])
        }
    }
}
