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
    print("Usage: KernovaRelaunchHelper <pid> <app-bundle-path>", to: &standardError)
    exit(1)
}

let appPath = CommandLine.arguments[2]
let appURL = URL(fileURLWithPath: appPath)

guard FileManager.default.fileExists(atPath: appPath) else {
    print("App bundle not found: \(appPath)", to: &standardError)
    exit(1)
}

/// A `TextOutputStream` that writes to stderr, used with `print(..., to:)`.
private struct StandardError: TextOutputStream {
    mutating func write(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}

private var standardError = StandardError()

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
