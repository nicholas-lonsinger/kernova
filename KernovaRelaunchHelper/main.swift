import AppKit
import KernovaKit
import os

// A watchdog that monitors the main Kernova process and relaunches it after
// termination. Used when macOS TCC forces a restart while VMs are saving state,
// which exceeds TCC's built-in relaunch timeout.
//
// Usage: KernovaRelaunchHelper <pid> <app-bundle-path>

private let logger = Logger(subsystem: "app.kernova", category: "RelaunchHelper")

// MARK: - Argument parsing

guard CommandLine.arguments.count == 3,
    let pid = pid_t(CommandLine.arguments[1])
else {
    logger.error("Usage: KernovaRelaunchHelper <pid> <app-bundle-path>")
    exit(1)
}

let appPath = CommandLine.arguments[2]
let appURL = URL(fileURLWithPath: appPath)

guard FileManager.default.fileExists(atPath: appPath) else {
    logger.error("App bundle not found: \(appPath, privacy: .private)")
    exit(1)
}

// MARK: - Relaunch

/// Waits for Launch Services to release the app's registration, then opens it.
///
/// Must run from a run-loop callout, which is what lets the wait service the
/// main run loop.
@MainActor
func relaunchApp() {
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
        // mediated path `NSWorkspace` already took — it adds no capability this
        // open lacks.
        logger.error(
            "Failed to relaunch Kernova: \(error.localizedDescription, privacy: .public)")
        exit(1)
    }
}

// MARK: - PID monitoring

logger.notice("Watching PID \(pid, privacy: .public) for exit, will relaunch \(appPath, privacy: .private)")

/// How long the app is given to exit, in seconds.
///
/// It bounds that wait alone. The relaunch behind it carries its own deadline,
/// so no two of these run at once and each says what it waited on.
let exitWatchSeconds: TimeInterval = 15

// Set up the watcher FIRST to close the TOCTOU race window: a death during setup
// is caught by the source, an earlier one by the liveness check below.
let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)

let exitWatchTimeout = DispatchWorkItem {
    logger.warning(
        "PID \(pid, privacy: .public) had not exited after \(Int(exitWatchSeconds), privacy: .public) s; not relaunching"
    )
    source.cancel()
    exit(1)
}

/// Ends the exit watch and hands the relaunch to a run-loop callout, never a
/// main-queue job: the relaunch waits on a nested run loop, and one entered
/// from inside a main-queue job cannot drain that queue.
@MainActor
func beginRelaunch() {
    exitWatchTimeout.cancel()
    source.cancel()
    RunLoop.main.perform { MainActor.assumeIsolated { relaunchApp() } }
}

source.setEventHandler {
    logger.notice("PID \(pid, privacy: .public) exited, relaunching Kernova")
    // The source's queue is the main queue, so this is already the main thread.
    MainActor.assumeIsolated { beginRelaunch() }
}

source.resume()

// NOW check if the PID exited before the watcher was attached.
if !processIsRunning(pid) {
    logger.notice("PID \(pid, privacy: .public) already exited, relaunching immediately")
    beginRelaunch()
}

DispatchQueue.main.asyncAfter(deadline: .now() + exitWatchSeconds, execute: exitWatchTimeout)

RunLoop.main.run()
