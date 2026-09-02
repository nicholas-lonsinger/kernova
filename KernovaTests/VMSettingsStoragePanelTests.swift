import AVFoundation
import AppKit
import KernovaTestSupport
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
        guestOS: VMGuestOS, isReadOnly: Bool, category: VMSettingsCategory? = .storage,
        phase: VMLifecyclePhase = .stopped
    ) -> (VMSettingsViewController, VMInstance, VMLibraryViewModel) {
        makeSettingsController(
            guestOS: guestOS, isReadOnly: isReadOnly, category: category, phase: phase,
            preferences: preferences)
    }

    // MARK: - Live missing-file badge

    /// Builds a pane over a VM carrying one external disk at `path`, drilled
    /// into Storage.
    private func makeStorageController(externalDiskAt path: String) -> (
        VMSettingsViewController, VMInstance
    ) {
        let viewModel = makeViewModel()
        let instance = makeInstance(guestOS: .linux)
        instance.configuration.storageDisks = [StorageDisk(path: path, label: "Scratch")]
        let vc = VMSettingsViewController(
            instance: instance, viewModel: viewModel, isReadOnly: false)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.storage)
        return (vc, instance)
    }

    private func showsMissingBadge(in vc: VMSettingsViewController) -> Bool {
        guard let panel = vc.panelForTesting(.storage) else { return false }
        return findLabel(containing: "Missing", in: panel) != nil
    }

    @Test("A file change while the pane is hidden leaves the badge live afterwards")
    func missingBadgeStaysLiveAcrossReappearance() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kernova-settings-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("scratch.img")
        let path = url.path(percentEncoded: false)
        FileManager.default.createFile(atPath: path, contents: Data([0]))

        let (vc, _) = makeStorageController(externalDiskAt: path)
        // RATIONALE: genuine no-signal predicate (docs/TESTING.md "Async waits in
        // tests") — the observed effect is an `NSTextField`'s rendered text at
        // the end of a debounced file-system watch, with no Observable or
        // `AsyncGate` signal to arm against.
        try await waitUntil { !self.showsMissingBadge(in: vc) }

        // A change landing while the pane is away ends that observation cycle.
        vc.viewWillDisappear()
        try FileManager.default.removeItem(at: url)
        try await Task.sleep(for: .milliseconds(200))

        // Re-appearing has to start a fresh cycle, so a *later* change still
        // reaches the row — with no `apply()` pass of its own to carry it.
        vc.viewDidAppear()
        try await waitUntil { self.showsMissingBadge(in: vc) }

        FileManager.default.createFile(atPath: path, contents: Data([0]))
        try await waitUntil { !self.showsMissingBadge(in: vc) }
    }

    // MARK: - Section lock hints

    @Test("Each section's lock hint names the states that section is editable in")
    func sectionLockHintsNameTheirOwnCondition() throws {
        let hintText = VMSettingsStoragePanelViewController.removableMediaLockHintText
        // Removable media is hot-pluggable, so the shared "Editable when
        // stopped" would be a claim the user disproves the moment a guest boots.
        #expect(hintText != groupedFormLockHintText)

        // A stopped VM edits both lists, so neither hint shows.
        let (stopped, _, _) = makeController(guestOS: .linux, isReadOnly: false)
        #expect(visibleLockHints(in: stopped.view).isEmpty)

        // Running pins the disks and still takes a hot-plug: the disk hint
        // shows alone.
        let (running, _, _) = makeController(
            guestOS: .linux, isReadOnly: true, phase: .running(sessionID: UUID()))
        #expect(visibleLockHints(in: running.view) == [groupedFormLockHintText])

        // A suspended VM's saved state pins both, so both sections say so.
        let (suspended, _, _) = makeController(
            guestOS: .linux, isReadOnly: true, phase: .suspended)
        #expect(
            Set(visibleLockHints(in: suspended.view)) == [groupedFormLockHintText, hintText])
    }

    /// The tooltip of every lock hint currently on screen.
    private func visibleLockHints(in view: NSView) -> [String] {
        allSubviews(NSStackView.self, in: view) {
            !$0.isHidden && $0.toolTip != nil
                && [
                    groupedFormLockHintText,
                    VMSettingsStoragePanelViewController.removableMediaLockHintText,
                ].contains($0.toolTip ?? "")
        }
        .compactMap(\.toolTip)
    }

    // MARK: - Per-row delete confirmation prompt

    @Test("Internal disk delete offers Move-to-Trash only (no keep-file)")
    func deletePromptInternalDisk() {
        let prompt = VMCommandCore.attachmentDeletePrompt(
            label: "Extra Disk", isInternal: true,
            isGuestAgent: false, sharedVMNames: [])
        #expect(prompt.actions == [.moveToTrash])
        #expect(prompt.title.contains("Extra Disk"))
    }

    @Test("Private external delete offers both Move-to-Trash and Remove-from-VM")
    func deletePromptPrivateExternal() {
        let prompt = VMCommandCore.attachmentDeletePrompt(
            label: "Scratch", isInternal: false,
            isGuestAgent: false, sharedVMNames: [])
        #expect(prompt.actions == [.moveToTrash, .removeFromVM])
    }

    @Test("Shared external delete hard-blocks trashing (Remove-from-VM only) and names the VMs")
    func deletePromptSharedExternal() {
        let prompt = VMCommandCore.attachmentDeletePrompt(
            label: "Installer", isInternal: false,
            isGuestAgent: false, sharedVMNames: ["macOS Copy", "Linux"])
        #expect(prompt.actions == [.removeFromVM])
        #expect(prompt.message.contains("macOS Copy"))
        #expect(prompt.message.contains("Linux"))
    }

    @Test("Guest Agent delete only detaches and says the installer isn't deleted")
    func deletePromptGuestAgent() {
        let prompt = VMCommandCore.attachmentDeletePrompt(
            label: "Kernova Guest Agent", isInternal: false,
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

    @Test("Edit Notes and Rename are disabled on a running VM's storage row")
    func attachmentMenuEditNotesFollowsTheDiskGate() {
        // The model gate, not the route: a running VM's disks are pinned by the
        // `VZVirtualMachine`, which is what closes the row's edits.
        let (vc, _, _) = makeController(
            guestOS: .linux, isReadOnly: true, phase: .running(sessionID: UUID()))
        let row = storageRow(in: vc.view)
        let menu = row?.contextMenu?()

        #expect(menu?.items.first { $0.title == "Edit Notes" }?.isEnabled == false)
        #expect(menu?.items.first { $0.title == "Rename" }?.isEnabled == false)
    }

    @Test("Every row of a two-disk VM offers Remove\u{2026}, Disk.asif included")
    func attachmentMenuOffersRemoveOnEveryDiskWithASibling() {
        let viewModel = makeViewModel()
        let instance = makeInstance(guestOS: .linux)
        let main = StorageDisk.mainDisk(layout: VMBundleLayout(bundleURL: instance.bundleURL))
        instance.configuration.storageDisks = [
            main,
            StorageDisk(path: "AdditionalDisks/x.asif", label: "Extra", isInternal: true),
        ]
        let vc = VMSettingsViewController(
            instance: instance, viewModel: viewModel, isReadOnly: false)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.storage)

        let rows = allSubviews(AttachmentRowView.self, in: vc.view)
        #expect(rows.count == 2)
        let mainTitles = rows.first?.contextMenu?()?.items.map(\.title) ?? []
        let extraTitles = rows.dropFirst().first?.contextMenu?()?.items.map(\.title) ?? []

        #expect(mainTitles.contains("Remove\u{2026}"))
        #expect(mainTitles.contains("Rename"))
        #expect(extraTitles.contains("Remove\u{2026}"))
    }

    @Test("A VM's only disk offers no Remove\u{2026}")
    func attachmentMenuOmitsRemoveOnTheSoleDisk() {
        let viewModel = makeViewModel()
        let instance = makeInstance(guestOS: .linux)
        instance.configuration.storageDisks = [
            StorageDisk(path: "AdditionalDisks/x.asif", label: "Extra", isInternal: true)
        ]
        let vc = VMSettingsViewController(
            instance: instance, viewModel: viewModel, isReadOnly: false)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.storage)

        let rows = allSubviews(AttachmentRowView.self, in: vc.view)
        #expect(rows.count == 1)
        let titles = rows.first?.contextMenu?()?.items.map(\.title) ?? []

        #expect(!titles.contains("Remove\u{2026}"))
        #expect(titles.contains("Rename"))
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
