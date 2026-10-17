import Foundation
import KernovaKit
import KernovaLogging

/// The alerts ``AppAlertPresenter`` shows, built from what each is about, each
/// button acting on `viewModel`.
@MainActor
package struct AppAlertConfigurations {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "AppAlertPresenter")

    let viewModel: VMLibraryViewModel

    package init(viewModel: VMLibraryViewModel) {
        self.viewModel = viewModel
    }

    /// An alternative the core offered that this alert has no route for — a
    /// live button that would do nothing, which is a programming error the same
    /// way a missing handler is.
    static func reportUnhandledAlternative(
        _ alternative: ConfirmationAlternative, on verb: String
    ) {
        #log(
            logger, .fault,
            "No \(verb, privacy: .public) route for alternative '\(alternative.title, privacy: .public)'"
        )
        assertionFailure("No \(verb) route for alternative '\(alternative.title)'")
    }

    /// The cancel confirmation for a create, clone or import, drawn from the
    /// prompt taken when the gesture was made.
    package func cancelPreparingConfig(
        _ prompt: ConfirmationPrompt, _ arrival: VMArrival
    ) -> AlertConfiguration {
        AlertConfiguration(
            confirming: prompt,
            confirm: { [weak viewModel] in viewModel?.cancelArrival(arrival) })
    }

    /// The revert confirmation.
    package func revertSnapshotConfig(
        _ snapshot: VMSnapshot, _ vm: VMInstance
    ) -> AlertConfiguration {
        AlertConfiguration(
            confirming: Self.revertPrompt(snapshot, on: vm),
            confirm: { [weak viewModel] in
                guard let viewModel else { return }
                Task { await viewModel.revert(vm, to: snapshot) }
            },
            alternative: { [weak viewModel] _ in
                guard let viewModel else { return }
                Task { await viewModel.revert(vm, to: snapshot, takingSnapshotFirst: true) }
            })
    }

    /// The core's revert confirmation, with Take Snapshot, Then Revert beside
    /// it wherever Take Snapshot is admitted: the app chains the two verbs.
    static func revertPrompt(_ snapshot: VMSnapshot, on vm: VMInstance) -> ConfirmationPrompt {
        let prompt = VMCommandCore.revertPrompt(snapshot, on: vm)
        guard vm.snapshotCaptureMode != nil else { return prompt }
        return ConfirmationPrompt(
            kind: prompt.kind, title: prompt.title, message: prompt.message,
            confirmTitle: prompt.confirmTitle, confirmIsDestructive: prompt.confirmIsDestructive,
            dismissTitle: prompt.dismissTitle,
            alternatives: [ConfirmationAlternative(title: "Take Snapshot, Then Revert")])
    }

    /// The delete-snapshot confirmation; for the VM's Ephemeral baseline, one
    /// that also turns Ephemeral Mode off, which the delete then does first.
    package func deleteSnapshotConfig(
        _ snapshot: VMSnapshot, _ vm: VMInstance
    ) -> AlertConfiguration {
        let turningOffEphemeralMode = vm.isEphemeralBaseline(snapshot)
        return AlertConfiguration(
            confirming: turningOffEphemeralMode
                ? Self.deleteEphemeralBaselinePrompt(snapshot, on: vm)
                : VMCommandCore.deleteSnapshotPrompt(snapshot, on: vm),
            confirm: { [weak viewModel] in
                viewModel?.deleteSnapshot(
                    vm, snapshot: snapshot, turningOffEphemeralMode: turningOffEphemeralMode)
            })
    }

    /// The confirmation that turns Ephemeral Mode off and deletes `snapshot`,
    /// the baseline it returns `vm` to.
    static func deleteEphemeralBaselinePrompt(
        _ snapshot: VMSnapshot, on vm: VMInstance
    ) -> ConfirmationPrompt {
        let name = "\u{201C}\(snapshot.name)\u{201D}"
        return ConfirmationPrompt(
            kind: .deleteSnapshot,
            title: "Delete \(name)?",
            message:
                "\(name) is the snapshot Ephemeral Mode returns \u{201C}\(vm.name)\u{201D} to. "
                + "Deleting it turns Ephemeral Mode off for this virtual machine, so later "
                + "power-offs keep their changes. Its saved state and disk copies move to the Trash.",
            confirmTitle: "Delete",
            dismissTitle: "Cancel")
    }

    package func forceStopConfig(_ vm: VMInstance) -> AlertConfiguration {
        AlertConfiguration(
            confirming: VMCommandCore.forceStopPrompt(vm),
            confirm: { [weak viewModel] in
                guard let viewModel else { return }
                Task { await viewModel.forceStop(vm) }
            },
            alternative: { [weak viewModel] alternative in
                guard let viewModel else { return }
                guard alternative.disposition == .graceful else {
                    Self.reportUnhandledAlternative(alternative, on: "force stop")
                    return
                }
                Task { await viewModel.stop(vm) }
            })
    }

    package func recoveryBootConfig(_ vm: VMInstance) -> AlertConfiguration {
        AlertConfiguration(
            title: "Start “\(vm.name)” in Recovery Mode?",
            message:
                "The virtual machine will boot into the macOS Recovery environment for this launch only. Restart normally to return to macOS.",
            buttons: [
                AlertButton("Start in Recovery", role: .default) { [weak viewModel] in
                    guard let viewModel else { return }
                    Task { await viewModel.start(vm, bootIntoRecovery: true) }
                },
                AlertButton("Cancel", role: .cancel),
            ])
    }

    /// The Stop a paused VM offers: the guest takes the shutdown request only
    /// awake, so the app resumes it and then stops it, or force stops it.
    package func pausedStopConfig(_ vm: VMInstance) -> AlertConfiguration {
        // Both choices end in a power-off, and an Ephemeral VM's power-off is
        // a revert, so the outcome the mode produces belongs here as much as in
        // the force-stop refusal.
        let ephemeralReturn =
            vm.ephemeralBaselineSnapshot.map {
                " Either way it is ephemeral, so it returns to \u{201C}\($0.name)\u{201D}."
            } ?? ""
        // This alert is the confirmation, so both actions call the view model
        // directly: `requestForceStop` presents its own alert, which would
        // stack on top of this one.
        return AlertConfiguration(
            title: "Stop \u{201C}\(vm.name)\u{201D}?",
            message:
                "\u{201C}\(vm.name)\u{201D} is paused and cannot be shut down directly. Resume it to send a graceful shutdown, or force stop to terminate it immediately (any unsaved data inside the guest will be lost).\(ephemeralReturn)",
            buttons: [
                AlertButton("Resume and Shut Down", role: .default) { [weak viewModel] in
                    guard let viewModel else { return }
                    Task { await viewModel.resumeAndStop(vm) }
                },
                AlertButton("Cancel", role: .cancel),
                AlertButton("Force Stop", role: .destructive) { [weak viewModel] in
                    guard let viewModel else { return }
                    Task { await viewModel.forceStop(vm) }
                },
            ])
    }

    package func startFailedAttachmentConfig(
        _ failure: StartFailedAttachment, _ vm: VMInstance
    ) -> AlertConfiguration {
        // The heading names the bring-up that failed; the button names what the
        // recovery does: a resume where the saved state survives the removal,
        // and otherwise a start — a resume's saved state is discarded along
        // with a storage disk or a shared folder.
        //
        // Laid out as ``AlertConfiguration/init(confirming:confirm:alternative:dismiss:)``
        // lays a destructive confirmation out: the action on the trailing edge
        // taking no Return, the dismiss on Escape. The removal edits the
        // configuration and, taking a storage disk or a shared folder from a VM
        // holding one, destroys a saved state — so no keystroke performs it.
        AlertConfiguration(
            title: "Couldn't \(failure.verb == .resume ? "Resume" : "Start") “\(vm.name)”",
            message: Self.startFailedAttachmentMessage(
                failure, holdsSavedState: vm.hasSaveFile),
            buttons: [
                AlertButton(
                    Self.startFailedRecoveryResumes(failure, holdsSavedState: vm.hasSaveFile)
                        ? "Remove and Resume" : "Remove and Start",
                    role: .destructive
                ) { [weak viewModel] in
                    guard let viewModel else { return }
                    Task { await viewModel.removeStartFailedAttachmentAndStart(failure, on: vm) }
                },
                AlertButton("Cancel", role: .cancel),
            ])
    }

    /// What the start-failed alert says: what was found, what can be done about
    /// it, and what the removal costs.
    ///
    /// One remedy here is certain, and it is ``StartFailedAttachment/Reason/notWritable``'s:
    /// the builder asks for a writable file or folder only for an entry the VM
    /// may write (`requireWritable: !readOnly`), so marking that entry Read
    /// Only skips the check the bring-up died on. It is named only while the VM's
    /// settings can be reached — `holdsSavedState` is exactly what closes them
    /// (``VMAdmission/editClasses(settledAt:facts:)``) — because advice nobody in that state
    /// can follow is worse than none. Everything else the file-system reasons
    /// could be is put to the user as a condition to check, for the reason
    /// ``StartFailedAttachment/Reason`` gives.
    ///
    /// ``StartFailedAttachment/Reason/pathIsDirectory``,
    /// ``StartFailedAttachment/Reason/notADirectory``,
    /// ``StartFailedAttachment/Reason/notReadable`` and
    /// ``StartFailedAttachment/Reason/attachRefused`` are offered no remedy at
    /// all: Read Only does not make a folder a disk image or a file a folder,
    /// a share is read whether or not it is Read Only, and nothing here knows
    /// what the framework objected to.
    ///
    /// Every entry this alert is built for is external
    /// (``StartFailedAttachment``), so re-attaching it later is always true.
    static func startFailedAttachmentMessage(
        _ failure: StartFailedAttachment, holdsSavedState: Bool
    ) -> String {
        let wording = StartFailedWording(failure.kind)
        let item = wording.item
        let remedy: String
        switch failure.reason {
        case .notFound:
            remedy = "If it’s on a disk that isn’t connected, connect it and try again. "
        case .notWritable where !holdsSavedState:
            // The certain one first, named for the control that performs it.
            remedy =
                "Turn on Read Only for it in Settings, under \(wording.settingsSection), "
                + "to start without writing to it. If the \(item) or the disk it’s on is locked or "
                + "read-only, making it writable works too. "
        case .notWritable:
            remedy =
                "If the \(item) or the disk it’s on is locked or read-only, make it writable and "
                + "try again. "
        case .pathIsDirectory, .notADirectory, .notReadable, .attachRefused:
            remedy = ""
        }
        // "also" only where something was offered before it.
        let offer = remedy.isEmpty ? "You can remove" : "You can also remove"
        let next =
            startFailedRecoveryResumes(failure, holdsSavedState: holdsSavedState)
            ? "resume" : "start"
        var message =
            "\(failure.message)\n\n\(remedy)\(offer) “\(failure.label)” from this virtual "
            + "machine and \(next) without it — the \(item) itself is not deleted, and you can "
            + "\(wording.addAgain) later in Settings."
        if holdsSavedState, !startFailedRecoveryResumes(failure, holdsSavedState: holdsSavedState) {
            message +=
                " Removing it also discards this virtual machine's saved state."
        }
        return message
    }

    /// Whether the recovery's removal leaves a saved state for its Start to
    /// restore.
    private static func startFailedRecoveryResumes(
        _ failure: StartFailedAttachment, holdsSavedState: Bool
    ) -> Bool {
        holdsSavedState && StartFailedWording(failure.kind).removalKeepsSavedState
    }

    /// What the start-failed alert says about each kind of entry.
    private struct StartFailedWording {
        /// What the entry is on the host.
        let item: String
        /// How the user puts it back.
        let addAgain: String
        /// The Settings section its Read Only switch lives in.
        let settingsSection: String
        /// Whether a saved state survives its removal, as
        /// ``VMCommandCore/removeStartFailedAttachment(_:attachment:)`` leaves it.
        let removalKeepsSavedState: Bool

        init(_ kind: StartFailedAttachment.Kind) {
            switch kind {
            case .storageDisk:
                (item, addAgain, settingsSection, removalKeepsSavedState) =
                    ("file", "re-attach it", "Storage Disks", false)
            case .removableMedia:
                (item, addAgain, settingsSection, removalKeepsSavedState) =
                    ("file", "re-attach it", "Removable Media", true)
            case .sharedDirectory:
                (item, addAgain, settingsSection, removalKeepsSavedState) =
                    ("folder", "share it again", "Shared Directories", false)
            }
        }
    }

    package func installerMountedConfig(
        _ vmName: String, purpose: GuestAgentInstallerPurpose, delivery: GuestAgentDiskDelivery
    ) -> AlertConfiguration {
        let nextStep: String
        switch purpose {
        case .install:
            nextStep = "run install.command to complete setup."
        case .manage:
            nextStep =
                "run install.command to reinstall, or uninstall.command to remove the agent."
        }

        let title: String
        let lead: String
        switch delivery {
        case .usb:
            title = purpose == .install ? "Installer Mounted" : "Guest Agent Disk Attached"
            lead = "The Kernova guest agent disk has been attached to \(vmName) as a USB disk."
        case .virtio:
            // Nothing was attached just now — the disk is there for the whole
            // session, so the alert describes where it already is.
            title = "Guest Agent Disk Attached"
            lead = "The Kernova guest agent disk stays attached to \(vmName) whenever it runs."
        }

        return .acknowledgement(
            title: title,
            message:
                "\(lead) Inside the VM, open the “\(BundledGuestAgent.diskLabel)” disk in Finder and \(nextStep)"
        )
    }
}
