#if os(macOS)
import CoreServices
import Dispatch
import Foundation
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaSynchronization
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaPlatformDarwin

@Suite("The macOS peers' power adapters", .caseScoped)
struct MacPowerTests {
    /// An adapter over `mechanism`, its reports, and a way to wait out everything it has queued.
    final class Harness: Sendable {
        let adapter: MacPowerAdapter
        private let reports = Locked<[PowerInput]>([])
        private let queue = DispatchQueue(label: "test.power")
        private let callQueue = DispatchQueue(label: "test.power.call")

        init(_ mechanism: MacPowerMechanism, console: ConsoleState? = nil) {
            adapter = MacPowerAdapter(mechanism, queue: queue, callQueue: callQueue)
            if let console { adapter.consoleChanged(console) }
            adapter.start(reporter: PowerReporter { [reports] input in reports.withLock { $0.append(input) } })
            settle()
        }

        /// Waits for the adapter's queued work, a call it handed off and the answer that call queued.
        func settle() {
            queue.sync {}
            callQueue.sync {}
            queue.sync {}
        }

        /// The reports made so far and not yet taken, without waiting for anything queued.
        var reported: [PowerInput] { reports.withLock { $0 } }

        /// The reports made since the last `take()`.
        func take() -> [PowerInput] {
            settle()
            return reports.withLock { reports in
                defer { reports.removeAll() }
                return reports
            }
        }
    }

    static let id = PowerRequestID(generation: ConnectionGeneration(rawValue: 1), rawValue: 3)

    /// The session peer's mechanism with its graceful call replaced by one counting its calls and answering
    /// `answer`.
    static func mechanism(answering answer: MacPowerAnswer, calls: Locked<Int>) -> MacPowerMechanism {
        MacPowerMechanism(
            graceful: .init(
                absentDetail: Self.absentDetail,
                call: .answering {
                    calls.withLock { $0 += 1 }
                    return answer
                }),
            ignoringApps: nil)
    }

    static let absentDetail = MacPowerMechanism.loginWindow().graceful?.absentDetail ?? ""

    // MARK: - Adverts

    @Test(
        "The system peer offers no graceful shutdown in any console state, and Stop Anyway in every one"
    )
    func systemPeerAdvert() {
        let harness = Harness(.shutdownCommand(run: { _ in 0 }))
        let offer = PowerInput.availability(.available(PowerOffer(actions: [], ignoringApps: [.shutdown])))
        #expect(harness.take() == [offer])

        for console in [ConsoleState.off, .on, .unknown] {
            harness.adapter.consoleChanged(console)
            #expect(harness.take() == [offer], "\(console)")
        }
    }

    // MARK: - Requests

    /// Every answer a call can give, and what the adapter reports of it.
    static let answers: [(answer: MacPowerAnswer, reports: [PowerInput])] = [
        (.tookIt, [.accepted(id), .handedOff(id)]),
        (.refused(WireError(.powerNotPermitted)), [.refused(id, WireError(.powerNotPermitted))]),
        (.unconfirmed, [.unconfirmed(id)]),
    ]

    @Test(
        "A request in the offered console state makes the call once and reports its answer",
        arguments: answers.indices)
    func requestReportsAnswer(row: Int) {
        let (answer, reports) = Self.answers[row]
        let calls = Locked(0)
        let harness = Harness(Self.mechanism(answering: answer, calls: calls), console: .on)
        _ = harness.take()

        harness.adapter.perform(Self.id, .shutdown, ignoringApps: false)
        #expect(harness.take() == reports)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test(
        "The system peer reports a shutdown without waiting for apps accepted before shutdown starts, then how shutdown ended",
        arguments: [
            (Int32(0), PowerInput.handedOff(id)),
            (1, .failed(id, WireError(.powerOsFailed, debugDetail: "shutdown exited 1"))),
            (-1, .failed(id, WireError(.powerOsFailed, debugDetail: "shutdown could not start"))),
            (128 + SIGKILL, .failed(id, WireError(.powerOsFailed, debugDetail: "shutdown ended by signal 9"))),
        ])
    func systemPeerAcceptsBeforeShutdown(status: Int32, end: PowerInput) {
        let seenAtStart = Locked<[PowerInput]?>(nil)
        let harness = Locked<Harness?>(nil)
        let mechanism = MacPowerMechanism.shutdownCommand(run: { _ in
            seenAtStart.withLock { $0 = harness.withLock { $0 }?.reported }
            return status
        })
        let built = Harness(mechanism, console: .off)
        harness.withLock { $0 = built }
        _ = built.take()

        built.adapter.perform(Self.id, .shutdown, ignoringApps: true)
        #expect(built.take() == [.accepted(Self.id), end])
        #expect(seenAtStart.withLock { $0 } == [.accepted(Self.id)])
    }

    @Test(
        "A session peer's request while its session does not own the console is refused NOT_ON_CONSOLE without a call",
        arguments: [ConsoleState.off, .unknown])
    func requestOffConsoleRefused(console: ConsoleState) {
        let calls = Locked(0)
        let harness = Harness(Self.mechanism(answering: .tookIt, calls: calls), console: console)
        _ = harness.take()

        harness.adapter.perform(Self.id, .shutdown, ignoringApps: false)
        #expect(
            harness.take() == [.refused(Self.id, WireError(.powerNotOnConsole, debugDetail: Self.absentDetail))])
        #expect(calls.withLock { $0 } == 0)
    }

    // MARK: - loginwindow

    @Test(
        "The send's answer: delivered is taken, refused where nothing was delivered, else unconfirmed",
        arguments: [
            (OSStatus(noErr), "tookIt"),
            (OSStatus(errAEEventNotPermitted), "notPermitted"), (OSStatus(procNotFound), "osFailed"),
            (OSStatus(connectionInvalid), "osFailed"),
            (OSStatus(errAETimeout), "unconfirmed"), (OSStatus(-50), "unconfirmed"),
        ])
    func loginWindowAnswers(status: OSStatus, expected: String) {
        let answer = LoginWindowPower.answer(status)
        switch answer {
        case .tookIt: #expect(expected == "tookIt")
        case .refused(let error) where error.code == .powerNotPermitted: #expect(expected == "notPermitted")
        case .refused(let error) where error.code == .powerOsFailed: #expect(expected == "osFailed")
        case .refused(let error): Issue.record("unexpected refusal \(error)")
        case .unconfirmed: #expect(expected == "unconfirmed")
        }
    }
}
#endif
