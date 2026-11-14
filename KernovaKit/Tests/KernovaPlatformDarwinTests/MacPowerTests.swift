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

    /// The answer `call` gives, whichever kind of call it is.
    static func answer(of call: MacPowerMechanism.Call?) -> String {
        switch call {
        case .answering(let call): String(describing: call())
        case .committing(let call): call().map { "failed \($0)" } ?? "going down"
        case nil: "no call"
        }
    }

    // MARK: - Adverts

    @Test("The session peer offers shutdown, asking apps to quit, only while its session owns the console")
    func sessionPeerAdvertFollowsConsole() {
        let harness = Harness(.loginWindow(send: { _ in noErr }))
        let elsewhere = Availability<PowerOffer>.absent(.notOnConsole, debugDetail: Self.absentDetail)
        let offered = Availability.available(PowerOffer(actions: [.shutdown], asksAppsToQuit: true))
        #expect(harness.take() == [.availability(elsewhere)])

        harness.adapter.consoleChanged(.on)
        #expect(harness.take() == [.availability(offered)])
        harness.adapter.consoleChanged(.on)
        #expect(harness.take() == [])

        for other in [ConsoleState.off, .unknown] {
            harness.adapter.consoleChanged(other)
            #expect(harness.take() == [.availability(elsewhere)], "\(other)")
            harness.adapter.consoleChanged(.on)
            #expect(harness.take() == [.availability(offered)], "\(other)")
        }
    }

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

    @Test(
        "The system peer refuses a graceful shutdown POWER_ACTION_UNSUPPORTED in every console state, running nothing",
        arguments: [ConsoleState.off, .on, .unknown])
    func systemPeerRefusesGraceful(console: ConsoleState) {
        let ran = Locked(0)
        let harness = Harness(
            .shutdownCommand(run: { _ in
                ran.withLock { $0 += 1 }
                return 0
            }), console: console)
        _ = harness.take()

        harness.adapter.perform(Self.id, .shutdown, ignoringApps: false)
        #expect(harness.take() == [.refused(Self.id, WireError(.powerActionUnsupported))])
        #expect(ran.withLock { $0 } == 0)
    }

    @Test("A console state set before start is the first advert")
    func consoleBeforeStart() {
        let harness = Harness(.loginWindow(send: { _ in noErr }), console: .on)
        #expect(
            harness.take() == [
                .availability(.available(PowerOffer(actions: [.shutdown], asksAppsToQuit: true)))
            ])
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

    @Test("A cancel while shutdown runs reports nothing: the accepted request ends with shutdown")
    func cancelWhileShutdownRuns() {
        let running = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let harness = Harness(
            .shutdownCommand(run: { _ in
                running.signal()
                release.wait()
                return 0
            }), console: .off)
        _ = harness.take()

        harness.adapter.perform(Self.id, .shutdown, ignoringApps: true)
        running.wait()
        harness.adapter.cancel(Self.id)
        release.signal()
        #expect(harness.take() == [.accepted(Self.id), .handedOff(Self.id)])
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

    @Test("A cancel while the call is blocked lets the request go unconfirmed, and its late answer reports nothing")
    func cancelWhileCalling() {
        let calling = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let mechanism = MacPowerMechanism(
            graceful: .init(
                absentDetail: "",
                call: .answering {
                    calling.signal()
                    release.wait()
                    return .tookIt
                }),
            ignoringApps: nil)
        let harness = Harness(mechanism, console: .on)
        _ = harness.take()

        harness.adapter.perform(Self.id, .shutdown, ignoringApps: false)
        calling.wait()
        harness.adapter.cancel(Self.id)
        release.signal()
        #expect(harness.take() == [.unconfirmed(Self.id)])
    }

    @Test("A cancel after the answer reports nothing more")
    func cancelAfterAnswer() {
        let harness = Harness(Self.mechanism(answering: .tookIt, calls: Locked(0)), console: .on)
        _ = harness.take()
        harness.adapter.perform(Self.id, .shutdown, ignoringApps: false)
        #expect(harness.take() == [.accepted(Self.id), .handedOff(Self.id)])
        harness.adapter.cancel(Self.id)
        #expect(harness.take() == [])
    }

    // MARK: - loginwindow

    @Test("The session peer sends loginwindow kAEShutDown")
    func loginWindowEvent() {
        let sent = Locked<[(eventClass: AEEventClass, eventID: AEEventID, target: String?, type: DescType?)]>([])
        let mechanism = MacPowerMechanism.loginWindow(send: { event in
            let target = event.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr))
            let bundle = target.map { String(decoding: $0.data, as: UTF8.self) }
            sent.withLock { $0.append((event.eventClass, event.eventID, bundle, target?.descriptorType)) }
            return noErr
        })
        #expect(Self.answer(of: mechanism.graceful?.call) == "tookIt")
        let event = sent.withLock { $0 }
        #expect(event.count == 1)
        #expect(event.first?.eventClass == AEEventClass(kCoreEventClass))
        #expect(event.first?.eventID == AEEventID(kAEShutDown))
        #expect(event.first?.target == "com.apple.loginwindow")
        #expect(event.first?.type == DescType(typeApplicationBundleID))
    }

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

    // MARK: - shutdown(8)

    @Test("The system peer runs shutdown -h now")
    func shutdownArguments() {
        let ran = Locked<[[String]]>([])
        let mechanism = MacPowerMechanism.shutdownCommand(run: { arguments in
            ran.withLock { $0.append(arguments) }
            return 0
        })
        #expect(Self.answer(of: mechanism.ignoringApps) == "going down")
        #expect(ran.withLock { $0 } == [["/sbin/shutdown", "-h", "now"]])
    }

    // MARK: - Quit

    static func quitEvent(reason: OSType?, asParameter: Bool = false) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        if let reason {
            let value = NSAppleEventDescriptor(enumCode: reason)
            if asParameter {
                event.setParam(value, forKeyword: AEKeyword(kAEQuitReason))
            } else {
                event.setAttribute(value, forKeyword: AEKeyword(kAEQuitReason))
            }
        }
        return event
    }

    @Test(
        "A quit for a log out, shut down or restart relaunches the session peer; any other quit stops it",
        arguments: [
            (OSType(kAEShutDown) as OSType?, MacAgentPeer.relaunchStatus),
            (OSType(kAERestart), MacAgentPeer.relaunchStatus), (OSType(kAEReallyLogOut), MacAgentPeer.relaunchStatus),
            (OSType(kAEQuitAll), Int32(0)), (nil, Int32(0)),
        ])
    func quitStatus(reason: OSType?, status: Int32) {
        #expect(MacAgentQuit.exitStatus(for: Self.quitEvent(reason: reason)) == status)
        #expect(MacAgentQuit.exitStatus(for: Self.quitEvent(reason: reason, asParameter: true)) == status)
    }
}
#endif
