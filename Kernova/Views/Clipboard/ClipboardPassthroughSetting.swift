import AppKit
import os

/// The one write path for automatic clipboard passthrough, shared by every
/// surface that offers the toggle.
///
/// Turning it on grants the (untrusted, CLIPBOARD.md §10) guest continuous read
/// of the host clipboard, so the enable path confirms first; turning it off is
/// immediate. An enable that is refused, cancelled, or has no window to confirm
/// in writes nothing and calls ``refresh``, so no switch is left showing a value
/// the model does not hold.
///
/// Built per call site rather than stored: the confirmation alert holds
/// ``refresh`` across the sheet, so that closure captures its owner weakly.
@MainActor
struct ClipboardPassthroughSetting {
    private static let logger = Logger(
        subsystem: "app.kernova", category: "ClipboardPassthroughSetting")

    let instance: VMInstance
    let viewModel: VMLibraryViewModel
    /// Re-renders every surface showing the setting from the model.
    let refresh: () -> Void

    /// Applies the intended value, confirming an enable in `window`.
    func set(_ isOn: Bool, confirmingIn window: NSWindow?) {
        guard isOn else {
            write(false)
            return
        }
        guard let window else {
            Self.logger.warning("No window to confirm clipboard passthrough in; leaving it off")
            refresh()
            return
        }
        presentSheetAlert(
            ClipboardPassthroughConfirmation.alert(
                onConfirm: { confirmEnable() },
                onCancel: { cancelEnable() }),
            in: window)
    }

    /// The confirmation's Turn On.
    func confirmEnable() {
        write(true)
    }

    /// The confirmation's Cancel: nothing was written, so put every surface back
    /// on the value the model still holds.
    func cancelEnable() {
        refresh()
    }

    private func write(_ isOn: Bool) {
        let written = viewModel.updateConfiguration(of: instance) {
            $0.clipboardPassthroughEnabled = isOn
        }
        if !written { refresh() }
    }
}
