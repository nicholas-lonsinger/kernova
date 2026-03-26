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
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true

    do {
        try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        logger.notice("Relaunched Kernova successfully")
    } catch {
        logger.error("Failed to relaunch Kernova: \(error.localizedDescription, privacy: .public)")
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
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 5))
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

// Safety timeout — prevent the helper from lingering indefinitely.
DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
    logger.warning("Timeout waiting for PID \(pid, privacy: .public) to exit, giving up")
    source.cancel()
    exit(1)
}

RunLoop.main.run()
