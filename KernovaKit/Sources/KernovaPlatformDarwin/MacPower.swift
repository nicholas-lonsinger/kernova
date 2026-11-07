#if os(macOS)
import CoreServices
import Darwin
import Dispatch
import Foundation
import KernovaAgentCore
import KernovaAgentInstall
import KernovaAgentRuntime
import KernovaLogging
import KernovaSynchronization
import KernovaWire

/// How a macOS peer's power call answered.
enum MacPowerAnswer: Sendable, Equatable {
    /// The OS took the request and is going down.
    case tookIt
    /// Nothing was done, for this reason.
    case refused(WireError)
    /// The answer does not say whether the OS took the request.
    case unconfirmed
}

/// How a macOS peer asks its OS to shut down: the shutdown that asks apps to quit, which only the session peer
/// has, and the one that does not wait for apps, which only the system peer has. Shutdown is the only action a
/// macOS peer offers, because the host restarts a guest by shutting it down and booting it again.
struct MacPowerMechanism: Sendable {
    /// The blocking shutdown call, by when it says the OS has taken the request.
    enum Call: Sendable {
        /// A call whose answer says whether the OS took the request.
        case answering(@Sendable () -> MacPowerAnswer)
        /// A call the OS has taken once it starts, because it takes the OS down before it answers: its acceptance
        /// is reported before it starts, and it answers the failure that ended it, nil when the OS is going down.
        case committing(@Sendable () -> WireError?)
    }

    /// Shutdown through a call that asks running apps to quit, which may stop the request, offered only while the
    /// peer's session owns the console.
    struct Graceful: Sendable {
        /// Why it is not offered while the session does not own the console, for the host's log.
        let absentDetail: String
        /// Asks the OS to shut down, blocking until the call returns.
        let call: Call
    }

    /// The shutdown that asks apps to quit; nil for none.
    let graceful: Graceful?
    /// The shutdown performed without waiting for apps, in every console state; nil for none.
    let ignoringApps: Call?

    /// The session peer's: the Apple event loginwindow takes to shut down, while the session owns the console
    /// ([QA1134](https://developer.apple.com/library/archive/qa/qa1134/_index.html)). The sequence it starts "can
    /// be cancelled by running applications". In macOS 27.2 guests it always took loginwindow's
    /// reopen-windows path, whatever the user's setting, so unsaved documents came back at the next start; an app
    /// holding it showed its own prompt while the send still answered taken
    /// (`docs/research/2026-11-04-macos-shutdown-request-by-session-state.md`).
    static func loginWindow(send: @escaping @Sendable (NSAppleEventDescriptor) -> OSStatus = LoginWindowPower.send)
        -> MacPowerMechanism
    {
        MacPowerMechanism(
            graceful: Graceful(
                absentDetail: "this session does not own the console",
                call: .answering { LoginWindowPower.answer(send(LoginWindowPower.shutdownEvent())) }),
            ignoringApps: nil)
    }

    /// The system peer's: `shutdown(8)`, without waiting for apps, in every console state. It commits: in macOS
    /// 12.7.6 and 27.2 guests the peer logged nothing after starting it
    /// (`docs/research/2026-11-03-macos-guest-power-through-agents.md`). With a user logged in no app was asked
    /// anything, and the guest powered off (`docs/research/2026-11-03-macos-shutdown-without-waiting-for-apps.md`).
    static func shutdownCommand(run: @escaping @Sendable ([String]) -> Int32 = { Installer.spawn($0) })
        -> MacPowerMechanism
    {
        MacPowerMechanism(
            graceful: nil,
            ignoringApps: .committing { ShutdownCommand.failure(run(ShutdownCommand.arguments)) })
    }
}

/// A macOS peer's POWER: the mechanism's graceful shutdown while the peer's session owns the console, and its
/// shutdown without waiting for apps in every state; absent `NOT_ON_CONSOLE` when neither is offered.
public final class MacPowerAdapter: PowerAdapter {
    private static let logger = KernovaLogger(subsystem: "app.kernova.macosagent", category: "Power")

    private struct State {
        var reporter: PowerReporter?
        var console = ConsoleState.unknown
        /// The request whose call has not returned and that `cancel` has not let go, and whether it was
        /// reported accepted.
        var calling: (id: PowerRequestID, accepted: Bool)?
    }

    private let mechanism: MacPowerMechanism
    private let state = Locked(State())
    /// Makes every change and every report, so reports reach the runtime in the order made.
    private let queue: DispatchQueue
    /// Runs the mechanism's blocking call.
    private let callQueue: DispatchQueue

    /// The session peer's adapter.
    public static func sessionPeer() -> MacPowerAdapter { MacPowerAdapter(.loginWindow()) }

