import AppKit
import Darwin
import Foundation

// MARK: - Process liveness

/// Whether the kernel still has a process under `identifier`.
///
/// `ESRCH` is the one answer that means gone: success and `EPERM` both name a
/// process that is there, and any other errno is a question the probe could not
/// answer. Everything it cannot tell counts as running, `identifier` values of
/// zero and below included — those name no process to ask about, and a caller
/// waiting for something to disappear must not read "no pid yet" as "gone".
///
/// A process that has exited and not yet been reaped answers as running.
///
/// The App Sandbox permits the probe: `kill(_:0)` reaches the kernel's process
/// table rather than the target (verified 2026-09-06 against an ad-hoc
/// `com.apple.security.app-sandbox` signature on macOS 27).
public func processIsRunning(_ identifier: pid_t) -> Bool {
    guard identifier > 0 else { return true }
    errno = 0
    return !(kill(identifier, 0) == -1 && errno == ESRCH)
}

// MARK: - Scope

/// Which of a bundle's registered instances a deregistration wait is about.
public enum RegisteredInstanceScope: Sendable {
    /// Every instance registered for the bundle.
    ///
    /// For a caller that watched the app exit: the registration is stale from
    /// that moment, including the sliver where the kernel has not finished
    /// reaping the process.
    case all

    /// Only instances whose process is already gone.
    ///
    /// For a caller that did not watch it exit, so an app that is merely slow
    /// to answer is left alone rather than waited out to the deadline. The
    /// scope opens once the kernel has reaped the process: one that has exited
    /// and not yet been reaped still answers as running.
    case exitedProcesses
}

// MARK: - The registry

/// One instance of an app as Launch Services still holds it.
protocol RegisteredAppInstance: Sendable {
    /// Whether Launch Services has recorded the instance as exited.
    var hasTerminated: Bool { get }

    /// Whether the kernel has no process under this instance's identifier.
    ///
    /// Runs ahead of ``hasTerminated`` by the lag a wait exists to cover, and
    /// answers `false` whenever it cannot tell.
    var processHasExited: Bool { get }

    /// Calls `notify` whenever ``hasTerminated`` may have changed, until the
    /// returned observation is released.
    func observeTermination(_ notify: @escaping @Sendable () -> Void) -> TerminationObservation
}

/// Holds one termination observation; releasing it ends the observation.
final class TerminationObservation {
    private let end: () -> Void

    /// Creates an observation that runs `end` when it goes away.
    init(end: @escaping () -> Void) { self.end = end }

    deinit { end() }
}

/// The registry `NSWorkspace.openApplication` consults to decide whether an app
/// is already running.
protocol AppRegistry: Sendable {
    /// Every instance the registry holds for the bundle at `bundleURL`.
    func instances(ofBundleAt bundleURL: URL) -> [any RegisteredAppInstance]

    /// The instance the registry holds for `identifier`, or `nil` when it holds
    /// none — an app it never registered, or one it has already let go.
    func instance(withProcessIdentifier identifier: pid_t) -> (any RegisteredAppInstance)?
}

/// Launch Services itself, read through `NSRunningApplication`.
///
/// **Main thread only, and a wait over this registry has to service the main
/// run loop.** `NSRunningApplication`'s time-varying properties "persist until
/// the next turn of the main run loop in a common mode" (AppKit's
/// `NSRunningApplication` class documentation), so an instance read here reports
/// the same `hasTerminated` forever unless that loop turns.
struct LaunchServicesRegistry: AppRegistry {
    /// The registered instances of that exact copy of the app.
    ///
    /// Copies sharing an identifier are filtered out by path: an open names the
    /// bundle it wants, so another Kernova elsewhere on disk is not what it
    /// collides with.
    func instances(ofBundleAt bundleURL: URL) -> [any RegisteredAppInstance] {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let identifier = Bundle(url: bundleURL)?.bundleIdentifier else { return [] }
        let wanted = bundleURL.resolvingSymlinksInPath().path
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.bundleURL?.resolvingSymlinksInPath().path == wanted }
            .map(RunningAppInstance.init)
    }

    func instance(withProcessIdentifier identifier: pid_t) -> (any RegisteredAppInstance)? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let application = NSRunningApplication(processIdentifier: identifier) else {
            return nil
        }
        return RunningAppInstance(application: application)
    }
}

/// One `NSRunningApplication` seen as a registry entry.
private struct RunningAppInstance: RegisteredAppInstance {
    let application: NSRunningApplication

    var hasTerminated: Bool { application.isTerminated }

    /// An instance Launch Services has registered without a process identifier
    /// yet reads as running, which is what keeps a wait off an app mid-launch.
    var processHasExited: Bool { !processIsRunning(application.processIdentifier) }

    func observeTermination(_ notify: @escaping @Sendable () -> Void) -> TerminationObservation {
        dispatchPrecondition(condition: .onQueue(.main))
        let token = application.observe(\.isTerminated) { _, _ in notify() }
        return TerminationObservation { token.invalidate() }
    }
}

extension RegisteredInstanceScope {
    /// Whether a wait in this scope is about `instance`.
    func admits(_ instance: any RegisteredAppInstance) -> Bool {
        switch self {
        case .all: true
        case .exitedProcesses: instance.processHasExited
        }
    }
}

// MARK: - The wait

