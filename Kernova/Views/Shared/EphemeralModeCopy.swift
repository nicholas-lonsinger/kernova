import AppKit

/// The user-facing copy for Ephemeral Mode, shared by the Startup setting, the
/// sidebar badge, and the window title marker — they answer the same question,
/// so they read from one place.
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

    /// The Baseline snapshot menu's entry for `snapshot` — its name beside what
    /// reverting to it puts back, so the kind is legible while the baseline is
    /// being chosen rather than only in Get Info.
    static func baselineMenuTitle(for snapshot: VMSnapshot) -> String {
        "\(snapshot.name) \u{00B7} \(SnapshotKindCopy.captured(snapshot.kind))"
    }

    /// The caption naming the state a shutdown comes to rest in, which the
    /// baseline's kind decides: a warm baseline restores the guest's memory
    /// along with the disks, so the VM lands suspended on that session instead
    /// of stopped.
    static func baselineCaption(for kind: VMSnapshotKind) -> String {
        switch kind {
        case .warm:
            "Shutting down returns this virtual machine to the suspended session the baseline "
                + "captured, and starting it resumes from there."
        case .cold:
            "Shutting down returns this virtual machine to the baseline's disks and leaves it "
                + "stopped."
        }
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
