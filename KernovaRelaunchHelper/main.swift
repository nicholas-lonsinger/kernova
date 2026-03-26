import AppKit
import os

// KernovaRelaunchHelper
//
// A lightweight watchdog that monitors the main Kernova process and relaunches
// it after termination. Used when macOS TCC forces a restart while VMs are
// saving state, which exceeds TCC's built-in relaunch timeout.
//
// Usage: KernovaRelaunchHelper <pid> <app-bundle-path>

private let logger = Logger(subsystem: "com.kernova.app", category: "RelaunchHelper")

// MARK: - Argument parsing

guard CommandLine.arguments.count == 3,
      let pid = pid_t(CommandLine.arguments[1]) else {
    fputs("Usage: KernovaRelaunchHelper <pid> <app-bundle-path>\n", stderr)
    exit(1)
}

let appPath = CommandLine.arguments[2]
let appURL = URL(fileURLWithPath: appPath)

guard FileManager.default.fileExists(atPath: appPath) else {
    fputs("App bundle not found: \(appPath)\n", stderr)
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
            logger.warning("Relaunch attempt \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            if attempt < 4 {
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // Last resort: the `open` CLI takes a different LaunchServices code path
    // and may succeed where the NSWorkspace API call fails.
    logger.notice("NSWorkspace failed after 4 attempts, falling back to /usr/bin/open")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", appPath]
    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            logger.notice("Relaunched Kernova via /usr/bin/open")
        } else {
            logger.error("/usr/bin/open exited with status \(process.terminationStatus, privacy: .public)")
        }
    } catch {
        logger.error("Failed to launch via /usr/bin/open: \(error.localizedDescription, privacy: .public)")
    }

    exit(0)
}

// MARK: - PID monitoring

logger.notice("Watching PID \(pid, privacy: .public) for exit, will relaunch \(appPath, privacy: .public)")

// Handle the race where the main app already exited before we started monitoring.
if kill(pid, 0) != 0, errno == ESRCH {
    logger.notice("PID \(pid, privacy: .public) already exited, relaunching immediately")
    Task { @MainActor in
        await relaunchApp()
    }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 10))
    exit(0)
}

let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)

source.setEventHandler {
    logger.notice("PID \(pid, privacy: .public) exited, relaunching Kernova")
    source.cancel()
    Task { @MainActor in
        await relaunchApp()
    }
}

source.resume()

RunLoop.main.run()