/// Waiting until Launch Services has let a bundle's instances go.
///
/// `NSWorkspace.openApplication` reads the same registry, and Launch Services
/// keeps an exited instance in it for tens of milliseconds after the kernel
/// reaps the process. An open aimed at one of those fails with an
/// `NSWorkspace` error and macOS puts a "not open anymore" alert on screen, so
/// anything that opens an app it may have just watched exit waits here first.
public enum AppRegistryWait {
    /// How long a wait gives Launch Services before giving up, in seconds, for
    /// a caller with no budget of its own to spend.
    ///
    /// A stuck-state backstop rather than a sizing of the lag: the wait ends on
    /// the registry's own signal, and a release that has not arrived by here is
    /// not one a longer wait would collect.
    public static let defaultDeadline: TimeInterval = 20

    /// Blocks until the registry holds no instance of the bundle at
    /// `bundleURL` that `scope` admits, or `expiry` passes.
    ///
    /// Services the calling thread's run loop rather than parking it, so a
    /// registry whose readings only advance on a turn of that loop — every one
    /// backed by `NSRunningApplication`, see ``LaunchServicesRegistry`` — can
    /// report the change this is waiting for. Reach it from the run loop's base
    /// or a `RunLoop.main.perform` callout: nested inside a main-queue job the
    /// loop cannot drain that queue.
    ///
    /// - Returns: `true` once the registry has let go, `false` when `expiry`
    ///   passed with an admitted instance still registered.
    @discardableResult
    public static func awaitDeregistration(
        ofBundleAt bundleURL: URL,
        scope: RegisteredInstanceScope,
        by expiry: Date = Date(timeIntervalSinceNow: defaultDeadline)
    ) -> Bool {
        awaitDeregistration(
            ofBundleAt: bundleURL, scope: scope, by: expiry,
            registry: LaunchServicesRegistry())
    }

    /// ``awaitDeregistration(ofBundleAt:scope:by:)`` against a given registry.
    static func awaitDeregistration(
        ofBundleAt bundleURL: URL,
        scope: RegisteredInstanceScope,
        by expiry: Date,
        registry: any AppRegistry
    ) -> Bool {
        awaitDeregistration(
            of: registry.instances(ofBundleAt: bundleURL).filter { scope.admits($0) }, by: expiry)
    }

    /// Blocks until Launch Services has let the process `identifier` names go,
    /// or `expiry` passes.
    ///
    /// The key a caller holding a live connection should use: it names the
    /// instance actually on the other end, where a bundle path names whichever
    /// copies happen to share it. Registry-held instances only, so a pid the
    /// registry never had — anything but a registered app — is nothing to wait
    /// for.
    ///
    /// Same run-loop requirement as
    /// ``awaitDeregistration(ofBundleAt:scope:by:)``.
    ///
    /// - Returns: `true` once the registry has let go, `false` when `expiry`
    ///   passed with the instance still registered.
    @discardableResult
    public static func awaitDeregistration(
        ofProcess identifier: pid_t,
        by expiry: Date = Date(timeIntervalSinceNow: defaultDeadline)
    ) -> Bool {
        awaitDeregistration(
            ofProcess: identifier, by: expiry, registry: LaunchServicesRegistry())
    }

    /// ``awaitDeregistration(ofProcess:by:)`` against a given registry.
    static func awaitDeregistration(
        ofProcess identifier: pid_t,
        by expiry: Date,
        registry: any AppRegistry
    ) -> Bool {
        guard let instance = registry.instance(withProcessIdentifier: identifier) else {
            return true
        }
        return awaitDeregistration(of: [instance], by: expiry)
    }

    /// The one wait: park on the run loop until every instance reports
    /// terminated, waking on each instance's own notification.
    private static func awaitDeregistration(
        of instances: [any RegisteredAppInstance], by expiry: Date
    ) -> Bool {
        let settled = { instances.allSatisfy { $0.hasTerminated } }
        guard !settled() else { return true }

        let waker = RunLoopWaker(CFRunLoopGetCurrent())
        let observations = instances.map { $0.observeTermination { waker.wake() } }
        return withExtendedLifetime(observations) { () -> Bool in
            runCurrentLoop(until: expiry, while: { !settled() })
            return settled()
        }
    }

    /// Runs the calling thread's run loop until `keepWaiting` stops holding or
    /// `expiry` passes.
    ///
    /// The timer is what keeps the mode occupied: a run loop with nothing in it
    /// finishes the instant it is asked to run, which would turn each turn of
    /// this loop into a spin.
    private static func runCurrentLoop(until expiry: Date, while keepWaiting: () -> Bool) {
        let timer = Timer(fire: expiry, interval: 0, repeats: false) { _ in }
        RunLoop.current.add(timer, forMode: .default)
        defer { timer.invalidate() }
        while keepWaiting() {
            let remaining = expiry.timeIntervalSinceNow
            guard remaining > 0 else { return }
            CFRunLoopRunInMode(.defaultMode, remaining, false)
        }
    }
}

/// Wakes the run loop a wait is parked on, from whichever thread the registry's
/// notification lands on.
private final class RunLoopWaker: @unchecked Sendable {
    private let loop: CFRunLoop

    init(_ loop: CFRunLoop) { self.loop = loop }

    /// Schedules the stop on the loop before waking it, so a notification that
    /// arrives before the loop starts running still ends the wait.
    func wake() {
        let loop = self.loop
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { CFRunLoopStop(loop) }
        CFRunLoopWakeUp(loop)
    }
}
