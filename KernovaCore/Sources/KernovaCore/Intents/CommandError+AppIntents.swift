import AppIntents
import Foundation
import KernovaCommandModel

/// Carries the core's refusals into Shortcuts and Spotlight, naming commands
/// by Shortcuts' own actions.
///
/// Without this the framework reports a generic failure, and the sentences that
/// make a refusal actionable — the actions a VM's state does admit, the
/// operation it is busy with — never reach the user.
extension CommandError: CustomLocalizedStringResourceConvertible {
    package var localizedStringResource: LocalizedStringResource { "\(message(in: .shortcuts))" }
}
