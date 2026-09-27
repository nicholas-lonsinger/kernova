import AppKit
import IOKit
import IOKit.pwr_mgt
import KernovaLogging

/// Delivers system sleep and wake to one handler, holding each sleep until
/// the handler allows it.
///
/// The hold is the root power domain's: a client of
/// `IORegisterForSystemPower` must acknowledge `kIOMessageSystemWillSleep`
/// with `IOAllowPowerChange`, and "if a caller does not acknowledge the sleep
/// notification, the sleep will continue anyway after a 30 second timeout"
/// (`IORegisterForSystemPower` in `IOKit/pwr_mgt/IOPMLib.h`). That timeout is the only bound
/// on the hold. Where the registration is refused, sleep and wake arrive
/// through `NSWorkspace` instead and nothing holds sleep.
///
/// One per process, made by the composition root. Untested by construction
/// rather than by omission: a test process cannot put the machine to sleep.
@MainActor
final class SystemSleepWatcher {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "SystemSleepWatcher")

    /// Runs in the turn the system announces sleep; the system sleeps once it
    /// calls `allowSleep`, or once the platform stops waiting.
    typealias SleepHandler = @MainActor (_ allowSleep: @escaping @MainActor () -> Void) -> Void
    /// Runs in the turn the system announces it has woken.
    typealias WakeHandler = @MainActor () -> Void

    private var handlers: (sleep: SleepHandler, wake: WakeHandler)?

    private enum Source {
        case rootPowerDomain(RootPowerDomainRegistration)
        /// The fallback: notifications only, with no hold.
        case workspace([any NSObjectProtocol])
    }

    private var source: Source?

    /// The sleep the root power domain is holding for the handler — until the
    /// handler allows it, or the system wakes from a sleep that stopped
    /// waiting.
    private var heldSleep: HeldSleep?

    private final class HeldSleep {
        let notificationID: Int
        init(notificationID: Int) { self.notificationID = notificationID }
    }

    init() {}

    isolated deinit {
        switch source {
        case .rootPowerDomain(let registration):
            registration.end()
        case .workspace(let observers):
            for observer in observers {
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
            }
        case nil:
            break
        }
    }

    /// Starts delivering sleep and wake to the handlers; call once.
    func start(onSleep: @escaping SleepHandler, onWake: @escaping WakeHandler) {
        assert(handlers == nil, "SystemSleepWatcher started twice")
        handlers = (onSleep, onWake)
        if let registration = RootPowerDomainRegistration(relayingTo: self) {
            source = .rootPowerDomain(registration)
            #log(Self.logger, .notice, "Registered for system power; sleep waits for the sleep handler")
        } else {
            source = .workspace(observeWorkspace())
            #log(
                Self.logger, .error,
                "The system refused the power registration; sleep and wake arrive from NSWorkspace, and sleep does not wait for the sleep handler"
            )
        }
    }

    // MARK: - Root Power Domain

    /// Handles one message the root power domain sent to this process.
    fileprivate func received(_ message: UInt32, notificationID: Int) {
        guard case .rootPowerDomain(let registration) = source else { return }
        switch message {
        case SystemPowerMessage.canSystemSleep:
            // An idle sleep asks first; answering at once never vetoes it.
            IOAllowPowerChange(registration.connection, notificationID)
        case SystemPowerMessage.systemWillSleep:
            let sleep = HeldSleep(notificationID: notificationID)
            heldSleep = sleep
            #log(Self.logger, .notice, "System will sleep — holding sleep for the sleep handler")
            deliverSleep { [weak self] in self?.allow(sleep) }
        case SystemPowerMessage.systemHasPoweredOn:
            if heldSleep != nil {
                heldSleep = nil
                #log(Self.logger, .notice, "System woke before the sleep handler allowed sleep")
            }
            deliverWake()
        default:
            break
        }
    }

    /// Acknowledges `sleep` — nothing once the system has woken from it.
    private func allow(_ sleep: HeldSleep) {
        guard heldSleep === sleep, case .rootPowerDomain(let registration) = source else { return }
        heldSleep = nil
        IOAllowPowerChange(registration.connection, sleep.notificationID)
        #log(Self.logger, .notice, "Allowed system sleep")
    }

    // MARK: - NSWorkspace

    private func observeWorkspace() -> [any NSObjectProtocol] {
        let center = NSWorkspace.shared.notificationCenter
        let sleep = center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                #log(Self.logger, .notice, "System will sleep — nothing holds it")
                self?.deliverSleep {}
            }
        }
        let wake = center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.deliverWake() }
        }
        return [sleep, wake]
    }

    // MARK: - Delivery

    private func deliverSleep(allowing allowSleep: @escaping @MainActor () -> Void) {
        guard let onSleep = handlers?.sleep else { return allowSleep() }
        onSleep(allowSleep)
    }

    private func deliverWake() {
        #log(Self.logger, .notice, "System did wake — invoking wake handler")
        handlers?.wake()
    }
}

/// The system sleep and wake messages `IORegisterForSystemPower` delivers.
///
/// `IOKit/IOMessage.h` defines each as `iokit_common_msg(n)`, a macro Swift
/// does not import: `sys_iokit` (`err_system(0x38)`, so `0xE0000000`) or'd with
/// `sub_iokit_common` (`0`) and `n`.
private enum SystemPowerMessage {
    static let canSystemSleep: UInt32 = 0xE000_0270
    static let systemWillSleep: UInt32 = 0xE000_0280
    static let systemHasPoweredOn: UInt32 = 0xE000_0300
}

/// This process's registration with the root power domain, delivering its
/// messages on the main queue to the watcher it relays to.
@MainActor
private final class RootPowerDomainRegistration {
    /// The session with the root power domain, which every acknowledgement
    /// names.
    let connection: io_connect_t
    private var notifier: io_object_t
    private let port: IONotificationPortRef

    /// What the callback's `refcon` points at — retained until ``end()`` has
    /// stopped the messages — and a weak path to the watcher.
    private let relay: Unmanaged<Relay>

    private final class Relay {
        weak var watcher: SystemSleepWatcher?
        init(_ watcher: SystemSleepWatcher) { self.watcher = watcher }
    }

    /// Registers, or answers `nil` when the system refuses.
    init?(relayingTo watcher: SystemSleepWatcher) {
        let relay = Unmanaged.passRetained(Relay(watcher))
        var port: IONotificationPortRef?
        var notifier: io_object_t = 0
        let connection = IORegisterForSystemPower(
            relay.toOpaque(), &port,
            { refcon, _, message, argument in
                // `IONotificationPortSetDispatchQueue(_, .main)` below is what
                // puts this on the main queue.
                let refconBits = Int(bitPattern: refcon)
                let notificationID = Int(bitPattern: argument)
                MainActor.assumeIsolated {
                    guard let refcon = UnsafeMutableRawPointer(bitPattern: refconBits) else { return }
                    Unmanaged<Relay>.fromOpaque(refcon).takeUnretainedValue().watcher?
                        .received(message, notificationID: notificationID)
                }
            }, &notifier)
        guard connection != 0, let port else {
            relay.release()
            return nil
        }
        IONotificationPortSetDispatchQueue(port, .main)
        self.connection = connection
        self.notifier = notifier
        self.port = port
        self.relay = relay
    }

    /// Deregisters in the order `IORegisterForSystemPower`'s documentation
    /// gives, which stops the messages, then lets the relay go.
    func end() {
        IODeregisterForSystemPower(&notifier)
        IOServiceClose(connection)
        IONotificationPortDestroy(port)
        relay.release()
    }
}
