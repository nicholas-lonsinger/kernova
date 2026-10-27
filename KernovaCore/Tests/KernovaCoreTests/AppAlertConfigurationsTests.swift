import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// Covers `AppAlertConfigurations` — what each alert the presenter shows says,
/// and the buttons it offers.
@Suite("AppAlertConfigurations", .serialized, .caseScoped)
@MainActor
struct AppAlertConfigurationsTests {
    private let preferences = makeTestPreferences()

    private func makeConfigurations() -> (AppAlertConfigurations, VMLibraryViewModel) {
        let viewModel = makeLibraryViewModel(preferences: preferences)
        return (AppAlertConfigurations(viewModel: viewModel), viewModel)
    }

    private func makeInstance(
        name: String = "Test VM", in viewModel: VMLibraryViewModel,
        hostState: VMHostState = VMHostState()
    ) -> VMInstance {
        viewModel.library.admitFixture(name: name, hostState: hostState)
    }

    @Test("The revert alert on a suspended VM names the suspended session it replaces")
    func revertAlertNamesTheSuspendedSession() throws {
        let (configurations, viewModel) = makeConfigurations()
        let vm = makeInstance(in: viewModel)
        vm.activity.placeForTesting(.suspended)
        // A capturable suspend slot: every predicate a suspended VM is judged
        // by needs one on disk, not just the status.
        try VMInstanceFixture.writeSaveFile(for: vm)
        #expect(vm.isSuspended)
        let snapshot = VMSnapshot(name: "Before the update", macAddress: nil)

        let alert = configurations.revertSnapshotConfig(snapshot, vm)

        // A suspended VM can now check-point before reverting, so the
        // snapshot-first button is offered — but the copy still names the
        // suspended session that revert alone would replace.
        #expect(alert.buttons.contains { $0.title == "Take Snapshot, Then Revert" })
        #expect(alert.message.contains("suspended session"))
    }

    @Test("A running VM's force-stop alert keeps the destructive button off Return")
    func forceStopAlertOrdersItsButtons() {
        let (configurations, viewModel) = makeConfigurations()
        let vm = makeInstance(in: viewModel)
        vm.activity.placeForTesting(.running(sessionID: UUID()))

        let alert = configurations.forceStopConfig(vm)

        // Added trailing-edge first, so this reads right-to-left on screen:
        // Force Stop on the leading edge, Shut Down on Return.
        #expect(alert.buttons.map(\.title) == ["Shut Down", "Cancel", "Force Stop"])
        #expect(alert.buttons.map(\.role) == [.default, .cancel, .destructive])
    }

    // MARK: - The start-failed removal offer

    private func makeStartFailure(
        _ reason: StartFailedAttachment.Reason, message: String, verb: VMVerb = .start,
        kind: StartFailedAttachment.Kind = .storageDisk
    ) -> StartFailedAttachment {
        StartFailedAttachment(
            verb: verb, kind: kind, reason: reason, id: UUID(), label: "Archive",
            message: message)
    }

    /// The removal edits the configuration and, for a VM holding one, destroys a
    /// saved state — so no keystroke performs it. Same layout the core's own
    /// destructive confirmations get.
    @Test("The removal offer puts its destructive action off Return, with Cancel on Escape")
    func startFailedAlertKeepsTheRemovalOffReturn() {
        let (configurations, viewModel) = makeConfigurations()
        let vm = makeInstance(in: viewModel)
        let failure = makeStartFailure(.notFound, message: "Storage disk 'Archive' not found.")

        let alert = configurations.startFailedAttachmentConfig(failure, vm)

        #expect(alert.buttons.map(\.title) == ["Remove and Start", "Cancel"])
        #expect(alert.buttons.map(\.role) == [.destructive, .cancel])
        #expect(!alert.buttons.contains { $0.role == .default })
    }

    /// A saved state survives a removal of removable media, so the Start the
    /// recovery runs restores it — and the button says so.
    @Test("The removal offer names Resume where the saved state survives the removal")
    func startFailedAlertNamesResumeWhereTheStateSurvives() throws {
        let (configurations, viewModel) = makeConfigurations()
        let vm = makeInstance(in: viewModel)
        try VMInstanceFixture.writeSaveFile(for: vm)

        let media = configurations.startFailedAttachmentConfig(
            makeStartFailure(.notFound, message: "gone", verb: .resume, kind: .removableMedia),
            vm)
        let disk = configurations.startFailedAttachmentConfig(
            makeStartFailure(.notFound, message: "gone", verb: .resume), vm)

        #expect(media.buttons.map(\.title) == ["Remove and Resume", "Cancel"])
        #expect(disk.buttons.map(\.title) == ["Remove and Start", "Cancel"])
    }

