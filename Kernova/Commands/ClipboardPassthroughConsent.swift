import Foundation
import KernovaKit

/// The one gate on automatic clipboard passthrough: when consent is owed, and
/// what the user is being asked for.
///
/// Passthrough runs only while clipboard sharing carries it
/// (``VMConfiguration/clipboardPassthroughIsEffective``), so the passthrough
/// flag alone is not the question — turning sharing on over a flag already set
/// grants the guest the same continuous read of this Mac's clipboard that an
/// explicit passthrough enable does. The configuration verb asks this of every
/// write of either flag, so no surface can grant it silently.
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

    /// What passthrough exposes while it runs: the consent prompt's message and
    /// the passthrough switch's info, worded to read right before and after
    /// the user turns it on.
    static func disclosure(vmName: String) -> String {
        "While it\u{2019}s on, \u{201C}\(vmName)\u{201D} continuously receives whatever you "
            + "copy on this Mac, and its own clipboard is placed here \u{2014} with no per-copy "
            + "confirmation. That includes passwords and other sensitive content."
    }

    /// What the user is asked before passthrough starts running.
    static func prompt(vmName: String) -> ConfirmationPrompt {
        ConfirmationPrompt(
            kind: .enableClipboardPassthrough,
            title: "Turn On Automatic Clipboard Passthrough?",
            message: disclosure(vmName: vmName),
            confirmTitle: "Turn On",
            confirmIsDestructive: false,
            dismissTitle: "Cancel")
    }
}
