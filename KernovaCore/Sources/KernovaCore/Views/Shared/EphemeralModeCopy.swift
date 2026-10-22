import Foundation

/// The user-facing copy for Ephemeral Mode, shared by the Startup setting, the
/// sidebar badge, and the window title marker — they answer the same question,
/// so they read from one place.
@MainActor
package enum EphemeralModeCopy {
    /// The word the title marker and the sidebar badge carry.
    static let name = "Ephemeral"

    /// SF Symbol for the sidebar badge — the filled circle the row's other
    /// trailing accessories use.
    package static let badgeSymbolName = "arrow.counterclockwise.circle.fill"

    /// The VM name as a title bar carries it — suffixed while a session the
    /// baseline will discard is live, plain otherwise.
    package static func titleName(_ name: String, ephemeralSessionRunning: Bool) -> String {
        ephemeralSessionRunning ? "\(name) (\(self.name))" : name
    }

    /// The note naming what every shutdown discards and where it leaves the
    /// VM, which the baseline's kind decides: a warm baseline restores the
    /// guest's memory along with the disks, so the VM lands suspended on that
    /// session instead of stopped.
    package static func baselineCaption(for kind: VMSnapshotKind) -> String {
        switch kind {
        case .warm: "Each shutdown discards changes and leaves the virtual machine suspended at this snapshot."
        case .cold: "Each shutdown discards changes and leaves the virtual machine stopped at this snapshot."
        }
    }

    package static let popoverParagraphs: [InfoPopoverParagraph] = [
        .body(
            "Returns this virtual machine to its baseline snapshot every time it shuts down. The guest and the machine's settings go back to what the baseline captured, discarding every change made since. Its name and how Kernova handles it, like when it starts and where its display opens, stay as you left them."
        ),
        .body(
            "Suspending keeps the session — including when Kernova quits and suspends running VMs. The session still reverts at its next shutdown."
        ),
        .body(
            "Discarding a suspended ephemeral session returns the virtual machine to its baseline. Turning the mode off clears the baseline choice."
        ),
    ]

    /// The note under the toggle while the VM has no snapshot to stand as a
    /// baseline; `capturesBaseline` when turning the mode on takes one.
    package static func noSnapshotsCaption(capturesBaseline: Bool) -> String {
        capturesBaseline
            ? "Turning it on takes a snapshot to use as the baseline."
            : "Take a snapshot first to use as the baseline."
    }

    /// What pinning `baseline` as `vm`'s baseline does, in the words the
    /// confirmation asks with — both already quoted.
    package static func shutdownDiscards(vm: String, baseline: String) -> String {
        "Every shutdown returns \(vm) to \(baseline), discarding everything changed since "
            + "that snapshot \u{2014} including what\u{2019}s on it now."
    }

    /// The caution beside the toggle while turning the mode on would pin
    /// `baseline`.
    package static func enableCaution(baseline: VMSnapshot) -> String {
        "Once it\u{2019}s on, every shutdown returns the virtual machine to "
            + "\u{201C}\(baseline.name)\u{201D}, discarding everything changed since that "
            + "snapshot \u{2014} including what\u{2019}s on it now."
    }

    /// The Take Snapshot sheet's note when its capture turns the mode on,
    /// naming where a `kind` baseline leaves the VM.
    package static func baselineSheetNote(for kind: VMSnapshotKind) -> String {
        "Ephemeral Mode turns on with this snapshot as its baseline. \(baselineCaption(for: kind))"
    }

    package static let badgeHelpText = "Ephemeral: reverts to its baseline snapshot at every shutdown"
}
