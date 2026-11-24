import Foundation

/// What every deadline a verb takes has to be.
///
/// One rule rather than one per door, so a deadline means the same thing
/// wherever it is typed: the core refuses what fails it, and a tool that
/// validates before dialing the app refuses by the same test.
public enum CommandTimeout {
    /// Whether `seconds` is a deadline a verb can wait out: a positive, finite
    /// number of seconds.
    public static func isUsable(_ seconds: TimeInterval) -> Bool {
        seconds.isFinite && seconds > 0
    }

    /// `seconds` written the way a person types a deadline: whole where it is
    /// whole, one decimal otherwise.
    static func text(_ seconds: TimeInterval) -> String {
        seconds == seconds.rounded()
            ? String(format: "%.0f", seconds) : String(format: "%.1f", seconds)
    }
}
