import AppKit
import Darwin
import Foundation

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
    /// to answer is left alone rather than waited out to the deadline.
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
}

/// Launch Services itself, read through `NSRunningApplication`.
struct LaunchServicesRegistry: AppRegistry {
    /// The registered instances of that exact copy of the app.
    ///
    /// Copies sharing an identifier are filtered out by path: an open names the
    /// bundle it wants, so another Kernova elsewhere on disk is not what it
    /// collides with.
    func instances(ofBundleAt bundleURL: URL) -> [any RegisteredAppInstance] {
        guard let identifier = Bundle(url: bundleURL)?.bundleIdentifier else { return [] }
        let wanted = bundleURL.resolvingSymlinksInPath().path
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.bundleURL?.resolvingSymlinksInPath().path == wanted }
            .map(RunningAppInstance.init)
    }
}

/// One `NSRunningApplication` seen as a registry entry.
private struct RunningAppInstance: RegisteredAppInstance {
    let application: NSRunningApplication

    var hasTerminated: Bool { application.isTerminated }

    /// `ESRCH` is the one answer that means gone: success and `EPERM` both name
    /// a process that is there, and any other errno is a question the probe
    /// could not answer, which leaves the instance alone.
    ///
    /// The App Sandbox permits this probe — `kill(_:0)` reaches the kernel's
    /// process table, not the target (verified 2026-09-06 against an ad-hoc
    /// `com.apple.security.app-sandbox` signature on macOS 27).
    var processHasExited: Bool {
        let identifier = application.processIdentifier
        guard identifier > 0 else { return true }
        errno = 0
        return kill(identifier, 0) == -1 && errno == ESRCH
    }

    func observeTermination(_ notify: @escaping @Sendable () -> Void) -> TerminationObservation {
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
    /// How long a wait gives Launch Services before giving up, in seconds.
    ///
    /// A stuck-state backstop rather than a sizing of the lag: the wait ends on
    /// the registry's own signal, and a release that has not arrived by here is
    /// not one a longer wait would collect.
    public static let defaultDeadline: TimeInterval = 20

    /// Blocks until the registry holds no instance of the bundle at
    /// `bundleURL` that `scope` admits, or `deadline` seconds pass.
    ///
    /// Runs the calling thread's run loop rather than parking it, and must be
    /// called from the main thread, at the run loop's base or from a
    /// `RunLoop.main.perform` callout: `NSRunningApplication`'s time-varying
    /// properties advance only on a turn of the main run loop in a common mode
    /// (AppKit's `NSRunningApplication` class documentation), so a parked
    /// thread would never see the registration it is waiting on change. Nested
    /// from inside a main-queue job it would not drain that queue, which is
    /// what the callout avoids.
    ///
    /// - Returns: `true` once the registry has let go, `false` when the
    ///   deadline passed with an admitted instance still registered.
    @discardableResult
    public static func awaitDeregistration(
        ofBundleAt bundleURL: URL,
        scope: RegisteredInstanceScope,
        within deadline: TimeInterval = defaultDeadline
    ) -> Bool {
        awaitDeregistration(
            ofBundleAt: bundleURL, scope: scope, within: deadline,
            registry: LaunchServicesRegistry())
    }

    /// ``awaitDeregistration(ofBundleAt:scope:within:)`` against a given
    /// registry.
    static func awaitDeregistration(
        ofBundleAt bundleURL: URL,
        scope: RegisteredInstanceScope,
        within deadline: TimeInterval,
        registry: any AppRegistry
    ) -> Bool {
        let instances = registry.instances(ofBundleAt: bundleURL).filter { scope.admits($0) }
        let settled = { instances.allSatisfy { $0.hasTerminated } }
        guard !settled() else { return true }

        let waker = RunLoopWaker(CFRunLoopGetCurrent())
        let observations = instances.map { $0.observeTermination { waker.wake() } }
        let expiry = Date(timeIntervalSinceNow: deadline)
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
