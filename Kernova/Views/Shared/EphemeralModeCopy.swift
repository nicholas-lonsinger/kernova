import AppKit

/// The user-facing copy for Ephemeral Mode, shared by the Startup setting's
/// info popover, the sidebar badge, and the running chip — all three answer the
/// same question, so they read from one place.
@MainActor
enum EphemeralModeCopy {
    /// The word the running marker and the sidebar badge carry.
    static let name = "Ephemeral"

    /// SF Symbol for the sidebar badge — the filled circle the row's other
    /// trailing accessories use.
    static let badgeSymbolName = "arrow.counterclockwise.circle.fill"

    /// SF Symbol for the running chip, which supplies its own capsule.
    static let chipSymbolName = "arrow.counterclockwise"

    static let popoverParagraphs: [InfoPopoverParagraph] = [
        .body(
            "Returns this virtual machine to its baseline snapshot every time it shuts down. Everything changed inside the guest during the session is discarded."
        ),
        .body(
            "Suspending keeps the session — including when Kernova quits and suspends running VMs. The session still reverts at its next shutdown."
        ),
        .body(
            "Discarding a suspended ephemeral session returns the VM to its baseline. The baseline snapshot cannot be deleted while Ephemeral Mode is on; turning the mode off clears the baseline choice."
        ),
    ]

    /// The Startup card's caption for the toggle.
    static let settingsCaption =
        "An ephemeral virtual machine returns to its baseline snapshot every time it shuts down, "
        + "discarding everything changed inside the guest. Suspending keeps the session."

    /// The caption shown instead while the VM has no snapshot to stand as a
    /// baseline.
    static let noSnapshotsCaption =
        "Take a snapshot of this virtual machine first — it becomes the baseline every shutdown "
        + "returns to."

    static let badgeHelpText = "Ephemeral: reverts to its baseline snapshot at every shutdown"
}
