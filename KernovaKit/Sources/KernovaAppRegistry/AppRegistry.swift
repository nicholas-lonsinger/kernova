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

/// One instance of an app as Launch Services held it when the registry was read.
protocol RegisteredAppInstance: Sendable {
    /// The process the instance runs as; zero or below while it has none.
    var processIdentifier: pid_t { get }

    /// Whether Launch Services had recorded the instance as exited.
    ///
    /// A fresh read can return an instance already recorded as exited before
    /// it returns none at all.
    var hasTerminated: Bool { get }

    /// Whether the kernel has no process under this instance's identifier.
    ///
    /// Runs ahead of ``hasTerminated`` by the lag a wait exists to cover, and
    /// answers `false` whenever it cannot tell.
    var processHasExited: Bool { get }
}

/// The registry `NSWorkspace.openApplication` consults to decide whether an app
/// is already running.
protocol AppRegistry: Sendable {
    /// Every instance the registry holds for the bundle at `bundleURL`.
    func instances(ofBundleAt bundleURL: URL) -> [any RegisteredAppInstance]

    /// The instance the registry holds for `identifier`, or `nil` when it holds
    /// none — an app it never registered, one it has already let go, or an
    /// `identifier` of zero or below, which names no process.
    ///
    /// Asks the registry afresh on every call.
    func instance(withProcessIdentifier identifier: pid_t) -> (any RegisteredAppInstance)?
}

/// Launch Services itself, read through `NSRunningApplication`.
///
/// An instance once read goes stale: `NSRunningApplication`'s time-varying
/// properties "persist until the next turn of the main run loop in a common
/// mode" (AppKit's `NSRunningApplication` class documentation), and not even
/// that turn delivers a notice Launch Services sent before this process's
/// channel to it connected. A new `NSRunningApplication(processIdentifier:)` is
/// the fresh read: it answers `nil` once Launch Services lets the process go,
/// with the main run loop never turning, while an instance taken before the
/// exit still reports `isTerminated == false` (observed 2026-10-27 on macOS 27
/// against a background-only app).
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

    func instance(withProcessIdentifier identifier: pid_t) -> (any RegisteredAppInstance)? {
        guard identifier > 0,
            let application = NSRunningApplication(processIdentifier: identifier)
        else { return nil }
        return RunningAppInstance(application: application)
    }
}

/// One `NSRunningApplication` seen as a registry entry.
private struct RunningAppInstance: RegisteredAppInstance {
    let application: NSRunningApplication

    var processIdentifier: pid_t { application.processIdentifier }

    var hasTerminated: Bool { application.isTerminated }

    /// An instance Launch Services has registered without a process identifier
    /// yet reads as running, which is what keeps a wait off an app mid-launch.
    var processHasExited: Bool { !processIsRunning(application.processIdentifier) }
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
    /// A stuck-state backstop rather than a sizing of the lag: a release that
    /// has not arrived by here is not one a longer wait would collect.
    public static let defaultDeadline: TimeInterval = 20

    /// How long a wait sleeps after its first read before reading again, in
    /// seconds; each later sleep doubles, up to ``maximumRereadDelay``.
    static let initialRereadDelay: TimeInterval = 0.025

    /// The longest a wait sleeps between two reads, in seconds.
    static let maximumRereadDelay: TimeInterval = 1

    /// Blocks the calling thread until the registry has let go of every
    /// instance of the bundle at `bundleURL` that `scope` admits when the wait
    /// begins, or `expiry` passes; an instance registered later does not
    /// extend the wait.
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

    /// ``awaitDeregistration(ofBundleAt:scope:by:)`` against a given registry,
    /// clock, and sleep.
    static func awaitDeregistration(
        ofBundleAt bundleURL: URL,
        scope: RegisteredInstanceScope,
        by expiry: Date,
        registry: any AppRegistry,
        now: () -> Date = Date.init,
        sleep: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)
    ) -> Bool {
        awaitDeregistration(
            of: registry.instances(ofBundleAt: bundleURL).filter { scope.admits($0) }
                .map(\.processIdentifier),
            in: registry, by: expiry, now: now, sleep: sleep)
    }

    /// Blocks the calling thread until Launch Services has let the process
    /// `identifier` names go, or `expiry` passes.
    ///
    /// The key a caller holding a live connection should use: it names the
    /// instance actually on the other end, where a bundle path names whichever
    /// copies happen to share it. Registry-held instances only, so a pid the
    /// registry never had — anything but a registered app — is nothing to wait
    /// for.
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

    /// ``awaitDeregistration(ofProcess:by:)`` against a given registry, clock,
    /// and sleep.
    static func awaitDeregistration(
        ofProcess identifier: pid_t,
        by expiry: Date,
        registry: any AppRegistry,
        now: () -> Date = Date.init,
        sleep: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)
    ) -> Bool {
        awaitDeregistration(of: [identifier], in: registry, by: expiry, now: now, sleep: sleep)
    }

    /// The one wait: read `registry` afresh until it has let go of every one of
    /// `identifiers`, sleeping between reads on a doubling back-off from
    /// ``initialRereadDelay`` to ``maximumRereadDelay``.
    ///
    /// No sleep runs past `expiry`, and a read at `expiry` decides the result.
    /// An identifier of zero or below names no process, so it is not one to
    /// wait out.
    private static func awaitDeregistration(
        of identifiers: [pid_t], in registry: any AppRegistry, by expiry: Date,
        now: () -> Date, sleep: (TimeInterval) -> Void
    ) -> Bool {
        let settled = {
            identifiers.allSatisfy {
                $0 <= 0 || (registry.instance(withProcessIdentifier: $0)?.hasTerminated ?? true)
            }
        }
        var delay = initialRereadDelay
        while !settled() {
            let remaining = expiry.timeIntervalSince(now())
            guard remaining > 0 else { return false }
            sleep(min(delay, remaining))
            delay = min(delay * 2, maximumRereadDelay)
        }
        return true
    }
}
