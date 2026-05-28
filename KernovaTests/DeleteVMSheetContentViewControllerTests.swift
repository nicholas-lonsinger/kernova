import Testing
import AppKit
@testable import Kernova

@Suite("DeleteVMSheetContentViewController Tests")
@MainActor
struct DeleteVMSheetContentViewControllerTests {
    @Test("header title includes the VM name")
    func headerHasVMName() {
        let vc = make(vmName: "MyVM")
        vc.loadViewIfNeeded()
        let labels = collectLabels(in: vc.view)
        #expect(labels.contains { $0.stringValue.contains("MyVM") })
        #expect(labels.contains { $0.stringValue.contains("to Trash?") })
    }

    @Test("in-bundle disks render read-only under their section header")
    func bundledRowsRendered() {
        let bundled = [
            makeDisk(label: "Main Disk", path: "Disk.asif"),
            makeDisk(label: "Extra Disk", path: "AdditionalDisks/extra.asif"),
        ]
        let vc = make(vmName: "MyVM", bundledDisks: bundled)
        vc.loadViewIfNeeded()
        let labels = collectLabels(in: vc.view).map(\.stringValue)
        #expect(labels.contains("Removed with the VM"))
        #expect(labels.contains("Main Disk"))
        #expect(labels.contains("Extra Disk"))
        // Internal disks show the generic in-bundle subtitle, not a path.
        #expect(labels.contains("In-bundle disk image"))
        // No checkboxes are created for read-only bundled rows.
        #expect(vc.checkboxes.isEmpty)
    }

    @Test("one row rendered per external attachment, in order")
    func rowsRendered() {
        let externals = [
            makeAttachment(id: UUID(), label: "Disk A", path: "/tmp/a.asif"),
            makeAttachment(id: UUID(), label: "Installer ISO", path: "/tmp/installer.iso"),
        ]
        let vc = make(vmName: "MyVM", externals: externals)
        vc.loadViewIfNeeded()
        let labels = collectLabels(in: vc.view).map(\.stringValue)
        #expect(labels.contains("Files outside this VM"))
        #expect(labels.contains("Disk A"))
        #expect(labels.contains("/tmp/a.asif"))
        #expect(labels.contains("Installer ISO"))
        #expect(labels.contains("/tmp/installer.iso"))
    }

    @Test("exclusively-owned external starts checked (defaults to trash)")
    func exclusivelyOwnedStartsChecked() {
        let id = UUID()
        let vc = make(vmName: "MyVM", externals: [makeAttachment(id: id, label: "Disk", path: "/tmp/d.img")])
        vc.loadViewIfNeeded()
        #expect(vc.selectedExternalIDs == [id])
        #expect(vc.checkboxes[id]?.state == .on)
    }

    @Test("shared external is locked off and shows a 'kept' note")
    func sharedExternalLockedOff() {
        let id = UUID()
        let shared = makeAttachment(id: id, label: "Shared ISO", path: "/tmp/shared.iso", shared: ["Other VM"])
        let vc = make(vmName: "MyVM", externals: [shared])
        vc.loadViewIfNeeded()
        // Not selectable: no checkbox recorded, nothing selected.
        #expect(vc.checkboxes[id] == nil)
        #expect(vc.selectedExternalIDs.isEmpty)
        let labels = collectLabels(in: vc.view).map(\.stringValue)
        #expect(labels.contains { $0.contains("Kept — still used by") && $0.contains("Other VM") })
    }

    @Test("Cancel button fires delegate's cancel")
    func cancelFiresDelegate() {
        let vc = make(vmName: "MyVM")
        let delegate = MockDelegate()
        vc.delegate = delegate
        vc.loadViewIfNeeded()

        guard let cancel = findButton(titled: "Cancel", in: vc.view) else {
            Issue.record("Expected a Cancel button")
            return
        }
        cancel.performClick(nil)
        #expect(delegate.cancelCount == 1)
        #expect(delegate.confirmedIDChoices.isEmpty)
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
        let delegate = MockDelegate()
        vc.delegate = delegate
        vc.loadViewIfNeeded()

        guard let confirm = findButton(titled: "Move to Trash", in: vc.view) else {
            Issue.record("Expected a Move to Trash button")
            return
        }
        // Both start checked.
        confirm.performClick(nil)
        #expect(delegate.confirmedIDChoices == [[keepID, trashID]])

        // Uncheck one row and confirm again — only the other is returned.
        vc.checkboxes[keepID]?.state = .off
        confirm.performClick(nil)
        #expect(delegate.confirmedIDChoices == [[keepID, trashID], [trashID]])
    }

    @Test("Move to Trash button is the default (Return)")
    func confirmIsDefault() {
        let vc = make(vmName: "MyVM")
        vc.loadViewIfNeeded()
        guard let confirm = findButton(titled: "Move to Trash", in: vc.view) else {
            Issue.record("Expected a Move to Trash button")
            return
        }
        #expect(confirm.keyEquivalent == "\r")
        #expect(confirm.hasDestructiveAction)
    }

    @Test("Cancel button is keyed to Escape")
    func cancelIsEscape() {
        let vc = make(vmName: "MyVM")
        vc.loadViewIfNeeded()
        guard let cancel = findButton(titled: "Cancel", in: vc.view) else {
            Issue.record("Expected a Cancel button")
            return
        }
        #expect(cancel.keyEquivalent == "\u{1B}")
    }

