import Foundation

/// Arguments a launcher passes the app to say what it launched it for.
///
/// The string exists once, read by whoever passes it and by the app that
/// classifies the launch, so the two cannot fall out of step over a typo.
public enum KernovaLaunchArgument {
    /// Passed by the `kernova` tool when it launches the app to service a
    /// command.
    ///
    /// A launch carrying it is automation by construction — nobody asked to see
    /// a window, and the process settles back to idle when the last request
    /// finishes. It is positive evidence rather than an inference, which is
    /// what a shell over SSH needs: none of the signals a GUI launch leaves
    /// behind are present there.
    public static let automation = "--kernova-automation-launch"
}
