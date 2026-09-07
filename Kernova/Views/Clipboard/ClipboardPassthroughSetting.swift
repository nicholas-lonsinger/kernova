import AppKit
import os

/// The one write path for the two clipboard flags, shared by every surface that
/// offers either toggle.
///
/// Both go through here because either one can start passthrough running:
/// ``ClipboardPassthroughConsent`` decides when, so a sharing switch flipped
/// over a passthrough flag already set confirms exactly as the passthrough
/// switch does. A write that is refused, cancelled, or has no window to confirm
/// in writes nothing and calls ``refresh``, so no switch is left showing a value
/// the model does not hold.
///
/// Built per call site rather than stored: the confirmation alert holds
/// ``refresh`` across the sheet, so that closure captures its owner weakly.
@MainActor
struct ClipboardPassthroughSetting {
    private static let logger = Logger(
        subsystem: "app.kernova", category: "ClipboardPassthroughSetting")

    /// Which switch was flipped, and to what.
    enum Change: Equatable {
        /// The automatic-passthrough switch.
        case passthrough(Bool)
        /// The clipboard-sharing switch, which carries passthrough.
        case sharing(Bool)

        fileprivate func apply(to config: inout VMConfiguration) {
            switch self {
            case .passthrough(let isOn): config.clipboardPassthroughEnabled = isOn
            case .sharing(let isOn): config.clipboardSharingEnabled = isOn
            }
        }
    }

    let instance: VMInstance
    let viewModel: VMLibraryViewModel
    /// Re-renders every surface showing the setting from the model.
    let refresh: () -> Void

    /// Applies `change`, confirming in `window` when it turns passthrough on.
    func set(_ change: Change, confirmingIn window: NSWindow?) {
        var candidate = instance.configuration
        change.apply(to: &candidate)
        guard
            ClipboardPassthroughConsent.isNewlyEffective(
                from: instance.configuration, to: candidate)
        else {
            write(change)
            return
        }
        guard let window else {
            Self.logger.warning("No window to confirm clipboard passthrough in; leaving it off")
            refresh()
            return
        }
        presentSheetAlert(
            Self.alert(
                vmName: instance.name,
                onConfirm: { confirm(change) },
                onCancel: { cancel() }),
            in: window)
    }

    /// The confirmation's Turn On.
    func confirm(_ change: Change) {
        write(change)
    }

    /// The confirmation's Cancel: nothing was written, so put every surface back
    /// on the value the model still holds.
    func cancel() {
        refresh()
    }

    /// The enable confirmation, in the words every surface asks it with.
    static func alert(
        vmName: String, onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void
    ) -> AlertConfiguration {
        let prompt = ClipboardPassthroughConsent.prompt(vmName: vmName)
        return AlertConfiguration(
            title: prompt.title,
            message: prompt.message,
            buttons: [
                AlertButton(prompt.confirmTitle, role: .default, action: onConfirm),
                AlertButton(prompt.dismissTitle, role: .cancel, action: onCancel),
            ])
    }

    private func write(_ change: Change) {
        let written = viewModel.updateConfiguration(of: instance) { change.apply(to: &$0) }
        if !written { refresh() }
    }
}
