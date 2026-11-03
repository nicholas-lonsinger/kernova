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

    static func mechanism(
        _ base: MacPowerMechanism, answering answer: MacPowerAnswer, calls: Locked<[PowerAction]>
    ) -> MacPowerMechanism {
        MacPowerMechanism(
            offeredWhile: base.offeredWhile, asksAppsToQuit: base.asksAppsToQuit, absentDetail: base.absentDetail,
            perform: { action in
                calls.withLock { $0.append(action) }
                return answer
            })
    }

    // MARK: - Adverts

    @Test(
        "Each adapter offers shutdown and restart only in its console state: the session peer's on, the system peer's off",
        arguments: [
            (MacPowerMechanism.loginWindow(send: { _ in noErr }), ConsoleState.on, true),
            (MacPowerMechanism.shutdownCommand(run: { _ in 0 }), ConsoleState.off, false),
        ])
    func advertFollowsConsole(mechanism: MacPowerMechanism, offeredWhile: ConsoleState, asksAppsToQuit: Bool) {
        let harness = Harness(mechanism)
        let absent = Availability<PowerOffer>.absent(.notOnConsole, debugDetail: mechanism.absentDetail)
        let offered = Availability.available(
            PowerOffer(actions: [.shutdown, .restart], asksAppsToQuit: asksAppsToQuit))
        #expect(harness.take() == [.availability(absent)])

        harness.adapter.consoleChanged(offeredWhile)
        #expect(harness.take() == [.availability(offered)])
        harness.adapter.consoleChanged(offeredWhile)
        #expect(harness.take() == [])

        for other in [ConsoleState.on, .off, .unknown] where other != offeredWhile {
            harness.adapter.consoleChanged(other)
            #expect(harness.take() == [.availability(absent)], "\(other)")
            harness.adapter.consoleChanged(offeredWhile)
            #expect(harness.take() == [.availability(offered)], "\(other)")
        }
    }

    @Test("A console state set before start is the first advert")
    func consoleBeforeStart() {
        let harness = Harness(.loginWindow(send: { _ in noErr }), console: .on)
        #expect(
            harness.take() == [
                .availability(.available(PowerOffer(actions: [.shutdown, .restart], asksAppsToQuit: true)))
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
        let calls = Locked<[PowerAction]>([])
        let harness = Harness(
            Self.mechanism(.loginWindow(), answering: answer, calls: calls), console: .on)
        _ = harness.take()

        harness.adapter.perform(Self.id, .restart)
        #expect(harness.take() == reports)
        #expect(calls.withLock { $0 } == [.restart])
    }

    @Test("A request outside the offered console state is refused NOT_ON_CONSOLE without a call")
    func requestOffConsoleRefused() {
        let calls = Locked<[PowerAction]>([])
        let mechanism = Self.mechanism(.shutdownCommand(), answering: .tookIt, calls: calls)
        let harness = Harness(mechanism, console: .unknown)
        _ = harness.take()

        harness.adapter.perform(Self.id, .shutdown)
        #expect(
            harness.take() == [
                .refused(Self.id, WireError(.powerNotOnConsole, debugDetail: mechanism.absentDetail))
            ])
        #expect(calls.withLock { $0 }.isEmpty)
    }

    @Test("A cancel while the call is blocked lets the request go unconfirmed, and its late answer reports nothing")
    func cancelWhileCalling() {
        let calling = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let mechanism = MacPowerMechanism(
            offeredWhile: .on, asksAppsToQuit: true, absentDetail: "",
            perform: { _ in
                calling.signal()
                release.wait()
                return .tookIt
            })
        let harness = Harness(mechanism, console: .on)
        _ = harness.take()

        harness.adapter.perform(Self.id, .shutdown)
        calling.wait()
        harness.adapter.cancel(Self.id)
        release.signal()
        #expect(harness.take() == [.unconfirmed(Self.id)])
    }

    @Test("A cancel after the answer reports nothing more")
    func cancelAfterAnswer() {
        let harness = Harness(
            Self.mechanism(.loginWindow(), answering: .tookIt, calls: Locked([])), console: .on)
        _ = harness.take()
        harness.adapter.perform(Self.id, .shutdown)
        #expect(harness.take() == [.accepted(Self.id), .handedOff(Self.id)])
        harness.adapter.cancel(Self.id)
        #expect(harness.take() == [])
    }

    // MARK: - loginwindow

    @Test(
        "The session peer sends loginwindow kAEShutDown or kAERestart",
        arguments: [(PowerAction.shutdown, kAEShutDown), (.restart, kAERestart)])
    func loginWindowEvent(action: PowerAction, eventID: OSType) {
        let sent = Locked<[(eventClass: AEEventClass, eventID: AEEventID, target: String?, type: DescType?)]>([])
        let mechanism = MacPowerMechanism.loginWindow(send: { event in
            let target = event.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr))
            let bundle = target.map { String(decoding: $0.data, as: UTF8.self) }
            sent.withLock { $0.append((event.eventClass, event.eventID, bundle, target?.descriptorType)) }
            return noErr
        })
        #expect(mechanism.perform(action) == .tookIt)
        let event = sent.withLock { $0 }
        #expect(event.count == 1)
        #expect(event.first?.eventClass == AEEventClass(kCoreEventClass))
        #expect(event.first?.eventID == AEEventID(eventID))
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

    @Test(
        "The system peer runs shutdown -h now or -r now",
        arguments: [(PowerAction.shutdown, "-h"), (.restart, "-r")])
    func shutdownArguments(action: PowerAction, flag: String) {
        let ran = Locked<[[String]]>([])
        let mechanism = MacPowerMechanism.shutdownCommand(run: { arguments in
            ran.withLock { $0.append(arguments) }
            return 0
        })
        #expect(mechanism.perform(action) == .tookIt)
        #expect(ran.withLock { $0 } == [["/sbin/shutdown", flag, "now"]])
    }

    @Test("shutdown's status: 0 taken, a failure exit or no start refused, a signal unconfirmed")
    func shutdownAnswers() {
        #expect(ShutdownCommand.answer(0) == .tookIt)
        #expect(
            ShutdownCommand.answer(1) == .refused(WireError(.powerOsFailed, debugDetail: "shutdown exited 1")))
        #expect(
            ShutdownCommand.answer(-1) == .refused(WireError(.powerOsFailed, debugDetail: "shutdown could not start")))
        #expect(ShutdownCommand.answer(128 + SIGKILL) == .unconfirmed)
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

    @Test("No event, or one that is not a quit, stops the session peer")
    func quitWithoutQuitEvent() {
        #expect(MacAgentQuit.exitStatus(for: nil) == 0)
        let other = LoginWindowPower.event(for: .shutdown)
        other.setAttribute(NSAppleEventDescriptor(enumCode: OSType(kAEShutDown)), forKeyword: AEKeyword(kAEQuitReason))
        #expect(MacAgentQuit.exitStatus(for: other) == 0)
    }
}
#endif
