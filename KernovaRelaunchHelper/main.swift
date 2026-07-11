import AppKit
import os

// KernovaRelaunchHelper
//
// A lightweight watchdog that monitors the main Kernova process and relaunches
// it after termination. Used when macOS TCC forces a restart while VMs are
// saving state, which exceeds TCC's built-in relaunch timeout.
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

@MainActor
func relaunchApp() async {
    // Brief delay to let LaunchServices finish cleaning up the terminated process.
    // Without this, NSWorkspace may fail with "0 items" because the old process
    // registration hasn't been fully removed yet.
    try? await Task.sleep(for: .seconds(1))

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true

    // Retry with backoff — LaunchServices may need additional time to update
    // after process exit. Total retry window is ~7 seconds.
    for attempt in 1...4 {
        do {
            try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            logger.notice("Relaunched Kernova successfully (attempt \(attempt, privacy: .public))")
            exit(0)
        } catch {
            logger.warning(
                "Relaunch attempt \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            if attempt < 4 {
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // RATIONALE: No /usr/bin/open fallback. The helper runs sandboxed
    // (app-sandbox + inherit), so a spawned `open` would inherit the same
    // sandbox and reach LaunchServices through the same mediated path as
    // NSWorkspace — no added capability, just an exec for App Review to
    // question.
    logger.error("Failed to relaunch Kernova after 4 attempts, giving up")
    exit(1)
}

// MARK: - PID monitoring

logger.notice("Watching PID \(pid, privacy: .public) for exit, will relaunch \(appPath, privacy: .private)")

// Set up the watcher FIRST to close the TOCTOU race window. If the app dies
// during setup, the source catches it. If it was already dead, the subsequent
// kill check catches it.
let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)

source.setEventHandler {
    logger.notice("PID \(pid, privacy: .public) exited, relaunching Kernova")
    source.cancel()
    Task { @MainActor in
        await relaunchApp()
    }
}

source.resume()

// NOW check if the PID exited before the watcher was attached.
if kill(pid, 0) != 0, errno == ESRCH {
    logger.notice("PID \(pid, privacy: .public) already exited, relaunching immediately")
    source.cancel()
    Task { @MainActor in
        await relaunchApp()
    }
}

// Safety timeout — relaunchApp() calls exit(0) on success, so this only fires
// if something unexpected prevents the relaunch from completing.
DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
    logger.warning("Timeout waiting for PID \(pid, privacy: .public) to exit, giving up")
    source.cancel()
    exit(1)
}

RunLoop.main.run()
