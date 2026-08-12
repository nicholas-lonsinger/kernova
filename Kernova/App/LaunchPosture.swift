import Foundation

/// How the process was launched, decided from argv so the activation policy is
/// settled synchronously in `main()` — before AppKit checkin.
enum LaunchPosture: Equatable {
    /// Opened by the embedded login-item helper — start headless `.accessory`.
    case loginLaunch
    /// Every other launch — start `.regular`, with the library window on screen.
    case manual

    /// The flag the login-item helper passes in
    /// `NSWorkspace.OpenConfiguration.arguments`.
    static let loginLaunchFlag = "--login-launch"

    /// Reads the posture out of a full argv vector.
    ///
    /// Matched anywhere in the vector rather than at a fixed index: the flag
    /// reaches the process appended to an argv the system builds, so its
    /// position is not part of the contract.
    init(arguments: [String]) {
        self = arguments.contains(Self.loginLaunchFlag) ? .loginLaunch : .manual
    }

    /// Whether this launch must exit in favor of a copy already running.
    ///
    /// A backstop, not the primary defense: Launch Services mediates both routes
    /// into the app — a session-restore open and the login-item helper's open —
    /// and folds concurrent ones into a single instance. What is left for this
    /// guard is the window before a launching process has registered with Launch
    /// Services, during which two can still be in flight.
    ///
    /// One-sided deliberately: of the two, the headless login launch is the
    /// disposable one, so it is the side that yields. The autoclosure keeps the
    /// running-instance lookup off the manual path, which can never use its
    /// answer.
    func yields(toRunningInstance otherInstanceRunning: @autoclosure () -> Bool) -> Bool {
        self == .loginLaunch && otherInstanceRunning()
    }
}
