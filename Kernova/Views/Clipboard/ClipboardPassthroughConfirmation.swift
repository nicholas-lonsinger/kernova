import AppKit

/// The explicit security confirmation shown before enabling automatic clipboard
/// passthrough.
///
/// Turning passthrough on grants the (untrusted, CLIPBOARD.md §10) guest
/// continuous read of whatever is copied on the host — so the enable path must be
/// deliberate. Both places that can turn it on (the VM settings toggle and the
/// clipboard window banner) present *this* alert, so the copy and button roles
/// stay identical.
enum ClipboardPassthroughConfirmation {
    static let title = "Turn on automatic clipboard passthrough?"

    static let message =
        "Passthrough continuously shares this Mac's clipboard with the guest whenever it changes, "
        + "and automatically places the guest's clipboard on this Mac — with no per-copy "
        + "confirmation. The guest gains continuous access to whatever you copy, including "
        + "passwords and other sensitive content."

    /// Builds the enable-confirmation alert.
    ///
    /// - Parameters:
    ///   - onConfirm: fires when the user turns passthrough on.
    ///   - onCancel: fires when the user backs out — the caller reverts its toggle.
    /// - Returns: the configured alert (Turn On / Cancel) to hand to `presentSheetAlert`.
    static func alert(
        onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void
    ) -> AlertConfiguration {
        AlertConfiguration(
            title: title,
            message: message,
            buttons: [
                AlertButton("Turn On", role: .default, action: onConfirm),
                AlertButton("Cancel", role: .cancel, action: onCancel),
            ])
    }
}
