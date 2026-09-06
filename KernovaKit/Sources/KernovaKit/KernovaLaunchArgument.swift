import Foundation

/// Arguments a launcher passes the app to say what it launched it for.
///
/// The string exists once, read by whoever passes it and by the app that
/// classifies the launch, so the two cannot fall out of step over a typo.
public enum KernovaLaunchArgument {
    /// Passed by a launcher bringing the app up to service a command.
    ///
    /// A launch carrying it is automation by construction — nobody asked to see
    /// a window, and the process settles back to idle when the last request
    /// finishes. Positive evidence rather than an inference, which is what a
    /// launch from a shell over SSH needs: none of the signals a GUI launch
    /// leaves behind are present there.
    ///
    /// The App Sandbox drops it from `NSWorkspace.OpenConfiguration.arguments`,
    /// so the bundled `kernova` tool cannot pass it (#1143); a launcher outside
    /// the sandbox can.
    public static let automation = "--kernova-automation-launch"
}
