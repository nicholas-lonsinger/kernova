import Darwin
import Testing

@testable import Kernova

/// Unit tests for `AppDelegate.classifyQuit(senderPID:bundleIDResolver:isProcessAlive:)` —
/// the pure classifier `handleQuitAppleEvent` uses to decide whether a quit Apple
/// Event's sender should leave the resident agent running (GUI-origin quit), or
/// terminate it (with or without a post-exit relaunch).
///
/// Regression coverage for #438: an unattributable sender (no PID, or a PID that no
/// longer resolves) must fail toward `.terminateAndSave` rather than being treated
/// as a GUI-origin quit that vetoes a real system logout/shutdown.
@Suite("AppDelegate.classifyQuit")
struct AppDelegateQuitClassificationTests {
    private static let tccBundleID = "com.apple.settings.PrivacySecurity.extension"
    private static let loginwindowBundleID = "com.apple.loginwindow"

    @Test("No sender PID attribute fails toward terminate-and-save")
    func noSenderPID() {
        #expect(
            AppDelegate.classifyQuit(
                senderPID: nil,
                bundleIDResolver: { _ in
                    Issue.record("should not resolve a bundle ID"); return nil
                },
                isProcessAlive: { _ in
                    Issue.record("should not probe liveness"); return true
                }
            ) == .terminateAndSave)
    }

    @Test("A non-positive sender PID fails toward terminate-and-save")
    func nonPositiveSenderPID() {
        #expect(
            AppDelegate.classifyQuit(
                senderPID: 0,
                bundleIDResolver: { _ in
                    Issue.record("should not resolve a bundle ID"); return nil
                },
                isProcessAlive: { _ in
                    Issue.record("should not probe liveness"); return true
                }
            ) == .terminateAndSave)
    }

    @Test("A sender PID that no longer resolves to a live process fails toward terminate-and-save")
    func deadSender() {
        #expect(
            AppDelegate.classifyQuit(
                senderPID: 999,
                bundleIDResolver: { _ in
                    Issue.record("should not resolve a bundle ID"); return nil
                },
                isProcessAlive: { _ in false }
            ) == .terminateAndSave)
    }

    @Test("A self-sent quit Apple Event stays resident")
    func selfSender() {
        // `classifyQuit` calls the real (non-injectable) `getpid()` internally, so
        // the sender PID must be this process's actual PID to hit that branch.
        #expect(
            AppDelegate.classifyQuit(
                senderPID: getpid(),
                bundleIDResolver: { _ in
                    Issue.record("should not resolve a bundle ID"); return nil
                },
                isProcessAlive: { _ in true }
            ) == .stayResident)
    }

    @Test("A live sender with no resolvable bundle ID (AppleScript's osascript) stays resident")
    func liveSenderNoBundleID() {
        #expect(
            AppDelegate.classifyQuit(
                senderPID: 999,
                bundleIDResolver: { _ in nil },
                isProcessAlive: { _ in true }
            ) == .stayResident)
    }

    @Test("The Dock stays resident")
    func dock() {
        #expect(
            AppDelegate.classifyQuit(
                senderPID: 999,
                bundleIDResolver: { _ in "com.apple.dock" },
                isProcessAlive: { _ in true }
            ) == .stayResident)
    }

    @Test("An arbitrary other live app stays resident")
    func otherApp() {
        #expect(
            AppDelegate.classifyQuit(
                senderPID: 999,
                bundleIDResolver: { _ in "com.example.someApp" },
                isProcessAlive: { _ in true }
            ) == .stayResident)
    }

    @Test("loginwindow (logout / restart / shutdown) terminates and saves")
    func loginwindow() {
        #expect(
            AppDelegate.classifyQuit(
                senderPID: 999,
                bundleIDResolver: { _ in Self.loginwindowBundleID },
                isProcessAlive: { _ in true }
            ) == .terminateAndSave)
    }

    @Test("System Settings / TCC revocation terminates and relaunches")
    func tccRevocation() {
        #expect(
            AppDelegate.classifyQuit(
                senderPID: 999,
                bundleIDResolver: { _ in Self.tccBundleID },
                isProcessAlive: { _ in true }
            ) == .terminateAndRelaunch)
    }
}
