import Foundation
import KernovaKit

/// The one gate on automatic clipboard passthrough: when consent is owed, and
/// what the user is being asked for.
///
/// Passthrough runs only while clipboard sharing carries it
/// (``VMConfiguration/clipboardPassthroughIsEffective``), so the passthrough
/// flag alone is not the question — turning sharing on over a flag already set
/// grants the guest the same continuous read of this Mac's clipboard
/// (docs/CLIPBOARD.md §10) that an explicit passthrough enable does. Every
/// surface that writes either flag asks this, so none of them can grant it
/// silently.
///
/// Headless: it holds the prompt's words but presents nothing — the pane raises
/// an alert with them, and a wire client receives them as a
/// ``CommandError/confirmationRequired(_:)``.
enum ClipboardPassthroughConsent {
    /// Whether moving from `current` to `candidate` turns effective passthrough
    /// on — the whole of what consent is owed for.
    static func isNewlyEffective(
        from current: VMConfiguration, to candidate: VMConfiguration
    ) -> Bool {
        candidate.clipboardPassthroughIsEffective && !current.clipboardPassthroughIsEffective
    }

    /// What the user is asked before passthrough starts running.
    static func prompt(vmName: String) -> ConfirmationPrompt {
        ConfirmationPrompt(
            kind: .enableClipboardPassthrough,
            title: "Turn On Automatic Clipboard Passthrough?",
            message:
                "\u{201C}\(vmName)\u{201D} will continuously receive whatever you copy on this "
                + "Mac, and its own clipboard will be placed here — with no per-copy "
                + "confirmation. That includes passwords and other sensitive content.",
            confirmTitle: "Turn On",
            confirmIsDestructive: false,
            dismissTitle: "Cancel")
    }
}