    @Test("The offer heads itself with the bring-up the user asked for")
    func startFailedAlertNamesTheBringUp() {
        let (configurations, viewModel) = makeConfigurations()
        let vm = makeInstance(name: "Builder", in: viewModel)

        let started = configurations.startFailedAttachmentConfig(
            makeStartFailure(.notFound, message: "gone"), vm)
        let resumed = configurations.startFailedAttachmentConfig(
            makeStartFailure(.notFound, message: "gone", verb: .resume), vm)

        #expect(started.title == "Couldn't Start “Builder”")
        #expect(resumed.title == "Couldn't Resume “Builder”")
    }

    /// Nothing here can tell a deleted file from one on a volume that is not
    /// mounted, so the copy names reconnecting as a condition to check, never as
    /// the cause.
    @Test("A file that isn't there names reconnecting, and claims no cause")
    func startFailedAlertOnAMissingFileNamesTheRetry() {
        let message = AppAlertConfigurations.startFailedAttachmentMessage(
            makeStartFailure(
                .notFound, message: "Storage disk 'Archive' not found at /Volumes/Ext/a.img."),
            holdsSavedState: false)

        #expect(message.hasPrefix("Storage disk 'Archive' not found at /Volumes/Ext/a.img."))
        #expect(message.contains("If it’s on a disk that isn’t connected, connect it and try again."))
        #expect(!message.contains("was deleted"))
        #expect(!message.contains("may have been"))
        #expect(message.contains("You can also remove “Archive”"))
        #expect(message.contains("re-attach it later in Settings"))
    }

