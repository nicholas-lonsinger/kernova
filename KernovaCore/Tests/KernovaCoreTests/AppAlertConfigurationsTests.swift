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

    @Test("A running VM's force-stop alert keeps the destructive button off Return")
    func forceStopAlertOrdersItsButtons() {
        let (configurations, viewModel) = makeConfigurations()
        let vm = makeInstance(in: viewModel)
        vm.activity.placeForTesting(.running(sessionID: UUID()))

        let alert = configurations.forceStopConfig(vm)

        // Added trailing-edge first, so this reads right-to-left on screen:
        // Force Stop on the leading edge, Stop on Return.
        #expect(alert.buttons.map(\.title) == ["Stop", "Cancel", "Force Stop"])
        #expect(alert.buttons.map(\.role) == [.default, .cancel, .destructive])
    }

    @Test("A refusal a setting lifts offers Open Settings beside OK, which asks for that pane")
    func errorAlertOpensSettings() throws {
        let (configurations, viewModel) = makeConfigurations()
        var shown: [SettingsDestination] = []
        viewModel.onShowSettings = { shown.append($0) }

        let alert = configurations.errorConfig(
            title: "Duplicate Machine ID", message: "Refused.", openingSettingsAt: .pane(.advanced))

        #expect(alert.title == "Duplicate Machine ID")
        #expect(alert.message == "Refused.")
        #expect(alert.buttons.map(\.title) == ["OK", "Open Settings"])
        #expect(alert.buttons.map(\.role) == [.default, .standard])
        try #require(alert.buttons.last).action()
        #expect(shown == [.pane(.advanced)])
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

    @Test("A paused VM's Stop offers Resume and Stop on Return and Force Stop off it")
    func pausedStopAlertLaysOutBothSteps() {
        let (configurations, viewModel) = makeConfigurations()
        let vm = makeInstance(in: viewModel)
        vm.activity.placeForTesting(.livePaused(sessionID: UUID()))

        let alert = configurations.pausedStopConfig(vm)

        #expect(alert.title == "Stop \u{201C}\(vm.name)\u{201D}?")
        #expect(alert.buttons.map(\.title) == ["Resume and Stop", "Cancel", "Force Stop"])
        #expect(alert.buttons.map(\.role) == [.default, .cancel, .destructive])
        #expect(
            alert.message
                == "\u{201C}\(vm.name)\u{201D} is paused and cannot be shut down directly. Resume it to send a "
                + "graceful shutdown, or force stop to terminate it immediately, which loses anything in the guest "
                + "that isn\u{2019}t saved to disk.")
    }

    @Test("A Linux guest's manage alert gives both commands and copies each, where a macOS guest's names Finder")
    func installerMountedOnLinux() {
        let (configurations, _) = makeConfigurations()
        var copied: [String] = []
        let manage = configurations.installerMountedConfig(
            "Ubuntu", guestOS: .linux, purpose: .manage, delivery: .usb
        ) { copied.append($0) }
        #expect(manage.message.contains(LinuxAgentDisk.installCommand(for: .sessionAgent)))
        #expect(manage.message.contains(LinuxAgentDisk.uninstallCommand))
        #expect(manage.message.contains("Adding --system to either also installs or removes the system service."))
        // The lines after it serve a guest with no desktop.
        #expect(manage.message.contains(LinuxAgentDisk.mountAndInstallCommands(for: .both).joined(separator: "\n")))
        #expect(manage.buttons.map(\.title) == ["Copy Install Command", "Done", "Copy Uninstall Command"])
        manage.buttons.first?.action()
        manage.buttons.last?.action()
        #expect(copied == [LinuxAgentDisk.installCommand(for: .sessionAgent), LinuxAgentDisk.uninstallCommand])

        let macOS = configurations.installerMountedConfig(
            "Sequoia", guestOS: .macOS, purpose: .install, delivery: .usb
        ) { copied.append($0) }
        #expect(macOS.message.contains("Finder"))
        #expect(macOS.buttons.map(\.title) == ["OK"])
    }

    @Test("The Linux install question copies the command for the choice it holds, and its Cancel changes nothing")
    func linuxInstallQuestion() {
        let (configurations, viewModel) = makeConfigurations()
        let vm = viewModel.library.admitFixture(name: "Ubuntu", guestOS: .linux, phase: .running(sessionID: UUID()))
        var choice = LinuxAgentInstallChoice.both
        var copied: [String] = []
        let alert = configurations.linuxAgentInstallChoiceConfig(vm, choice: { choice }) { copied.append($0) }

        #expect(alert.title == "What do you want to install in \u{201C}Ubuntu\u{201D}?")
        #expect(alert.message.contains("ejects it once each agent you choose connects"))
        #expect(alert.buttons.map(\.title) == ["Attach and Copy Command", "Cancel"])
        #expect(alert.buttons.map(\.role) == [.default, .cancel])

        alert.buttons.last?.action()
        #expect(copied.isEmpty)
        #expect(vm.configuration.removableMedia == nil)

        // Read when the user answers, not when the alert was built.
        choice = .systemService
        alert.buttons.first?.action()
        #expect(copied == [LinuxAgentDisk.installCommand(for: .systemService)])

        let steps = AppAlertConfigurations.linuxAgentInstallSteps(for: .systemService)
        #expect(steps.precondition == LinuxAgentDisk.installCommandPrecondition)
        #expect(steps.command == LinuxAgentDisk.installCommand(for: .systemService))
        let headless = LinuxAgentDisk.mountAndInstallCommands(for: .systemService)
        #expect(steps.headless.hasSuffix(headless.joined(separator: "\n")))
    }
}
