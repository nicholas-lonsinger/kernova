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
                guard case .role(.power(let id, let result)) = event, id == Self.id else { return nil }
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
    }
}
