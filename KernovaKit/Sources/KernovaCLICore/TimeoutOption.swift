import ArgumentParser
import Foundation
import KernovaCommandModel

/// What every `--timeout` on the tool accepts: ``CommandTimeout``'s rule,
/// refused here so a usage error never dials the app.
enum TimeoutOption {
    /// How long `wait` and `ip --wait` wait when given no `--timeout`.
    static let waitDefault: Double = 300

    /// Refuses a deadline that is not a positive, finite number of seconds.
    ///
    /// - Throws: `ValidationError`, which the tool exits 2 on.
    static func validate(_ seconds: Double?) throws {
        guard let seconds, !CommandTimeout.isUsable(seconds) else { return }
        throw ValidationError("--timeout takes a number of seconds greater than zero.")
    }
}
