import AppKit
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaUI

@Suite("DeleteVMSheetContentViewController Tests", .caseScoped)
@MainActor
struct DeleteVMSheetContentViewControllerTests {
    @Test("a suspended VM's saved state is listed alongside the in-bundle disks")
    func savedStateRowRendered() {
        let vc = make(
            vmName: "MyVM",
            bundledDisks: [makeDisk(label: "Main Disk", path: "Disk.asif")],
            hasSavedState: true)
        vc.loadViewIfNeeded()
        let labels = collectLabels(in: vc.view).map(\.stringValue)
        #expect(labels.contains("Removed with the VM"))
        #expect(labels.contains("Saved State"))
        // Read-only like the disk rows — the saved state can't be kept behind.
        #expect(vc.checkboxes.isEmpty)
    }

    @Test("Cancel button fires onCancel")
    func cancelFiresCallback() {
        let vc = make(vmName: "MyVM")
        var cancelCount = 0
        var confirmedIDChoices: [Set<UUID>] = []
        vc.onCancel = { cancelCount += 1 }
        vc.onConfirm = { confirmedIDChoices.append($0) }
        vc.loadViewIfNeeded()

        guard let cancel = findButton(titled: "Cancel", in: vc.view) else {
            Issue.record("Expected a Cancel button")
            return
        }
        cancel.performClick(nil)
        #expect(cancelCount == 1)
        #expect(confirmedIDChoices.isEmpty)
    }

    @Test("Move to Trash returns the ids of the checked externals")
    func confirmReturnsSelectedExternalIDs() {
        let keepID = UUID()
        let trashID = UUID()
        let externals = [
            makeAttachment(id: keepID, label: "Keep", path: "/tmp/keep.img"),
            makeAttachment(id: trashID, label: "Trash", path: "/tmp/trash.img"),
        ]
        let vc = make(vmName: "MyVM", externals: externals)
        var confirmedIDChoices: [Set<UUID>] = []
        vc.onConfirm = { confirmedIDChoices.append($0) }
        vc.loadViewIfNeeded()

        guard let confirm = findButton(titled: "Move to Trash", in: vc.view) else {
            Issue.record("Expected a Move to Trash button")
            return
        }
        // Both start unchecked: confirming keeps every external file.
        confirm.performClick(nil)
        #expect(confirmedIDChoices == [[]])

        // Check one row and confirm again — only that id is returned.
        vc.checkboxes[trashID]?.state = .on
        confirm.performClick(nil)
        #expect(confirmedIDChoices == [[], [trashID]])
    }

    // MARK: - Immediate-delete mode

    @Test("a single snapshot reads in the singular")
    func snapshotRowSingular() {
        let vc = make(vmName: "MyVM", snapshotCount: 1)
        vc.loadViewIfNeeded()
        #expect(collectLabels(in: vc.view).map(\.stringValue).contains("1 in-bundle restore point"))
    }

    @Test("immediate mode confirm button reads Delete Immediately and is not the Return default")
    func immediateModeConfirmButton() {
        let vc = make(vmName: "MyVM", mode: .immediate)
        vc.loadViewIfNeeded()
        guard let confirm = findButton(titled: "Delete Immediately", in: vc.view) else {
            Issue.record("Expected a Delete Immediately button")
            return
        }
        // No Return default for the irreversible action; still styled destructive.
        #expect(confirm.keyEquivalent == "")
        #expect(confirm.hasDestructiveAction)
        // The trash-mode title must not also be present.
        #expect(findButton(titled: "Move to Trash", in: vc.view) == nil)
    }

    // The content list's height is driven by an explicit measured constant
    // (see `makeContentList`), so these layout assertions resolve
    // deterministically after a plain layout pass — no window needed.

    // MARK: - Helpers

    @MainActor
    private func make(
        vmName: String,
        bundledDisks: [StorageDisk] = [],
        externals: [ExternalAttachment] = [],
        hasSavedState: Bool = false,
        snapshotCount: Int = 0,
        mode: DeleteVMSheetContentViewController.Mode = .trash
    ) -> DeleteVMSheetContentViewController {
        DeleteVMSheetContentViewController(
            prompt: makePrompt(vmName: vmName, mode: mode),
            bundledDisks: bundledDisks, externals: externals,
            hasSavedState: hasSavedState, snapshotCount: snapshotCount, mode: mode
        )
    }

    /// A confirmation shaped like the one `VMCommandCore.deletePrompt` composes.
    ///
    /// This suite covers what the sheet does with a prompt; the words in one are
    /// the core's, asserted in `VMCommandCoreTests`.
    private func makePrompt(
        vmName: String, mode: DeleteVMSheetContentViewController.Mode
    ) -> ConfirmationPrompt {
        ConfirmationPrompt(
            kind: .deleteVM,
            title: mode == .immediate
                ? "Delete \u{201C}\(vmName)\u{201D} Immediately?"
                : "Move \u{201C}\(vmName)\u{201D} to the Trash?",
            message: "What goes with \u{201C}\(vmName)\u{201D}, in one sentence.",
            confirmTitle: mode == .immediate ? "Delete Immediately" : "Move to Trash",
            dismissTitle: "Cancel")
    }

    private func makeDisk(label: String, path: String) -> StorageDisk {
        StorageDisk(path: path, readOnly: false, label: label, isInternal: true, kind: .virtio)
    }

    private func makeAttachment(
        id: UUID, label: String, path: String, shared: [String] = [], missing: Bool = false
    ) -> ExternalAttachment {
        ExternalAttachment(
            reference: ExternalFileReference(
                id: id, kind: .storageDisk, label: label, path: path, bookmark: nil, readOnly: false),
            sharedWithVMNames: shared,
            isMissing: missing
        )
    }
}
