import AppIntents
import Foundation

/// Carries the shared refusal vocabulary into Shortcuts and Siri.
///
/// Without this the framework reports a generic failure, and the sentences that
/// make a refusal actionable — the verbs a VM's state does admit, the operation
/// it is busy with — never reach the user.
extension CommandError: CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}
