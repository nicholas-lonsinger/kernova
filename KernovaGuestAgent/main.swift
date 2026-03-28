import Foundation
import os

// KernovaGuestAgent
//
// A guest-side agent that runs inside macOS virtual machines managed by Kernova.
// This is currently a stub that validates the build-package-install pipeline.
// The real agent will implement host-guest communication via SPICE.
//
// Usage: kernova-agent [--version]
// When run without flags, blocks indefinitely via dispatchMain() for launchd supervision.

private let logger = Logger(subsystem: "com.kernova.agent", category: "GuestAgent")

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
    return b
}()

if CommandLine.arguments.contains("--version") {
    print("kernova-agent \(version) (\(buildNumber))")
    exit(0)
}

logger.notice("Kernova Guest Agent v\(version, privacy: .public) (\(buildNumber, privacy: .public)) started (stub — waiting for termination)")
dispatchMain()