    /// Marking the entry Read Only is the one remedy this app can be sure of —
    /// the builder asks for a writable file only for an entry the VM may write —
    /// and each kind's switch lives in its own Settings section.
    @Test(
        "An unwritable file names the Read Only switch, in the section that carries it",
        arguments: [
            (StartFailedAttachment.Kind.storageDisk, "Storage Disks"),
            (.removableMedia, "Removable Media"),
        ])
    func startFailedAlertOnAnUnwritableFileNamesReadOnly(
        kind: StartFailedAttachment.Kind, section: String
    ) {
        let message = AppAlertConfigurations.startFailedAttachmentMessage(
            makeStartFailure(
                .notWritable, message: "Archive is not writable: /tmp/a.img.", kind: kind),
            holdsSavedState: false)

        #expect(
            message.contains("Turn on Read Only for it in Settings, under \(section),"), "\(kind)")
        // The file-system side is a condition, not a diagnosis: `isWritableFile`
        // is equally false for a read-only volume and a sandbox denial.
        #expect(
            message.contains("If the file or the disk it’s on is locked or read-only"), "\(kind)")
        #expect(message.contains("You can also remove “Archive”"), "\(kind)")
    }

    /// Settings are locked while a saved state is on disk, so the one remedy
    /// that needs them is not offered to a VM that cannot reach them.
    @Test("An unwritable file on a suspended VM is not sent to Settings")
    func startFailedAlertOnAnUnwritableFileWithASavedStateOmitsReadOnly() {
        let message = AppAlertConfigurations.startFailedAttachmentMessage(
            makeStartFailure(
                .notWritable, message: "Storage disk 'Archive' is not writable: /tmp/a.img."),
            holdsSavedState: true)

        #expect(!message.contains("Turn on Read Only"))
        #expect(
            message.contains(
                "If the file or the disk it’s on is locked or read-only, make it writable and "
                    + "try again."))
        #expect(
            message.hasSuffix(
                "Removing it also discards this virtual machine's saved state."))
    }

    /// A saved state restores with removable media removed, so its removal
    /// costs nothing more than the item.
    @Test("Removing removable media from a suspended VM does not claim to discard its saved state")
    func startFailedAlertOnRemovableMediaWithASavedStateKeepsIt() {
        let message = AppAlertConfigurations.startFailedAttachmentMessage(
            makeStartFailure(
                .notFound, message: "Removable media 'Archive' was not found.", verb: .resume,
                kind: .removableMedia),
            holdsSavedState: true)

        #expect(!message.contains("saved state"))
        #expect(message.contains("and resume without it"))
        #expect(message.hasSuffix("you can re-attach it later in Settings."))
    }

    /// Read Only does not make a folder a disk image, and nothing here knows
    /// what the framework objected to — so neither case invents a step.
    @Test(
        "A folder and a refused attach name no remedy",
        arguments: [StartFailedAttachment.Reason.pathIsDirectory, .attachRefused])
    func startFailedAlertNamesNoRemedyWhereNoneIsCertain(reason: StartFailedAttachment.Reason) {
        let message = AppAlertConfigurations.startFailedAttachmentMessage(
            makeStartFailure(reason, message: "Storage disk 'Archive' is a directory."),
            holdsSavedState: false)

        #expect(message.contains("You can remove “Archive”"), "\(reason)")
        #expect(!message.contains("try again."), "\(reason)")
        #expect(!message.contains("Read Only"), "\(reason)")
    }

    /// A shared folder's removal discards a saved state, as a storage disk's
    /// does, so the recovery always ends in a Start.
    @Test("The removal offer for a shared folder starts, saved state or not")
    func startFailedAlertOnASharedFolderStarts() throws {
        let (configurations, viewModel) = makeConfigurations()
        let vm = makeInstance(in: viewModel)
        let failure = makeStartFailure(
            .notFound, message: "gone", verb: .resume, kind: .sharedDirectory)

        let stopped = configurations.startFailedAttachmentConfig(failure, vm)
        try VMInstanceFixture.writeSaveFile(for: vm)
        let suspended = configurations.startFailedAttachmentConfig(failure, vm)

        #expect(stopped.buttons.map(\.title) == ["Remove and Start", "Cancel"])
        #expect(suspended.buttons.map(\.title) == ["Remove and Start", "Cancel"])
    }

    @Test("A shared folder that isn't there names reconnecting, and calls itself a folder")
    func startFailedAlertOnAMissingSharedFolder() {
        let message = AppAlertConfigurations.startFailedAttachmentMessage(
            makeStartFailure(
                .notFound, message: "Shared folder 'Archive' not found at /Volumes/Ext/Archive.",
                kind: .sharedDirectory),
            holdsSavedState: false)

        #expect(
            message
                == "Shared folder 'Archive' not found at /Volumes/Ext/Archive.\n\n"
                + "If it’s on a disk that isn’t connected, connect it and try again. You can also "
                + "remove “Archive” from this virtual machine and start without it — the folder "
                + "itself is not deleted, and you can share it again later in Settings.")
    }

    @Test("An unwritable shared folder names the Read Only switch under Shared Directories")
    func startFailedAlertOnAnUnwritableSharedFolderNamesReadOnly() {
        let message = AppAlertConfigurations.startFailedAttachmentMessage(
            makeStartFailure(
                .notWritable, message: "Shared folder 'Archive' is not writable: /tmp/Archive.",
                kind: .sharedDirectory),
            holdsSavedState: false)

        #expect(
            message.contains(
                "Turn on Read Only for it in Settings, under Shared Directories, to start without "
                    + "writing to it. If the folder or the disk it’s on is locked or read-only, "
                    + "making it writable works too."))
        #expect(message.contains("the folder itself is not deleted"))
        #expect(!message.contains("file"))
        #expect(!message.contains("saved state"))
    }

    @Test("An unwritable shared folder on a suspended VM is not sent to Settings, and says the state goes")
    func startFailedAlertOnAnUnwritableSharedFolderWithASavedState() {
        let message = AppAlertConfigurations.startFailedAttachmentMessage(
            makeStartFailure(
                .notWritable, message: "Shared folder 'Archive' is not writable: /tmp/Archive.",
                verb: .resume, kind: .sharedDirectory),
            holdsSavedState: true)

        #expect(!message.contains("Turn on Read Only"))
        #expect(
            message.contains(
                "If the folder or the disk it’s on is locked or read-only, make it writable and "
                    + "try again."))
        #expect(message.contains("and start without it"))
        #expect(
            message.hasSuffix(
                "Removing it also discards this virtual machine's saved state."))
    }

    /// Read Only does not make a file a folder, and a share is read whether it
    /// is Read Only or not — so neither case invents a step.
    @Test(
        "A shared path that is no folder, or that cannot be read, names no remedy",
        arguments: [StartFailedAttachment.Reason.notADirectory, .notReadable])
    func startFailedAlertOnAnUnusableSharedFolderNamesNoRemedy(
        reason: StartFailedAttachment.Reason
    ) {
        let message = AppAlertConfigurations.startFailedAttachmentMessage(
            makeStartFailure(
                reason, message: "Shared folder 'Archive' is not readable: /tmp/Archive.",
                kind: .sharedDirectory),
            holdsSavedState: false)

        #expect(message.contains("You can remove “Archive”"), "\(reason)")
        #expect(!message.contains("try again."), "\(reason)")
        #expect(!message.contains("Read Only"), "\(reason)")
        #expect(message.contains("the folder itself is not deleted"), "\(reason)")
    }

    @Test("The baseline's delete is confirmed naming the mode turning off; any other as before")
    func deleteSnapshotAlertNamesTheModeForTheBaseline() {
        let (configurations, viewModel) = makeConfigurations()
        let baseline = VMSnapshot(name: "Clean install", macAddress: nil)
        let later = VMSnapshot(name: "Configured", macAddress: nil)
        var hostState = VMHostState()
        hostState.applyEphemeralMode(enabled: true, baseline: baseline.id)
        let vm = makeInstance(in: viewModel, hostState: hostState)
        vm.seedSnapshotManifest(VMSnapshotManifest(snapshots: [baseline, later]))

        let alert = configurations.deleteSnapshotConfig(baseline, vm)
        #expect(alert.title == "Delete \u{201C}Clean install\u{201D}?")
        #expect(
            alert.message
                == "\u{201C}Clean install\u{201D} is the snapshot Ephemeral Mode returns "
                + "\u{201C}\(vm.name)\u{201D} to. Deleting it turns Ephemeral Mode off for this "
                + "virtual machine, so later power-offs keep their changes. Its saved state and "
                + "disk copies move to the Trash.")
        #expect(alert.buttons.map(\.title) == ["Delete", "Cancel"])

        let plain = configurations.deleteSnapshotConfig(later, vm)
        #expect(plain.message == VMCommandCore.deleteSnapshotPrompt(later, on: vm).message)
    }

    @Test("Discarding a suspended ephemeral session is presented as a revert to the baseline")
    func discardAlertOnAnEphemeralVMNamesTheBaseline() throws {
        let (configurations, viewModel) = makeConfigurations()
        let baseline = VMSnapshot(name: "Clean install", macAddress: nil)
        var hostState = VMHostState()
        hostState.applyEphemeralMode(enabled: true, baseline: baseline.id)
        let vm = makeInstance(in: viewModel, hostState: hostState)
        vm.activity.placeForTesting(.suspended)
        try VMInstanceFixture.writeSaveFile(for: vm)
        vm.seedSnapshotManifest(VMSnapshotManifest(snapshots: [baseline], currentID: baseline.id))

        let alert = configurations.forceStopConfig(vm)

        #expect(alert.buttons.contains { $0.title == "Revert to Baseline" })
        #expect(alert.message.contains("Clean install"))
        #expect(!alert.message.contains("permanently delete"))
    }

    @Test("Discarding a suspended VM that isn't ephemeral still names the deletion")
    func discardAlertOnAPlainVMIsUnchanged() throws {
        let (configurations, viewModel) = makeConfigurations()
        let vm = makeInstance(in: viewModel)
        vm.activity.placeForTesting(.suspended)
        try VMInstanceFixture.writeSaveFile(for: vm)

        let alert = configurations.forceStopConfig(vm)

        #expect(alert.buttons.contains { $0.title == "Discard" })
        #expect(alert.message.contains("permanently delete the saved state"))
    }

    @Test("The revert alert on a live VM offers the snapshot-first path instead")
    func revertAlertOnALiveVMOffersSnapshotFirst() {
        let (configurations, viewModel) = makeConfigurations()
        let vm = makeInstance(in: viewModel)
        vm.activity.placeForTesting(.running(sessionID: UUID()))
        let snapshot = VMSnapshot(name: "Before the update", macAddress: nil)

        let alert = configurations.revertSnapshotConfig(snapshot, vm)

        #expect(alert.buttons.contains { $0.title == "Take Snapshot, Then Revert" })
        #expect(!alert.message.contains("suspended session"))
    }

    @Test("A stopped VM is offered the check-point path, now that it can be captured")
    func revertAlertOnAStoppedVMOffersSnapshotFirst() {
        let (configurations, viewModel) = makeConfigurations()
        let vm = makeInstance(in: viewModel)
        vm.activity.placeForTesting(.stopped)
        let snapshot = VMSnapshot(name: "Before the update", kind: .cold, macAddress: nil)

        let alert = configurations.revertSnapshotConfig(snapshot, vm)

        #expect(alert.buttons.contains { $0.title == "Take Snapshot, Then Revert" })
    }

    @Test("A VM whose guest can write an external disk is offered no snapshot-first path")
    func revertAlertOffersNoSnapshotFirstWhereNoneCanBeTaken() {
        let (configurations, viewModel) = makeConfigurations()
        let vm = viewModel.library.admitFixture {
            $0.removableMedia = [RemovableMediaItem(path: "/Volumes/Data/Scratch.img", readOnly: false)]
        }
        vm.activity.placeForTesting(.running(sessionID: UUID()))
        let snapshot = VMSnapshot(name: "Before the update", macAddress: nil)

        let alert = configurations.revertSnapshotConfig(snapshot, vm)

        #expect(alert.buttons.map(\.title) == ["Revert", "Cancel"])
    }

    @Test("A paused VM's Stop offers Resume and Shut Down on Return and Force Stop off it")
    func pausedStopAlertLaysOutBothSteps() {
        let (configurations, viewModel) = makeConfigurations()
        let vm = makeInstance(in: viewModel)
        vm.activity.placeForTesting(.livePaused(sessionID: UUID()))

        let alert = configurations.pausedStopConfig(vm)

        #expect(alert.title == "Stop \u{201C}\(vm.name)\u{201D}?")
        #expect(alert.buttons.map(\.title) == ["Resume and Shut Down", "Cancel", "Force Stop"])
        #expect(alert.buttons.map(\.role) == [.default, .cancel, .destructive])
        #expect(!alert.message.contains("ephemeral"))
    }

    @Test("A paused Ephemeral VM's Stop names the baseline both its actions end at")
    func pausedStopAlertOnAnEphemeralVMNamesTheBaseline() {
        let (configurations, viewModel) = makeConfigurations()
        let baseline = VMSnapshot(name: "Clean install", macAddress: nil)
        var hostState = VMHostState()
        hostState.applyEphemeralMode(enabled: true, baseline: baseline.id)
        let vm = makeInstance(in: viewModel, hostState: hostState)
        vm.seedSnapshotManifest(VMSnapshotManifest(snapshots: [baseline]))
        vm.activity.placeForTesting(.livePaused(sessionID: UUID()))

        let alert = configurations.pausedStopConfig(vm)

        // Resume-and-shut-down and force-stop both power the VM off, and a
        // power-off is the revert.
        #expect(alert.message.hasSuffix("Either way it is ephemeral, so it returns to \u{201C}Clean install\u{201D}."))
    }

    @Test("Reverting a live VM to a snapshot taken while stopped says the session ends, powered off")
    func revertAlertOnAColdTargetNamesThePowerOff() {
        let (configurations, viewModel) = makeConfigurations()
        let vm = makeInstance(in: viewModel)
        vm.activity.placeForTesting(.running(sessionID: UUID()))
        let snapshot = VMSnapshot(name: "Before first boot", kind: .cold, macAddress: nil)

        let alert = configurations.revertSnapshotConfig(snapshot, vm)

        #expect(alert.message.contains("powered off"))
        #expect(alert.message.contains("session it is running now ends"))
    }

    @Test("Reverting a suspended VM to a snapshot taken while stopped says its saved session is discarded")
    func revertAlertOnAColdTargetFromSuspended() throws {
        let (configurations, viewModel) = makeConfigurations()
        let vm = makeInstance(in: viewModel)
        vm.activity.placeForTesting(.suspended)
        try VMInstanceFixture.writeSaveFile(for: vm)
        let snapshot = VMSnapshot(name: "Before first boot", kind: .cold, macAddress: nil)

        let alert = configurations.revertSnapshotConfig(snapshot, vm)

        #expect(alert.message.contains("powered off"))
        #expect(alert.message.contains("discarded"))
        // The warm wording, which promises a replacement session, must not leak.
        #expect(!alert.message.contains("replaced by"))
    }
}