    /// The system peer's adapter.
    public static func systemPeer() -> MacPowerAdapter { MacPowerAdapter(.shutdownCommand()) }

    init(
        _ mechanism: MacPowerMechanism, queue: DispatchQueue = DispatchQueue(label: "app.kernova.macosagent.power"),
        callQueue: DispatchQueue = DispatchQueue(label: "app.kernova.macosagent.power.call")
    ) {
        self.mechanism = mechanism
        self.queue = queue
        self.callQueue = callQueue
    }

    /// The peer's console state is now `console`.
    public func consoleChanged(_ console: ConsoleState) {
        queue.async { [self] in
            let reporter = state.withLock { state -> PowerReporter? in
                guard state.console != console else { return nil }
                state.console = console
                return state.reporter
            }
            reporter?.report(.availability(availability(console)))
        }
    }

    /// Reports the advert of the console state given so far.
    public func start(reporter: PowerReporter) {
        queue.async { [self] in
            let console = state.withLock { state in
                state.reporter = reporter
                return state.console
            }
            reporter.report(.availability(availability(console)))
        }
    }

    /// Makes the mechanism's graceful call, refusing `NOT_ON_CONSOLE` while the session does not own the console;
    /// `ignoringApps`, the call that does not wait for apps, in any console state. Any action but shutdown, and a
    /// shutdown the mechanism does not offer that way, is refused `POWER_ACTION_UNSUPPORTED`.
    public func perform(_ id: PowerRequestID, _ action: PowerAction, ignoringApps: Bool) {
        queue.async { [self] in
            let (console, reporter) = state.withLock { ($0.console, $0.reporter) }
            guard action == .shutdown else {
                reporter?.report(.refused(id, WireError(.powerActionUnsupported)))
                return
            }
            let call: MacPowerMechanism.Call
            if ignoringApps {
                guard let offered = mechanism.ignoringApps else {
                    reporter?.report(.refused(id, WireError(.powerActionUnsupported)))
                    return
                }
                call = offered
            } else {
                guard let graceful = mechanism.graceful else {
                    reporter?.report(.refused(id, WireError(.powerActionUnsupported)))
                    return
                }
                guard console == .on else {
                    reporter?.report(.refused(id, WireError(.powerNotOnConsole, debugDetail: graceful.absentDetail)))
                    return
                }
                call = graceful.call
            }
            Self.logger.log(
                .notice,
                "Asking macOS to shut down\(ignoringApps ? " without waiting for apps" : "", privacy: .public)")
            switch call {
            case .answering(let call):
                state.withLock { $0.calling = (id, accepted: false) }
                callQueue.async { [self] in
                    let answer = call()
                    queue.async { [self] in answered(id, answer) }
                }
            case .committing(let call):
                state.withLock { $0.calling = (id, accepted: true) }
                // Queued to the runtime before the call starts, so it goes out ahead of the connection's close
                // that the OS going down brings.
                reporter?.report(.accepted(id))
                callQueue.async { [self] in
                    let failure = call()
                    queue.async { [self] in ended(id, failure) }
                }
            }
        }
    }

    /// A call blocked in the OS cannot be withdrawn, so a request still calling is let go unconfirmed, and its
    /// answer, when it comes, reports nothing. A request already reported accepted is its call's to end.
    public func cancel(_ id: PowerRequestID) {
        queue.async { [self] in
            let reporter = state.withLock { state -> PowerReporter? in
                guard let calling = state.calling, calling.id == id, !calling.accepted else { return nil }
                state.calling = nil
                return state.reporter
            }
            guard let reporter else { return }
            Self.logger.log(.notice, "A power request's deadline passed before macOS answered")
            reporter.report(.unconfirmed(id))
        }
    }

    /// The graceful shutdown while the session owns the console, beside the shutdown without waiting for apps in
    /// every state; absent `NOT_ON_CONSOLE` when that leaves nothing.
    private func availability(_ console: ConsoleState) -> Availability<PowerOffer> {
        let graceful = console == .on ? mechanism.graceful : nil
        guard graceful != nil || mechanism.ignoringApps != nil else {
            return .absent(.notOnConsole, debugDetail: mechanism.graceful?.absentDetail ?? "")
        }
        return .available(
            PowerOffer(
                actions: graceful == nil ? [] : [.shutdown], asksAppsToQuit: graceful != nil,
                ignoringApps: mechanism.ignoringApps == nil ? [] : [.shutdown]))
    }

