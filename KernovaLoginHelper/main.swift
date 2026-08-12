import AppKit
import os

// The login item registered by "Launch into Background at Login". Launch
// Services starts it at login; it opens the enclosing Kernova.app with the
// login-launch flag and exits. The app, never this process, is the long-lived
// VM host.

private let logger = Logger(subsystem: "app.kernova", category: "LoginHelper")

// Must stay equal to the app's `LaunchPosture.loginLaunchFlag`. The two targets
// cannot share a source file: a synchronized root group spans exactly one
// folder, and `membershipExceptions` only subtracts. `LaunchPostureTests` pins
// the app's side of the literal.
private let loginLaunchFlag = "--login-launch"

// Contents/Library/LoginItems/KernovaLoginHelper.app → the enclosing Kernova.app.
//
// Derived from this bundle's own path rather than looked up by identifier: the
// derivation opens the copy that actually contains this helper, while a
// Launch Services bundle-identifier lookup can elect a different copy of the
// app entirely (`Tools/ghosts.sh` exists to diagnose exactly that).
private let hostAppURL =
    Bundle.main.bundleURL
    .deletingLastPathComponent()  // …/Contents/Library/LoginItems
    .deletingLastPathComponent()  // …/Contents/Library
    .deletingLastPathComponent()  // …/Contents
    .deletingLastPathComponent()  // …/Kernova.app

@MainActor
func openHostApp() async {
    let configuration = NSWorkspace.OpenConfiguration()
    // The app reads the flag and picks `.accessory` before AppKit checkin, so
    // activating would pull a window-less app forward at login.
    configuration.activates = false
    configuration.addsToRecentItems = false
    configuration.arguments = [loginLaunchFlag]

    do {
        try await NSWorkspace.shared.openApplication(at: hostAppURL, configuration: configuration)
        logger.notice("Opened the host app for login launch")
        exit(0)
    } catch {
        logger.error(
            "Could not open the host app: \(error.localizedDescription, privacy: .public)")
        exit(1)
    }
}

Task { @MainActor in await openHostApp() }

// Launch Services is busy at login; exit rather than linger as a stray process
// if the open never comes back.
DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
    logger.error("Timed out opening the host app")
    exit(1)
}

RunLoop.main.run()
