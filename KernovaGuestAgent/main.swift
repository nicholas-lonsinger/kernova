import AppKit
import Foundation

// KernovaGuestAgent
//
// A guest-side SPICE agent that runs inside macOS virtual machines managed by Kernova.
// Speaks the VDAgent clipboard protocol over the virtio console port, enabling
// bidirectional text clipboard sharing with the host.
//
// Usage: kernova-agent [--version]
// When run without flags, discovers the SPICE serial device and begins clipboard sharing.
// Designed to run as a macOS LaunchAgent (auto-start on login, auto-restart on crash).

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

// MARK: - Vsock connection

/// Long-lived vsock connection to the host, used for log forwarding (and
/// eventually clipboard / drag-drop). Independent from the SPICE agent —
/// either side can be down without affecting the other.
///
/// Created and registered with `VsockLogBridge` before the
/// `logger.notice(...)` startup banner emission below, so that banner is
/// buffered into the connection's pre-connect ring buffer rather than
/// dropped.
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

// MARK: - Signal Handling

// RATIONALE: nonisolated(unsafe) is correct here because all access to currentAgent occurs
// on the main dispatch queue (signal handlers, attemptConnection, onDisconnect callback).
// main.swift top-level code is nonisolated in Swift 6, making @MainActor impractical.
nonisolated(unsafe) var currentAgent: GuestClipboardAgent?

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)

let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

let shutdownHandler: () -> Void = {
    logger.notice("Received termination signal, shutting down")
    vsockConnection.stop()
    currentAgent?.stop()
    currentAgent = nil
    exit(0)
}

sigintSource.setEventHandler(handler: shutdownHandler)
sigtermSource.setEventHandler(handler: shutdownHandler)
sigintSource.resume()
sigtermSource.resume()

// MARK: - Device Discovery and Connect Loop

/// Retry interval when the device is not yet available or after a disconnect.
private let retryInterval: TimeInterval = 5.0

func attemptConnection() {
    guard let deviceHandle = SerialPortDiscovery.openDevice() else {
        logger.debug("SPICE device not available, retrying in \(retryInterval, privacy: .public)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval) {
            attemptConnection()
        }
        return
    }

    let agent = GuestClipboardAgent(deviceHandle: deviceHandle)
    currentAgent = agent
    agent.onDisconnect = {
        logger.notice("Device disconnected, scheduling reconnect in \(retryInterval, privacy: .public)s")
        currentAgent = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval) {
            attemptConnection()
        }
    }
    agent.start()
}

vsockConnection.start()
attemptConnection()
dispatchMain()
