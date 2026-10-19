import AVFoundation
import AppKit
import KernovaKit
import KernovaTestSupport
import Testing
import Virtualization

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// The Storage panel's own behavior, drilled into through the shell.
@Suite("VM Settings Storage Panel Tests", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct VMSettingsStoragePanelTests {
    private let preferences = makeTestPreferences()
    private let scratch = TestScratchDirectory(prefix: "VMSettingsStoragePanelTests")

    private func makeViewModel() -> VMLibraryViewModel {
        makeSettingsViewModel(preferences: preferences)
    }

    private func makeController(
        guestOS: VMGuestOS, isReadOnly: Bool, category: VMSettingsCategory? = .storage,
        phase: VMLifecyclePhase = .stopped, holdsSavedState: Bool = false
    ) -> (VMSettingsViewController, VMInstance, VMLibraryViewModel) {
        makeSettingsController(
            guestOS: guestOS, isReadOnly: isReadOnly, category: category, phase: phase,
            holdsSavedState: holdsSavedState, preferences: preferences)
    }

    // MARK: - Live missing-file badge

    /// Builds a pane over a VM carrying one external disk at `path`, drilled
    /// into Storage.
    private func makeStorageController(externalDiskAt path: String) -> (
        VMSettingsViewController, VMInstance
    ) {
        let viewModel = makeViewModel()
        let instance = makeSettingsInstance(guestOS: .linux) {
            $0.storageDisks = [StorageDisk(path: path, label: "Scratch")]
        }
        let vc = makeSettingsPane(
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
        let directory = scratch.url.appendingPathComponent(
            "kernova-settings-storage", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("scratch.img")
        let path = url.path(percentEncoded: false)
        FileManager.default.createFile(atPath: path, contents: Data([0]))

        let (vc, _) = makeStorageController(externalDiskAt: path)
        // Genuine no-signal predicate — the observed effect is an
        // `NSTextField`'s rendered text at the end of a debounced file-system
        // watch, with no Observable or `AsyncGate` signal to arm against.
        try await waitUntil { !self.showsMissingBadge(in: vc) }

        // A change landing while the pane is away ends that observation cycle.
        vc.viewWillDisappear()
        try FileManager.default.removeItem(at: url)
        try await Task.sleep(for: .milliseconds(200))

        // Re-appearing has to start a fresh cycle, so a *later* change still
        // reaches the row.
        vc.viewDidAppear()
        try await waitUntil { self.showsMissingBadge(in: vc) }

        FileManager.default.createFile(atPath: path, contents: Data([0]))
        try await waitUntil { !self.showsMissingBadge(in: vc) }
    }

    /// A pane over a stopped VM carrying one external disk at `path`, whose
    /// sizes `files` reports, showing `category` — `nil` for the overview.
    private func makeMeasuredDiskPane(
        at path: String, files: MockVMBundleMachineFiles, showing category: VMSettingsCategory?
    ) -> (VMSettingsViewController, StorageDisk) {
        let disk = StorageDisk(path: path, label: "Scratch")
        let viewModel = makeSettingsViewModel(preferences: preferences, machineFiles: files)
        let instance = viewModel.library.registerFixture(guestOS: .linux) {
            $0.storageDisks = [disk]
        }
        let vc = makeSettingsPane(instance: instance, viewModel: viewModel, isReadOnly: false)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        if let category { vc.showCategory(category) }
        return (vc, disk)
    }

    private static let scratchSizes = VMBundleLayout.DiskSizes(
        onDiskBytes: 2_000_000_000, capacityBytes: 32_000_000_000)
    private static let scratchSubtitle =
        "\(DataFormatters.formatBytes(2_000_000_000)) (used) / "
        + "\(DataFormatters.formatBytes(32_000_000_000)) (allocated)"

    /// Whether the overview's Storage card states `text`.
    private func storageCardStates(_ text: String, in vc: VMSettingsViewController) -> Bool {
        guard let card = vc.overviewCardForTesting(.storage) else { return false }
        return findLabel(withText: text, in: card) != nil
    }

    // Each file change below is followed by the re-probe a volume mount or
    // unmount runs. Genuine no-signal predicates: the repaint lands at the end
    // of the off-main probe and the measurement it issues.

    @Test("A stopped VM's disk whose file appears is measured again, and its row states the sizes")
    func aFileAppearingRemeasuresTheRow() async throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let path = scratch.url.appendingPathComponent("appears.img").path(percentEncoded: false)
        let files = MockVMBundleMachineFiles()
        let (vc, disk) = makeMeasuredDiskPane(at: path, files: files, showing: .storage)
        let panel = try #require(vc.panelForTesting(.storage))
        try await waitUntil { self.showsMissingBadge(in: vc) }
        await vc.overviewForTesting.attachmentSizeTaskForTesting?.value
        let readsWhileMissing = files.diskSizeReads

        // The file a volume mount brings back, and the figures it now reads.
        files.setDiskSizes(Self.scratchSizes, for: disk.id)
        FileManager.default.createFile(atPath: path, contents: Data([0]))
        vc.overviewForTesting.fileMonitor.revalidate()

        try await waitUntil { findLabel(withText: Self.scratchSubtitle, in: panel) != nil }
        #expect(!showsMissingBadge(in: vc))
        #expect(files.diskSizeReads > readsWhileMissing)
    }

    @Test("A stopped VM's disk whose file goes missing is measured again, and its row badges missing")
    func aFileGoingMissingRemeasuresTheRow() async throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let url = scratch.url.appendingPathComponent("vanishes.img")
        let path = url.path(percentEncoded: false)
        FileManager.default.createFile(atPath: path, contents: Data([0]))
        let files = MockVMBundleMachineFiles()
        let (vc, disk) = makeMeasuredDiskPane(at: path, files: files, showing: nil)
        files.setDiskSizes(Self.scratchSizes, for: disk.id)
        vc.showCategory(.storage)
        let panel = try #require(vc.panelForTesting(.storage))
        try await waitUntil { findLabel(withText: Self.scratchSubtitle, in: panel) != nil }
        let readsWhilePresent = files.diskSizeReads

        // The volume it lived on unmounts: the file reads as nothing.
        files.setDiskSizes(VMBundleLayout.DiskSizes(), for: disk.id)
        try FileManager.default.removeItem(at: url)
        vc.overviewForTesting.fileMonitor.revalidate()

        try await waitUntil { self.showsMissingBadge(in: vc) }
        try await waitUntil { files.diskSizeReads > readsWhilePresent }
        await vc.overviewForTesting.attachmentSizeTaskForTesting?.value
        #expect(vc.overviewForTesting.resolved.attachmentSizes[disk.id] == VMBundleLayout.DiskSizes())
        #expect(findLabel(withText: Self.scratchSubtitle, in: panel) == nil)
    }

    @Test("The overview alone follows a disk's file: the card states it once it appears, and Unknown once it goes")
    func theOverviewCardFollowsTheFile() async throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let url = scratch.url.appendingPathComponent("card.img")
        let path = url.path(percentEncoded: false)
        let files = MockVMBundleMachineFiles()
        let (vc, disk) = makeMeasuredDiskPane(at: path, files: files, showing: nil)
        let unknown = VMBundleLayout.DiskSizes().allocatedText
        // The overview seeds the monitor itself, with no panel ever built.
        try await waitUntil { !vc.overviewForTesting.fileMonitor.exists(path) }
        try await waitUntil { self.storageCardStates(unknown, in: vc) }

        files.setDiskSizes(Self.scratchSizes, for: disk.id)
        FileManager.default.createFile(atPath: path, contents: Data([0]))
        vc.overviewForTesting.fileMonitor.revalidate()
        try await waitUntil {
            self.storageCardStates(DataFormatters.formatBytes(32_000_000_000), in: vc)
        }

        files.setDiskSizes(VMBundleLayout.DiskSizes(), for: disk.id)
        try FileManager.default.removeItem(at: url)
        vc.overviewForTesting.fileMonitor.revalidate()
        try await waitUntil { self.storageCardStates(unknown, in: vc) }
    }

    @Test("Each row paints the pane's measured sizes: the in-bundle label or path until they land")
    func rowsPaintTheResolvedSizes() async throws {
        // The external files exist, so neither row reads as missing; their
        // figures come from the mock alone.
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let dataPath = scratch.url.appendingPathComponent("data.img").path(percentEncoded: false)
        let stickPath = scratch.url.appendingPathComponent("stick.img").path(percentEncoded: false)
        FileManager.default.createFile(atPath: dataPath, contents: Data([0]))
        FileManager.default.createFile(atPath: stickPath, contents: Data([0]))
        let main = StorageDisk(path: "Disk.asif", label: "Main Disk", isInternal: true)
        let data = StorageDisk(path: dataPath, label: "Data")
        let stick = RemovableMediaItem(path: stickPath)
        let files = MockVMBundleMachineFiles()
        files.setDiskSizes(
            VMBundleLayout.DiskSizes(onDiskBytes: 3_000_000_000, capacityBytes: 64_000_000_000), for: main.id)
        files.setDiskSizes(VMBundleLayout.DiskSizes(onDiskBytes: 1_000_000), for: stick.id)
        // `data` is left unseeded, so it measures unreadable.
        let viewModel = makeSettingsViewModel(preferences: preferences, machineFiles: files)
        let instance = viewModel.library.registerFixture(guestOS: .linux) {
            $0.storageDisks = [main, data]
            $0.removableMedia = [stick]
        }
        let vc = makeSettingsPane(instance: instance, viewModel: viewModel, isReadOnly: false)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.storage)
        let panel = try #require(vc.panelForTesting(.storage))
        // Nothing has suspended since the measurement was issued.
        #expect(findLabel(withText: "In-bundle disk image", in: panel) != nil)
        #expect(findLabel(withText: stickPath, in: panel) != nil)

        await vc.overviewForTesting.attachmentSizeTaskForTesting?.value

        let used = DataFormatters.formatBytes(3_000_000_000)
        let allocated = DataFormatters.formatBytes(64_000_000_000)
        #expect(findLabel(withText: "\(used) (used) / \(allocated) (allocated)", in: panel) != nil)
        #expect(findLabel(withText: "\(DataFormatters.formatBytes(1_000_000)) used", in: panel) != nil)
        #expect(findLabel(withText: dataPath, in: panel) != nil)

        // A newer measurement repaints the same row.
        let grown = DataFormatters.formatBytes(5_000_000_000)
        files.setDiskSizes(
            VMBundleLayout.DiskSizes(onDiskBytes: 5_000_000_000, capacityBytes: 64_000_000_000), for: main.id)
        vc.showCategory(.storage)
        await vc.overviewForTesting.attachmentSizeTaskForTesting?.value
        #expect(findLabel(withText: "\(grown) (used) / \(allocated) (allocated)", in: panel) != nil)
    }

    // MARK: - Section lock hints

    @Test("Each section's lock hint names the states that section is editable in")
    func sectionLockHintsNameTheirOwnCondition() throws {
        let hintText = VMSettingsEditableStates.stoppedOrRunning.lockHint
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
            guestOS: .linux, isReadOnly: true, phase: .suspended, holdsSavedState: true)
        #expect(
            Set(visibleLockHints(in: suspended.view)) == [groupedFormLockHintText, hintText])
    }

    /// The tooltip of every lock hint currently on screen.
    private func visibleLockHints(in view: NSView) -> [String] {
        allSubviews(NSStackView.self, in: view) {
            !$0.isHidden && $0.toolTip != nil
                && [
                    groupedFormLockHintText,
                    VMSettingsEditableStates.stoppedOrRunning.lockHint,
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
        #expect(prompt.kind == .removeAttachment)
        #expect(prompt.confirmTitle == "Move to Trash")
        #expect(prompt.confirmIsDestructive)
        #expect(prompt.alternatives.isEmpty)
        #expect(prompt.title.contains("Extra Disk"))
    }

    @Test("Private external delete offers both Move-to-Trash and Remove-from-VM")
    func deletePromptPrivateExternal() {
        let prompt = VMCommandCore.attachmentDeletePrompt(
            label: "Scratch", isInternal: false,
            isGuestAgent: false, sharedVMNames: [])
        #expect(prompt.confirmTitle == "Move to Trash")
        #expect(prompt.confirmIsDestructive)
        #expect(prompt.alternatives.map(\.title) == ["Remove from VM"])
        // Keeping the file is the whole of what the alternative changes, and
        // it destroys nothing.
        #expect(prompt.alternatives.map(\.keepsFile) == [true])
        #expect(prompt.alternatives.map(\.isDestructive) == [false])
    }

    @Test("Shared external delete hard-blocks trashing (Remove-from-VM only) and names the VMs")
    func deletePromptSharedExternal() {
        let prompt = VMCommandCore.attachmentDeletePrompt(
            label: "Installer", isInternal: false,
            isGuestAgent: false, sharedVMNames: ["macOS Copy", "Linux"])
        #expect(prompt.confirmTitle == "Remove from VM")
        #expect(!prompt.confirmIsDestructive)
        #expect(prompt.alternatives.isEmpty)
        #expect(prompt.message.contains("macOS Copy"))
        #expect(prompt.message.contains("Linux"))
    }

    @Test("Guest Agent delete only detaches and says the installer isn't deleted")
    func deletePromptGuestAgent() {
        let prompt = VMCommandCore.attachmentDeletePrompt(
            label: "Kernova Guest Agent", isInternal: false,
            isGuestAgent: true, sharedVMNames: [])
        #expect(prompt.confirmTitle == "Remove from VM")
        #expect(!prompt.confirmIsDestructive)
        #expect(prompt.alternatives.isEmpty)
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
        let instance = makeSettingsInstance(guestOS: .linux) {
            let bundleURL = VMInstanceFixture.bundleURL(for: $0.id)
            $0.storageDisks = [
                StorageDisk.mainDisk(layout: VMBundleLayout(bundleURL: bundleURL)),
                StorageDisk(path: "AdditionalDisks/x.asif", label: "Extra", isInternal: true),
            ]
        }
        let vc = makeSettingsPane(
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

    @Test("A stopped VM's snapshot delete leaves disk edits open and offers no disk creation or trash")
    func diskCreationAndTrashAreOfferedOnlyWhereTheyAreTaken() {
        let viewModel = makeViewModel()
        let instance = makeSettingsInstance(guestOS: .linux) {
            let bundleURL = VMInstanceFixture.bundleURL(for: $0.id)
            $0.storageDisks = [
                StorageDisk.mainDisk(layout: VMBundleLayout(bundleURL: bundleURL)),
                StorageDisk(path: "AdditionalDisks/x.asif", label: "Extra", isInternal: true),
            ]
        }
        // A snapshot delete tolerates machine-key and removable-media edits,
        // but holds the VM against every other operation — a disk's creation
        // and trash among them.
        instance.activity.placeForTesting(.operating(.deletingSnapshot, from: .stopped))
        let vc = makeSettingsPane(
            instance: instance, viewModel: viewModel, isReadOnly: false)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.storage)

        let buttons = allSubviews(NSButton.self, in: vc.view)
        let creates = buttons.filter { $0.title == "Create New Disk\u{2026}" }
        #expect(creates.count == 2)
        #expect(creates.allSatisfy { !$0.isEnabled })
        let attaches = buttons.filter { $0.title == "Attach Disk\u{2026}" }
        #expect(attaches.count == 2)
        #expect(attaches.allSatisfy { $0.isEnabled })

        let menu = allSubviews(AttachmentRowView.self, in: vc.view).first?.contextMenu?()
        #expect(menu?.items.first { $0.title == "Rename" }?.isEnabled == true)
        #expect(menu?.items.first { $0.title == "Remove\u{2026}" }?.isEnabled == false)

        // Once the delete rests the VM, both are offered again.
        instance.activity.placeForTesting(.stopped)
        vc.reconfigure(instance: instance, viewModel: viewModel, isReadOnly: false)
        #expect(
            allSubviews(NSButton.self, in: vc.view)
                .filter { $0.title == "Create New Disk\u{2026}" }.allSatisfy { $0.isEnabled })
        let rested = allSubviews(AttachmentRowView.self, in: vc.view).first?.contextMenu?()
        #expect(rested?.items.first { $0.title == "Remove\u{2026}" }?.isEnabled == true)
    }

    @Test("A live VM's snapshot delete keeps removable media editable and the disks pinned")
    func removableMediaStaysEditableUnderALiveSnapshotDelete() {
        let viewModel = makeViewModel()
        let instance = makeSettingsInstance(guestOS: .linux) { _ in }
        instance.activity.placeForTesting(
            .operating(.deletingSnapshot, from: .running(sessionID: UUID())))
        let vc = makeSettingsPane(instance: instance, viewModel: viewModel, isReadOnly: true)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.storage)

        let attaches = allSubviews(NSButton.self, in: vc.view)
            .filter { $0.title == "Attach Disk\u{2026}" }
        #expect(attaches.count == 2)
        #expect(attaches.filter { $0.isEnabled }.count == 1)
        #expect(visibleLockHints(in: vc.view) == [groupedFormLockHintText])
    }

    @Test("A VM's only disk offers no Remove\u{2026}")
    func attachmentMenuOmitsRemoveOnTheSoleDisk() {
        let viewModel = makeViewModel()
        let instance = makeSettingsInstance(guestOS: .linux) {
            $0.storageDisks = [
                StorageDisk(path: "AdditionalDisks/x.asif", label: "Extra", isInternal: true)
            ]
        }
        let vc = makeSettingsPane(
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
        showInTestWindow(vc.view, size: NSSize(width: 600, height: 800))
        let row = storageRow(in: vc.view)
        let menu = row?.contextMenu?()
        let editNotes = menu?.items.first { $0.title == "Edit Notes" }

        editNotes.map { _ = $0.target?.perform($0.action, with: $0) }

        let editing = allSubviews(InlineEditableLabel.self, in: vc.view) { $0.isEditable }
        #expect(!editing.isEmpty)
    }
}
