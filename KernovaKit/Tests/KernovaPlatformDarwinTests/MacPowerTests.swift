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

    /// The session peer's mechanism with its graceful call replaced by one recording each action and answering
    /// `answer`.
    static func mechanism(answering answer: MacPowerAnswer, calls: Locked<[PowerAction]>) -> MacPowerMechanism {
        MacPowerMechanism(
            graceful: .init(
                absentDetail: Self.absentDetail,
                call: .answering { action in
                    calls.withLock { $0.append(action) }
                    return answer
                }),
            ignoringApps: nil, powerButtonIgnoredWhileOff: false)
    }

    static let absentDetail = MacPowerMechanism.loginWindow().graceful?.absentDetail ?? ""

    /// The answer `call` gives `action`, whichever kind of call it is.
    static func answer(of call: MacPowerMechanism.Call?, _ action: PowerAction) -> String {
        switch call {
        case .answering(let call): String(describing: call(action))
        case .committing(let call): call(action).map { "failed \($0)" } ?? "going down"
        case nil: "no call"
        }
    }

    // MARK: - Adverts

    @Test("The session peer offers shutdown and restart, asking apps to quit, only while its session owns the console")
    func sessionPeerAdvertFollowsConsole() {
        let harness = Harness(.loginWindow(send: { _ in noErr }))
        let elsewhere = Availability<PowerOffer>.absent(.notOnConsole, debugDetail: Self.absentDetail)
        let offered = Availability.available(PowerOffer(actions: [.shutdown, .restart], asksAppsToQuit: true))
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
        "The system peer offers no graceful shutdown or restart in any console state, Shut Down Anyway in every one, and says macOS ignores the power button exactly while the console is off"
    )
    func systemPeerAdvert() {
        let harness = Harness(.shutdownCommand(run: { _ in 0 }))
        func offer(buttonIgnored: Bool) -> PowerInput {
            .availability(.available(PowerOffer(actions: [], ignoringApps: [.shutdown], powerButtonIgnored: buttonIgnored)))
        }
        #expect(harness.take() == [offer(buttonIgnored: false)])

        for (console, buttonIgnored) in [(ConsoleState.off, true), (.on, false), (.off, true), (.unknown, false)] {
            harness.adapter.consoleChanged(console)
            #expect(harness.take() == [offer(buttonIgnored: buttonIgnored)], "\(console)")
        }
    }

    @Test("The system peer refuses a graceful shutdown or restart POWER_ACTION_UNSUPPORTED in every console state, running nothing",
        arguments: [ConsoleState.off, .on, .unknown], [PowerAction.shutdown, .restart])
    func systemPeerRefusesGraceful(console: ConsoleState, action: PowerAction) {
        let ran = Locked(0)
        let harness = Harness(
            .shutdownCommand(run: { _ in
                ran.withLock { $0 += 1 }
                return 0
            }), console: console)
        _ = harness.take()

        harness.adapter.perform(Self.id, action, ignoringApps: false)
        #expect(harness.take() == [.refused(Self.id, WireError(.powerActionUnsupported))])
        #expect(ran.withLock { $0 } == 0)
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
        let harness = Harness(Self.mechanism(answering: answer, calls: calls), console: .on)
        _ = harness.take()

        harness.adapter.perform(Self.id, .restart, ignoringApps: false)
        #expect(harness.take() == reports)
        #expect(calls.withLock { $0 } == [.restart])
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
        let calls = Locked<[PowerAction]>([])
        let harness = Harness(Self.mechanism(answering: .tookIt, calls: calls), console: console)
        _ = harness.take()

        harness.adapter.perform(Self.id, .shutdown, ignoringApps: false)
        #expect(
            harness.take() == [.refused(Self.id, WireError(.powerNotOnConsole, debugDetail: Self.absentDetail))])
        #expect(calls.withLock { $0 }.isEmpty)
    }

    @Test(
        "With a user logged in, the system peer shuts down without waiting for apps: accepted before shutdown -h now starts, then handed off",
        arguments: [ConsoleState.on, .unknown, .off])
    func systemPeerShutsDownIgnoringApps(console: ConsoleState) {
        let ran = Locked<[[String]]>([])
        let seenAtStart = Locked<[PowerInput]?>(nil)
        let harness = Locked<Harness?>(nil)
        let built = Harness(
            .shutdownCommand(run: { arguments in
                ran.withLock { $0.append(arguments) }
                seenAtStart.withLock { $0 = harness.withLock { $0 }?.reported }
                return 0
            }), console: console)
        harness.withLock { $0 = built }
        _ = built.take()

        built.adapter.perform(Self.id, .shutdown, ignoringApps: true)
        #expect(built.take() == [.accepted(Self.id), .handedOff(Self.id)])
        #expect(seenAtStart.withLock { $0 } == [.accepted(Self.id)])
        #expect(ran.withLock { $0 } == [["/sbin/shutdown", "-h", "now"]])
    }

    @Test(
        "A request without waiting for apps the mechanism does not offer is refused POWER_ACTION_UNSUPPORTED without a call",
        arguments: [(PowerAction.shutdown, true), (.restart, false)])
    func ignoringAppsUnofferedRefused(action: PowerAction, sessionPeer: Bool) {
        let sent = Locked(0)
        let ran = Locked(0)
        let mechanism: MacPowerMechanism =
            sessionPeer
            ? .loginWindow(send: { _ in
                sent.withLock { $0 += 1 }
                return noErr
            })
            : .shutdownCommand(run: { _ in
                ran.withLock { $0 += 1 }
                return 0
            })
        let harness = Harness(mechanism, console: .on)
        _ = harness.take()

        harness.adapter.perform(Self.id, action, ignoringApps: true)
        #expect(harness.take() == [.refused(Self.id, WireError(.powerActionUnsupported))])
        #expect(sent.withLock { $0 } == 0)
        #expect(ran.withLock { $0 } == 0)
    }

    @Test("A cancel while the call is blocked lets the request go unconfirmed, and its late answer reports nothing")
    func cancelWhileCalling() {
        let calling = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let mechanism = MacPowerMechanism(
            graceful: .init(
                absentDetail: "",
                call: .answering { _ in
                    calling.signal()
                    release.wait()
                    return .tookIt
                }),
            ignoringApps: nil, powerButtonIgnoredWhileOff: false)
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
        let harness = Harness(Self.mechanism(answering: .tookIt, calls: Locked([])), console: .on)
        _ = harness.take()
        harness.adapter.perform(Self.id, .shutdown, ignoringApps: false)
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
        #expect(Self.answer(of: mechanism.graceful?.call, action) == "tookIt")
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
        #expect(Self.answer(of: mechanism.ignoringApps?.call, action) == "going down")
        #expect(ran.withLock { $0 } == [["/sbin/shutdown", flag, "now"]])
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
