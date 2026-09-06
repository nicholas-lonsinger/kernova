import AppKit
import Foundation
import KernovaKit

/// The app bundle a helper executable is embedded in.
enum EnclosingAppBundle {
    /// The innermost ancestor directory whose name ends in `.app`, or `nil` when
    /// the executable is not inside one.
    ///
    /// Symlinks are resolved first, because the installed tool is one: Settings
    /// → Advanced puts a link in `/usr/local/bin`, and `Bundle.main.executableURL`
    /// answers the path it was invoked through rather than the file behind it.
    ///
    /// Ancestors only: an executable whose own name ends in `.app` is a file,
    /// not the bundle it would be launched as.
    static func locate(executable: URL) -> URL? {
        var candidate = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        while true {
            if candidate.pathExtension == "app" { return candidate }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
    }
}

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

    /// The app bundle this copy of the tool is inside, or `nil` for a copy that
    /// is not inside one.
    static var enclosingBundle: URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        return EnclosingAppBundle.locate(executable: executable)
    }

    /// Asks Launch Services for the enclosing bundle, hidden and unactivated.
    ///
    /// Answers as soon as the request is away, not when the app is up.
    ///
    /// `hides` is the whole of what a sandboxed launcher can say, and it says
    /// enough: a command typed in a terminal is not a request for a window, and
    /// a hidden launch is the one the app answers by staying headless
    /// (docs/SANDBOX.md). Measured 2026-09-05 (#1143) on macOS 27, the App
    /// Sandbox drops `arguments`, `environment` and a custom `appleEvent` from
    /// `NSWorkspace.OpenConfiguration` before they reach the app; `hides`
    /// arrives.
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
    static func launchEnclosingApp(by deadline: Date) -> Result<Void, CLIFailure> {
        guard let bundle = enclosingBundle else {
            return .failure(
                CLIFailure(
                    .unavailable,
                    "This copy of kernova is not inside a Kernova.app, so it cannot start the "
                        + "app. Install the tool from Kernova's Settings \u{2192} Advanced."))
        }

        AppRegistryWait.awaitDeregistration(
            ofBundleAt: bundle, scope: .exitedProcesses, by: deadline)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.hides = true
        configuration.activates = false
        // Without it, a launch request can spawn a second process managing the
        // same VM bundles.
        configuration.createsNewApplicationInstance = false
        configuration.addsToRecentItems = false

        let box = failure
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, error in
            guard let error else { return }
            box.store(
                CLIFailure(
                    .unavailable, "Kernova could not be started: \(error.localizedDescription)"))
        }
        return .success(())
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
