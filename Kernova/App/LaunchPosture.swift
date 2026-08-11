import Foundation

/// How the process was launched, decided from argv so the activation policy is
/// settled synchronously in `main()` — before AppKit checkin.
enum LaunchPosture: Equatable {
    /// Spawned by the embedded login LaunchAgent — start headless `.accessory`.
    case loginLaunch
    /// Every other launch — start `.regular`, with the library window on screen.
    case manual

    /// The flag the LaunchAgent's `ProgramArguments` carry.
    static let loginLaunchFlag = "--login-launch"

    /// Reads the posture out of a full argv vector.
    ///
    /// Matched anywhere in the vector rather than at a fixed index: launchd
    /// passes `ProgramArguments` through as argv, so element 0 is the executable
    /// path and the flag's position is not part of the contract.
    init(arguments: [String]) {
        self = arguments.contains(Self.loginLaunchFlag) ? .loginLaunch : .manual
    }

    /// Whether this launch must exit in favor of a copy already running.
    ///
    /// One-sided deliberately: a manual launch never yields, because Launch
    /// Services routes a second open to the live instance instead of spawning
    /// one. Only launchd's direct `execv` of the bundle executable bypasses
    /// that, so only a login launch can arrive as a duplicate process.
    func yields(toRunningInstance otherInstanceRunning: Bool) -> Bool {
        self == .loginLaunch && otherInstanceRunning
    }
}
