import AVFoundation
import AppKit
import Testing
import Virtualization

@testable import Kernova

/// The Storage panel's own behavior, drilled into through the shell.
@Suite("VM Settings Storage Panel Tests", .serialized, .admissionGated)
@MainActor
struct VMSettingsStoragePanelTests {
    /// Isolated, pre-cleaned preferences for this suite's `VMLibraryViewModel`.
    ///
    /// Selection/order persistence never touches the real `.standard` domain.
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.vmsettings.storage")

    private func makeViewModel() -> VMLibraryViewModel {
        makeSettingsViewModel(preferences: preferences)
    }

    private func makeInstance(guestOS: VMGuestOS) -> VMInstance {
        makeSettingsInstance(guestOS: guestOS)
    }

    private func makeController(
        guestOS: VMGuestOS, isReadOnly: Bool, category: VMSettingsCategory? = nil
    ) -> (VMSettingsViewController, VMInstance, VMLibraryViewModel) {
        makeSettingsController(
            guestOS: guestOS, isReadOnly: isReadOnly, category: category,
            preferences: preferences)
    }

    // MARK: - Per-row delete confirmation prompt

    @Test("Internal disk delete offers Move-to-Trash only (no keep-file)")
    func deletePromptInternalDisk() {
        let prompt = VMSettingsStoragePanelViewController.attachmentDeletePrompt(
            label: "Extra Disk", isInternal: true, isMainDisk: false,
            isGuestAgent: false, sharedVMNames: [])
        #expect(prompt.actions == [.moveToTrash])
        #expect(prompt.title.contains("Extra Disk"))
    }

    @Test("Main disk delete warns it's the startup disk")
    func deletePromptMainDisk() {
        let prompt = VMSettingsStoragePanelViewController.attachmentDeletePrompt(
            label: "Main Disk", isInternal: true, isMainDisk: true,
            isGuestAgent: false, sharedVMNames: [])
        #expect(prompt.actions == [.moveToTrash])
        #expect(prompt.message.contains("startup disk"))
    }

    @Test("Private external delete offers both Move-to-Trash and Remove-from-VM")
    func deletePromptPrivateExternal() {
        let prompt = VMSettingsStoragePanelViewController.attachmentDeletePrompt(
            label: "Scratch", isInternal: false, isMainDisk: false,
            isGuestAgent: false, sharedVMNames: [])
        #expect(prompt.actions == [.moveToTrash, .removeFromVM])
    }

    @Test("Shared external delete hard-blocks trashing (Remove-from-VM only) and names the VMs")
    func deletePromptSharedExternal() {
        let prompt = VMSettingsStoragePanelViewController.attachmentDeletePrompt(
            label: "Installer", isInternal: false, isMainDisk: false,
            isGuestAgent: false, sharedVMNames: ["macOS Copy", "Linux"])
        #expect(prompt.actions == [.removeFromVM])
        #expect(prompt.message.contains("macOS Copy"))
        #expect(prompt.message.contains("Linux"))
    }

    @Test("Guest Agent delete only detaches and says the installer isn't deleted")
    func deletePromptGuestAgent() {
        let prompt = VMSettingsStoragePanelViewController.attachmentDeletePrompt(
            label: "Kernova Guest Agent", isInternal: false, isMainDisk: false,
            isGuestAgent: true, sharedVMNames: [])
        #expect(prompt.actions == [.removeFromVM])
        #expect(prompt.message.contains("isn't deleted"))
    }

    // MARK: - Attachment row notes

    private func storageRow(in view: NSView) -> AttachmentRowView? {
        firstSubview(AttachmentRowView.self, in: view)
    }

    @Test("The attachment context menu offers Edit Notes between Rename and Get Info")
    func attachmentMenuOffersEditNotes() {
        let (vc, _, _) = makeController(guestOS: .linux, isReadOnly: false)
        let row = storageRow(in: vc.view)
        let menu = row?.contextMenu?()

        let titles = menu?.items.map(\.title) ?? []
        let renameIndex = titles.firstIndex(of: "Rename")
        let notesIndex = titles.firstIndex(of: "Edit Notes")
        let infoIndex = titles.firstIndex(of: "Get Info")
        #expect(renameIndex != nil && notesIndex != nil && infoIndex != nil)
        if let renameIndex, let notesIndex, let infoIndex {
            #expect(renameIndex < notesIndex)
            #expect(notesIndex < infoIndex)
        }
        #expect(menu?.items.first { $0.title == "Edit Notes" }?.isEnabled == true)
    }

    @Test("Edit Notes and Rename are disabled on a read-only VM's storage row")
    func attachmentMenuEditNotesFollowsReadOnly() {
        let (vc, _, _) = makeController(guestOS: .linux, isReadOnly: true)
        let row = storageRow(in: vc.view)
        let menu = row?.contextMenu?()

        #expect(menu?.items.first { $0.title == "Edit Notes" }?.isEnabled == false)
        #expect(menu?.items.first { $0.title == "Rename" }?.isEnabled == false)
    }

    @Test("Edit Notes on the context menu begins inline editing on the row")
    func attachmentMenuEditNotesBeginsEditing() {
        let (vc, _, _) = makeController(guestOS: .linux, isReadOnly: false)
        let window = showInTestWindow(vc.view, size: NSSize(width: 600, height: 800))
        defer { window.close() }
        let row = storageRow(in: vc.view)
        let menu = row?.contextMenu?()
        let editNotes = menu?.items.first { $0.title == "Edit Notes" }

        editNotes.map { _ = $0.target?.perform($0.action, with: $0) }

        let editing = allSubviews(InlineEditableLabel.self, in: vc.view) { $0.isEditable }
        #expect(!editing.isEmpty)
    }
}
