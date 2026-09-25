import AppKit
import Foundation
import KernovaAppRegistry

/// Launching the app this tool is embedded in — the one place here that reaches
/// AppKit.
enum AppLaunch {
    /// Whatever `openApplication` reported after the request left, `nil` while
    /// it has not answered or answered success.
    ///
    /// The launch is not awaited: the retry loop's first successful connect is
    /// the readiness signal, and this is what lets that loop give up early
    /// rather than spending its whole deadline on an app that will never come.
    static var reportedFailure: CLIFailure? { failure.value }

    /// Asks Launch Services for the app at `app`, as ``configuration`` says.
    ///
    /// Answers as soon as the request is away, not when the app is up.
    ///
    /// The wait ahead of it is what keeps the open off a registration Launch
    /// Services has not released yet. Only an instance whose process is already
    /// gone is waited out: this path is reached because the socket did not
    /// answer, which an app still coming up explains just as well, and the
    /// connect retry is what waits for that one. An expired wait still opens —
    /// the open is the right next move either way, and its own refusal is what
    /// the caller hears.
    ///
    /// `deadline` is the caller's whole budget, shared with the connect that
    /// follows, so what the two spend together is what the caller was told.
    static func launch(_ app: URL, by deadline: Date) {
        AppRegistryWait.awaitDeregistration(
            ofBundleAt: app, scope: .exitedProcesses, by: deadline)

        let box = failure
        NSWorkspace.shared.openApplication(at: app, configuration: Self.configuration) { _, error in
            guard let error else { return }
            box.store(
                CLIFailure(
                    .unavailable, "Kernova could not be started: \(error.localizedDescription)"))
        }
    }

    /// How ``launch(_:by:)`` asks for the app: a new process of the copy at the
    /// given path, hidden and unactivated.
    static var configuration: NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        // The whole of what a sandboxed launcher can say, and enough: a command
        // typed in a terminal is not a request for a window, and a hidden launch
        // is the one the app answers by staying headless
        // (`AppResidencyController.launchPosture(for:keepInMenuBar:)`). Measured
        // 2026-09-05 (#1143) on macOS 27, the App Sandbox drops `arguments`,
        // `environment` and a custom `appleEvent` before they reach the app;
        // `hides` arrives.
        configuration.hides = true
        configuration.activates = false
        // The API has two modes, and `false` is not "reuse this copy": Apple's
        // documentation says it "causes the system to open the already running
        // app when present", matched by bundle identifier, so with another copy
        // running the open answers with that copy and this one never starts.
        // `true` always starts a process at the path; that a copy runs as one
        // process is the app's own `AppCopyClaim`, which a second process of a
        // running copy fails to take and exits.
        configuration.createsNewApplicationInstance = true
        configuration.addsToRecentItems = false
        return configuration
    }

    /// Holds what the launch reported, written from the completion handler's
    /// own queue and read by the connect loop.
    private static let failure = FailureBox()

    private final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CLIFailure?

        var value: CLIFailure? { lock.withLock { stored } }

        func store(_ failure: CLIFailure) { lock.withLock { stored = failure } }
    }
}

/// How long a connect waits between attempts while the app comes up.
enum ConnectBackoff {
    /// How long the tool waits in total for a launched app to answer.
    ///
    /// It covers process start alone: the app binds its socket before its first
    /// library read lands, and the verb behind the connect waits on that read
    /// itself.
    static let defaultDeadline: TimeInterval = 20

    /// The waits between successive connect attempts, in order.
    ///
    /// A finite schedule rather than a loop against a clock: the caller sleeps
    /// each element and gives up when the list runs out, so what it does is
    /// stated here and asserted in one test rather than depending on how long
    /// the machine took.
    static func delays(
        initial: TimeInterval = 0.05,
        cap: TimeInterval = 0.5,
        deadline: TimeInterval = defaultDeadline
    ) -> [TimeInterval] {
        var schedule: [TimeInterval] = []
        var next = initial
        var elapsed: TimeInterval = 0
        while elapsed + next <= deadline {
            schedule.append(next)
            elapsed += next
            next = min(next * 2, cap)
        }
        return schedule
    }
}
