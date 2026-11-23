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

    // MARK: - The start-failed removal offer

    private func makeStartFailure(
        _ reason: StartFailedAttachment.Reason, message: String, verb: VMVerb = .start,
        kind: StartFailedAttachment.Kind = .storageDisk
    ) -> StartFailedAttachment {
        StartFailedAttachment(
            verb: verb, kind: kind, reason: reason, id: UUID(), label: "Archive",
            message: message)
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
}