    private func answered(_ id: PowerRequestID, _ answer: MacPowerAnswer) {
        Self.logger.log(.notice, "macOS answered the power request: \(String(describing: answer), privacy: .public)")
        guard let reporter = release(id) else { return }
        let reports: [PowerInput] =
            switch answer {
            case .tookIt: [.accepted(id), .handedOff(id)]
            case .refused(let error): [.refused(id, error)]
            case .unconfirmed: [.unconfirmed(id)]
            }
        for report in reports { reporter.report(report) }
    }

    private func ended(_ id: PowerRequestID, _ failure: WireError?) {
        Self.logger.log(
            .notice,
            "The power request's call returned: \(failure.map { String(describing: $0) } ?? "going down", privacy: .public)"
        )
        release(id)?.report(failure.map { .failed(id, $0) } ?? .handedOff(id))
    }

    /// Lets go of request `id` once its call returns, answering the reporter its end goes to, or nil when it was
    /// let go already.
    private func release(_ id: PowerRequestID) -> PowerReporter? {
        state.withLock { state in
            guard state.calling?.id == id else { return nil }
            state.calling = nil
            return state.reporter
        }
    }
}

// MARK: - loginwindow

/// The Apple event loginwindow takes to shut down, sent through public Apple Event API.
enum LoginWindowPower {
    /// loginwindow's bundle identifier.
    static let bundleIdentifier = "com.apple.loginwindow"

    /// The event asking loginwindow to shut down: `kAEShutDown` in `kCoreEventClass`.
    static func shutdownEvent() -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEShutDown),
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }

    /// Sends `event` with no reply, as QA1134's sample does, and answers the send's error.
    @Sendable static func send(_ event: NSAppleEventDescriptor) -> OSStatus {
        do {
            _ = try event.sendEvent(options: [.noReply], timeout: TimeInterval(kAEDefaultTimeout))
            return noErr
        } catch {
            return OSStatus((error as NSError).code)
        }
    }

    /// What the send's `status` says of the request: delivered is taken, as QA1134 reads it.
    static func answer(_ status: OSStatus) -> MacPowerAnswer {
        switch Int(status) {
        case Int(noErr): .tookIt
        case errAEEventNotPermitted:
            .refused(WireError(.powerNotPermitted, debugDetail: "the Apple event to loginwindow is not permitted"))
        case procNotFound, connectionInvalid:
            .refused(WireError(.powerOsFailed, debugDetail: "loginwindow did not take the Apple event: \(status)"))
        default: .unconfirmed
        }
    }
}

// MARK: - shutdown(8)

/// `shutdown(8)`, which the system peer runs as root.
enum ShutdownCommand {
    /// The command line asking to shut down now: `-h` halts, which powers the machine off.
    static let arguments = ["/sbin/shutdown", "-h", "now"]

    /// The failure `status`, as `Installer.spawn(_:)` answers it, reports, nil for none: `shutdown` exits 0 once
    /// it has asked the system to go down.
    static func failure(_ status: Int32) -> WireError? {
        switch status {
        case 0: nil
        case -1: WireError(.powerOsFailed, debugDetail: "shutdown could not start")
        case 1..<128: WireError(.powerOsFailed, debugDetail: "shutdown exited \(status)")
        default: WireError(.powerOsFailed, debugDetail: "shutdown ended by signal \(status - 128)")
        }
    }
}

// MARK: - Session end

/// Why loginwindow quits the session peer.
public enum MacAgentQuit {
    /// The status the session peer exits with when `event`, the quit Apple event NSApplication is handling,
    /// asks it to quit: a quit whose reason (`kAEQuitReason`) is the session or the machine going down — which an
    /// app may still cancel — relaunches through launchd's `KeepAlive`; any other quit is the user's, and stops
    /// it.
    public static func exitStatus(for event: NSAppleEventDescriptor?) -> Int32 {
        sessionEnding(reason(of: event)) ? MacAgentPeer.relaunchStatus : 0
    }

    /// `event`'s quit reason, read as an attribute or a parameter.
    public static func reason(of event: NSAppleEventDescriptor?) -> OSType? {
        guard let event, event.eventClass == AEEventClass(kCoreEventClass),
            event.eventID == AEEventID(kAEQuitApplication)
        else { return nil }
        let descriptor =
            event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))
            ?? event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))
        guard let descriptor else { return nil }
        return descriptor.enumCodeValue != 0 ? descriptor.enumCodeValue : descriptor.typeCodeValue
    }

    /// Whether `reason` is a log out, shut down or restart: the reasons `AERegistry.h` lists for a quit other
    /// than `kAEQuitAll`.
    static func sessionEnding(_ reason: OSType?) -> Bool {
        guard let reason else { return false }
        return [OSType(kAEShutDown), OSType(kAERestart), OSType(kAEReallyLogOut)].contains(reason)
    }
}
#endif
