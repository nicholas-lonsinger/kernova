import AppKit
import Foundation

// KernovaGuestAgent
//
// A guest-side agent that runs inside macOS virtual machines managed by
// Kernova. Maintains two long-lived vsock connections to the host: one for
// log forwarding (`VsockHostConnection`) and one for clipboard sync
// (`VsockGuestClipboardAgent`). Both reconnect automatically on disconnect.
//
// Usage: kernova-agent [--version]
// Designed to run as a macOS LaunchAgent (auto-start on login,
// auto-restart on crash).

private let logger = KernovaLogger(subsystem: "com.kernova.agent", category: "GuestAgent")

// MARK: - Version

private let version: String = {
    guard let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
        logger.fault("Version string not found in embedded Info.plist")
        assertionFailure("Version string not found in embedded Info.plist")
        return "unknown"
    }
    return v
}()

private let buildNumber: String = {
    guard let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String else {
        logger.fault("Build number not found in embedded Info.plist")
        assertionFailure("Build number not found in embedded Info.plist")
        return "unknown"
    }
    guard b != "AGENT_BUILD_NUMBER" else {
        logger.fault("Build number was not preprocessed — literal macro name found in Info.plist")
        assertionFailure("Build number was not preprocessed")
        return "unknown"
    }
    return b
}()

if CommandLine.arguments.contains("--version") {
    print("kernova-agent \(version) (\(buildNumber))")
    exit(0)
}

// MARK: - Vsock connections

/// Long-lived vsock connection to the host for log forwarding. Created and
/// registered with `VsockLogBridge` *before* the `logger.notice(...)`
/// startup banner emission below, so that banner is buffered into the
/// connection's pre-connect ring buffer rather than dropped.
///
/// Note: the `logger.fault(...)` calls inside the `version` and
/// `buildNumber` closures above run during top-level module init, before
/// this assignment, so those failure cases (broken `Info.plist`) only
/// reach local `os.Logger`. They're build-time issues that should never
/// fire in a properly packaged release; not worth complicating the
/// init order to forward them.
let vsockConnection = VsockHostConnection()
VsockLogBridge.connection = vsockConnection

logger.notice("Kernova Guest Agent v\(version, privacy: .public) (\(buildNumber, privacy: .public)) started")

/// Clipboard sync agent. Maintains its own connection on
/// `KernovaVsockPort.clipboard` independent of the log connection, so a
/// disconnect on one channel doesn't take the other down.
let clipboardAgent = VsockGuestClipboardAgent()

// MARK: - Signal Handling

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)

let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

let shutdownHandler: () -> Void = {
    logger.notice("Received termination signal, shutting down")
    clipboardAgent.stop()
    vsockConnection.stop()
    exit(0)
}

sigintSource.setEventHandler(handler: shutdownHandler)
sigtermSource.setEventHandler(handler: shutdownHandler)
sigintSource.resume()
sigtermSource.resume()

// MARK: - Start

vsockConnection.start()
clipboardAgent.start()
dispatchMain()