    // The content list's height is driven by an explicit measured constant
    // (see `makeContentList`), so these layout assertions resolve
    // deterministically after a plain layout pass — no window needed.

    @Test("a long disk list caps the visible area and scrolls instead of compressing")
    func longListCapsAndScrolls() throws {
        let bundled = (0..<20).map { makeDisk(label: "Disk \($0)", path: "AdditionalDisks/\($0).asif") }
        let vc = make(vmName: "MyVM", bundledDisks: bundled)
        vc.loadViewIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        let scrollView = try #require(firstScrollView(in: vc.view))
        let documentHeight = try #require(scrollView.documentView).frame.height
        let visibleHeight = scrollView.frame.height

        // The visible area is capped (320pt, +1 slop)…
        #expect(visibleHeight <= 321)
        // …while the document keeps its full content height and overflows, so
        // the rows scroll rather than being squashed to fit.
        #expect(documentHeight > visibleHeight + 100)
        // The scrollbar is a persistent (legacy) gutter, shown when overflowing
        // so the user sees there's more content below.
        #expect(scrollView.scrollerStyle == .legacy)
        #expect(scrollView.verticalScroller?.isHidden == false)
    }

    @Test("a short disk list hugs its content with no cap and no empty gap")
    func shortListHugsContent() throws {
        let vc = make(vmName: "MyVM", bundledDisks: [makeDisk(label: "Main Disk", path: "Disk.asif")])
        vc.loadViewIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        let scrollView = try #require(firstScrollView(in: vc.view))
        let documentHeight = try #require(scrollView.documentView).frame.height
        let visibleHeight = scrollView.frame.height

        // One short row: the visible area matches the content exactly (no
        // scroll, no empty gap) and stays under the cap.
        #expect(visibleHeight < 320)
        #expect(abs(visibleHeight - documentHeight) <= 1)
        // Content fits, so the scrollbar is autohidden — no gutter, no hint.
        #expect(scrollView.verticalScroller?.isHidden == true)
    }

    @Test("a file shared with many VMs renders its wrapped warning without clipping")
    func sharedWarningWrapsWithoutClipping() throws {
        let external = ExternalAttachment(
            id: UUID(), kind: .storageDisk, label: "Installer",
            path: "/Volumes/External/installer.iso",
            sharedWithVMNames: [
                "Windows 11 Pro", "Development Box", "CI Runner Node",
                "Sonoma Test", "Ventura Test", "Sequoia Test",
            ])
        let vc = make(
            vmName: "VM",
            bundledDisks: [makeDisk(label: "Main Disk", path: "Disk.asif")],
            externals: [external])
        vc.loadViewIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        let scrollView = try #require(firstScrollView(in: vc.view))
        let documentView = try #require(scrollView.documentView)
        let warning = try #require(
            collectLabels(in: vc.view).first { $0.stringValue.hasPrefix("Kept — still used by") })

        // The long name list wraps the warning onto multiple lines. Because the
        // document height is measured at the render width, the row keeps its
        // full wrapped height (≥ 2 lines, not compressed to one) and its bottom
        // stays within the document (not clipped). A measurement taken at the
        // wrong width would clip or mis-size it.
        #expect(warning.frame.height > 18)
        let warningMaxY = warning.convert(warning.bounds, to: documentView).maxY
        #expect(warningMaxY <= documentView.frame.height + 1)
    }

    // MARK: - Helpers

    @MainActor
    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for subview in view.subviews {
            if let match = firstScrollView(in: subview) { return match }
        }
        return nil
    }

    @MainActor
    private func make(
        vmName: String,
        bundledDisks: [StorageDisk] = [],
        externals: [ExternalAttachment] = []
    ) -> DeleteVMSheetContentViewController {
        DeleteVMSheetContentViewController(
            vmName: vmName, bundledDisks: bundledDisks, externals: externals
        )
    }

    private func makeDisk(label: String, path: String) -> StorageDisk {
        StorageDisk(path: path, readOnly: false, label: label, isInternal: true, kind: .virtio)
    }

    private func makeAttachment(
        id: UUID, label: String, path: String, shared: [String] = []
    ) -> ExternalAttachment {
        ExternalAttachment(
            id: id,
            kind: .storageDisk,
            label: label,
            path: path,
            sharedWithVMNames: shared
        )
    }

    @MainActor
    private final class MockDelegate: DeleteVMSheetContentViewControllerDelegate {
        var cancelCount = 0
        var confirmedIDChoices: [Set<UUID>] = []

        func deleteVMSheetDidCancel(_ vc: DeleteVMSheetContentViewController) {
            cancelCount += 1
        }

        func deleteVMSheet(
            _ vc: DeleteVMSheetContentViewController,
            didConfirmTrashingExternalIDs ids: Set<UUID>
        ) {
            confirmedIDChoices.append(ids)
        }
    }

    @MainActor
    private func collectLabels(in view: NSView) -> [NSTextField] {
        var out: [NSTextField] = []
        if let field = view as? NSTextField { out.append(field) }
        for subview in view.subviews { out.append(contentsOf: collectLabels(in: subview)) }
        return out
    }

    @MainActor
    private func findButton(titled title: String, in view: NSView) -> NSButton? {
        // Cancel and Move to Trash titles are unique; per-row checkboxes have
        // empty titles, so a title match is sufficient for the action buttons.
        if let button = view as? NSButton, button.title == title {
            return button
        }
        for subview in view.subviews {
            if let match = findButton(titled: title, in: subview) { return match }
        }
        return nil
    }
}
