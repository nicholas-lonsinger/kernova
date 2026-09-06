import AppKit
import KernovaAppRegistry
import os

// A watchdog that monitors the main Kernova process and relaunches it after
// termination. Used when macOS TCC forces a restart while VMs are saving state,
// which exceeds TCC's built-in relaunch timeout.
//
// Usage: KernovaRelaunchHelper <pid> <app-bundle-path>

/// Waits for one process to exit, waits for Launch Services to let its app go,
/// and opens the app again.
///
/// A type rather than top-level functions and variables: a `func` declared at
/// the top level of `main.swift` is a *local* function, so a run-loop callout
/// or dispatch handler that names one captures it as a non-`Sendable` function
/// value. Static methods are named through the type and capture nothing.
@MainActor
enum Relauncher {
    nonisolated private static let logger = Logger(
        subsystem: "app.kernova", category: "RelaunchHelper")

    /// How long the app is given to exit, in seconds.
    ///
    /// It bounds that wait alone. The relaunch behind it carries its own
    /// deadline, so no two of these run at once and each says what it waited on.
    private static let exitWatchSeconds: TimeInterval = 15

    private static var appURL = URL(fileURLWithPath: "/")
    private static var watched: pid_t = 0
    private static var source: (any DispatchSourceProcess)?
    private static var exitWatchTimeout: DispatchWorkItem?

    /// Reports how the tool is called and exits.
    nonisolated static func refuseUsage() -> Never {
        logger.error("Usage: KernovaRelaunchHelper <pid> <app-bundle-path>")
        exit(1)
    }

    /// Reports a bundle that is not where the caller said and exits.
    nonisolated static func refuseMissingBundle(at path: String) -> Never {
        logger.error("App bundle not found: \(path, privacy: .private)")
        exit(1)
    }

    /// Watches `pid`, and reopens the bundle at `appURL` once it has gone.
    static func watch(pid: pid_t, appURL bundleURL: URL) {
        appURL = bundleURL
        watched = pid
        logger.notice(
            "Watching PID \(pid, privacy: .public) for exit, will relaunch \(bundleURL.path, privacy: .private)"
        )

        // Set up the watcher FIRST to close the TOCTOU race window: a death
        // during setup is caught by the source, an earlier one by the liveness
        // check below.
        let watcher = DispatchSource.makeProcessSource(
            identifier: pid, eventMask: .exit, queue: .main)
        source = watcher
        watcher.setEventHandler {
            MainActor.assumeIsolated {
                logger.notice("PID \(pid, privacy: .public) exited, relaunching Kernova")
                begin()
            }
        }
        watcher.resume()

        let timeout = DispatchWorkItem { MainActor.assumeIsolated { giveUpOnExit() } }
        exitWatchTimeout = timeout

        // NOW check if the PID exited before the watcher was attached.
        if !processIsRunning(pid) {
            logger.notice("PID \(pid, privacy: .public) already exited, relaunching immediately")
            begin()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + exitWatchSeconds, execute: timeout)
    }

    /// Ends the exit watch and hands the relaunch to a run-loop callout, never a
    /// main-queue job: the relaunch waits on a nested run loop, and one entered
    /// from inside a main-queue job cannot drain that queue.
    private static func begin() {
        exitWatchTimeout?.cancel()
        source?.cancel()
        RunLoop.main.perform { MainActor.assumeIsolated { relaunch() } }
    }

    /// Gives up on an app that never exited, leaving it running.
    private static func giveUpOnExit() {
        logger.warning(
            "PID \(watched, privacy: .public) had not exited after \(Int(exitWatchSeconds), privacy: .public) s; not relaunching"
        )
        source?.cancel()
        exit(1)
    }

    /// Waits for Launch Services to release the app's registration, then opens
    /// it.
    ///
    /// Runs from a run-loop callout, which is what lets the wait service the
    /// main run loop.
    private static func relaunch() {
        let deadline = Date(timeIntervalSinceNow: AppRegistryWait.defaultDeadline)
        if !AppRegistryWait.awaitDeregistration(ofBundleAt: appURL, scope: .all, by: deadline) {
            logger.warning(
                "Launch Services still had Kernova registered after \(Int(AppRegistryWait.defaultDeadline), privacy: .public) s; opening anyway"
            )
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            guard let error else {
                logger.notice("Relaunched Kernova successfully")
                exit(0)
            }
            // RATIONALE: the helper is app-sandbox + inherit
            // (KernovaRelaunchHelper.entitlements), so a spawned `/usr/bin/open`
            // inherits that sandbox and reaches LaunchServices through the same
            // mediated path `NSWorkspace` already took — it adds no capability
            // this open lacks.
            logger.error(
                "Failed to relaunch Kernova: \(error.localizedDescription, privacy: .public)")
            exit(1)
        }
    }
}

// MARK: - Entry

guard CommandLine.arguments.count == 3, let watchedPID = pid_t(CommandLine.arguments[1]) else {
    Relauncher.refuseUsage()
}

let appPath = CommandLine.arguments[2]

guard FileManager.default.fileExists(atPath: appPath) else {
    Relauncher.refuseMissingBundle(at: appPath)
}

Relauncher.watch(pid: watchedPID, appURL: URL(fileURLWithPath: appPath))

RunLoop.main.run()
