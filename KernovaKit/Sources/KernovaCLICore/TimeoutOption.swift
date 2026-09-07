import ArgumentParser
import Foundation

/// What every `--timeout` on the tool accepts.
///
/// One rule rather than one per verb, so a deadline means the same thing
/// wherever it is typed.
enum TimeoutOption {
    /// Refuses a deadline that is not a positive, finite number of seconds.
    ///
    /// - Throws: `ValidationError`, which the tool exits 2 on.
    static func validate(_ seconds: Double?) throws {
        guard let seconds else { return }
        guard seconds.isFinite, seconds > 0 else {
            throw ValidationError("--timeout takes a number of seconds greater than zero.")
        }
    }
}
