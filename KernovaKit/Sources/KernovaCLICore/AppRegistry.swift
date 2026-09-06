import AppKit
import Foundation

// MARK: - The registry

/// One instance of an app as Launch Services still holds it.
protocol RegisteredAppInstance: Sendable {
    /// Whether Launch Services has recorded the instance as exited.
    var hasTerminated: Bool { get }

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
    /// Copies sharing an identifier are filtered out by path: the tool opens
    /// the bundle it is embedded in, so another Kernova elsewhere on disk is
    /// not what a relaunch of this one collides with.
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

    func observeTermination(_ notify: @escaping @Sendable () -> Void) -> TerminationObservation {
        let token = application.observe(\.isTerminated) { _, _ in notify() }
        return TerminationObservation { token.invalidate() }
    }
}

// MARK: - The wait

/// Waiting until Launch Services has let a bundle's last instance go.
enum AppRegistryWait {
    /// Blocks until the registry holds no live instance of the bundle at
    /// `bundleURL`, or `deadline` seconds pass.
    ///
    /// Runs the calling thread's run loop rather than parking it, and must be
    /// called from the main thread: `NSRunningApplication`'s time-varying
    /// properties advance only on a turn of the main run loop in a common mode
    /// (AppKit's `NSRunningApplication` class documentation), so a parked
    /// thread would never see the registration it is waiting on change.
    ///
    /// - Throws: ``CLIFailure`` with ``CLIExitCode/timedOut`` when the deadline
    ///   passes with an instance still registered.
    static func awaitDeregistration(
        ofBundleAt bundleURL: URL,
        within deadline: TimeInterval = ConnectBackoff.defaultDeadline,
        registry: any AppRegistry = LaunchServicesRegistry()
    ) throws {
        let instances = registry.instances(ofBundleAt: bundleURL)
        let settled = { instances.allSatisfy { $0.hasTerminated } }
        guard !settled() else { return }

        let waker = RunLoopWaker(CFRunLoopGetCurrent())
        let observations = instances.map { $0.observeTermination { waker.wake() } }
        let expiry = Date(timeIntervalSinceNow: deadline)
        let released = withExtendedLifetime(observations) { () -> Bool in
            runCurrentLoop(until: expiry, while: { !settled() })
            return settled()
        }

        guard released else {
            throw CLIFailure(
                .timedOut,
                "Kernova has quit, but macOS still had it registered \(Int(deadline)) seconds "
                    + "later. Starting it again now may fail.")
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
