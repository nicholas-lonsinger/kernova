import AppKit
import KernovaCore
import KernovaKit
import KernovaLogging

/// The one write path for a setting whose write the configuration verb may
/// refuse without the user's consent — the clipboard flags, either of which
/// can start passthrough running, and Ephemeral Mode's switch and baseline,
/// after which every shutdown discards what the VM holds — shared by every
/// surface offering one of them.
///
/// A refusal for consent raises its prompt as a sheet and, once confirmed,
/// makes the same write with that consent given. A write that is refused,
/// cancelled, or has no window to confirm in writes nothing and calls
/// ``refresh``, so no control is left showing a value the model does not hold.
///
/// Built per call site rather than stored: the confirmation alert holds
/// ``refresh`` across the sheet, so that closure captures its owner weakly.
@MainActor
struct ConsentedSettingWrite {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "ConsentedSettingWrite")

    let instance: VMInstance
    let viewModel: VMLibraryViewModel
    /// Re-renders every surface showing the setting from the model.
    let refresh: () -> Void

    /// Applies `assignment` under `consent`, confirming in `window` when the
    /// verb asks for a consent `consent` does not carry.
    func write(
        _ assignment: ConfigurationEntry, confirmingIn window: NSWindow?, consent: Consent = .none
    ) {
        switch viewModel.setConfiguration([assignment], on: instance, consent: consent) {
        case .applied:
            return
        case .refused:
            refresh()
        case .consentRequired(let prompt):
            guard let window, !consent.covers(prompt.kind) else {
                Self.logger.log(
                    .warning,
                    "No confirmation for \(assignment.key, privacy: .public) on '\(instance.name, privacy: .public)'; leaving it unchanged"
                )
                refresh()
                return
            }
            presentSheetAlert(
                Self.alert(
                    prompt: prompt,
                    onConfirm: {
                        write(assignment, confirmingIn: window, consent: consent.adding(prompt.kind))
                    },
                    onCancel: { refresh() }),
                in: window)
        }
    }

    /// The consent alert for `prompt`.
    static func alert(
        prompt: ConfirmationPrompt, onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) -> AlertConfiguration {
        AlertConfiguration(confirming: prompt, confirm: onConfirm, dismiss: onCancel)
    }
}
