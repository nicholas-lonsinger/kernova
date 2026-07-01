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

    @Test("A negative sender PID fails toward terminate-and-save without ever being probed")
    func negativeSenderPID() {
        // kill(pid, 0) for pid < 0 targets a process GROUP, not a single process —
        // classifyQuit must reject it before any probe closure is invoked.
        #expect(
            AppDelegate.classifyQuit(
                senderPID: -1,
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
        // Asserts the pid_t argument too (not just the return value), so a future
        // regression that calls bundleIDResolver/isProcessAlive with the wrong pid
        // (e.g. copy-pasted from a different guard) would fail this test even
        // though every other test's closures ignore their argument. The call is
        // pulled out of the `#expect(...)` argument — nesting `#expect` inside
        // another `#expect`'s captured expression recurses in macro expansion.
        let classification = AppDelegate.classifyQuit(
            senderPID: 999,
            bundleIDResolver: { pid in
                #expect(pid == 999)
                return Self.loginwindowBundleID
            },
            isProcessAlive: { pid in
                #expect(pid == 999)
                return true
            }
        )
        #expect(classification == .terminateAndSave)
    }

    @Test("System Settings / TCC revocation terminates and relaunches")
    func tccRevocation() {
        let classification = AppDelegate.classifyQuit(
            senderPID: 999,
            bundleIDResolver: { pid in
                #expect(pid == 999)
                return Self.tccBundleID
            },
            isProcessAlive: { _ in true }
        )
        #expect(classification == .terminateAndRelaunch)
    }
}
