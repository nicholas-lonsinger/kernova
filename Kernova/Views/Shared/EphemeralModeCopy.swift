import AppKit

/// The user-facing copy for Ephemeral Mode, shared by the Startup setting's
/// info popover, the sidebar badge, and the window title marker — all three
/// answer the same question, so they read from one place.
@MainActor
enum EphemeralModeCopy {
    /// The word the title marker and the sidebar badge carry.
    static let name = "Ephemeral"

    /// SF Symbol for the sidebar badge — the filled circle the row's other
    /// trailing accessories use.
    static let badgeSymbolName = "arrow.counterclockwise.circle.fill"

    /// The VM name as a title bar carries it — suffixed while a session the
    /// baseline will discard is live, plain otherwise.
    static func titleName(_ name: String, ephemeralSessionRunning: Bool) -> String {
        ephemeralSessionRunning ? "\(name) (\(self.name))" : name
    }

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
