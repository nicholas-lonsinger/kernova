import Testing
import AppKit
@testable import Kernova

@Suite("DeleteVMSheetContentViewController Tests")
@MainActor
struct DeleteVMSheetContentViewControllerTests {
    @Test("header title includes the VM name")
    func headerHasVMName() {
        let vc = make(vmName: "MyVM", externals: [])
        vc.loadViewIfNeeded()
        let labels = collectLabels(in: vc.view)
        #expect(labels.contains { $0.stringValue.contains("MyVM") })
        #expect(labels.contains { $0.stringValue.contains("to Trash?") })
    }

    @Test("one row rendered per attachment, in order")
    func rowsRendered() {
        let externals = [
            makeAttachment(id: UUID(), label: "Disk A", path: "/tmp/a.asif"),
            makeAttachment(id: UUID(), label: "Installer ISO", path: "/tmp/installer.iso"),
        ]
        let vc = make(vmName: "MyVM", externals: externals)
        vc.loadViewIfNeeded()
        let labels = collectLabels(in: vc.view).map(\.stringValue)
        #expect(labels.contains("Disk A"))
        #expect(labels.contains("/tmp/a.asif"))
        #expect(labels.contains("Installer ISO"))
        #expect(labels.contains("/tmp/installer.iso"))
    }

    @Test("checkbox starts unchecked")
    func checkboxStartsUnchecked() {
        let vc = make(vmName: "MyVM", externals: [])
        vc.loadViewIfNeeded()
        #expect(!vc.trashExternalsChecked)
    }

    @Test("Cancel button fires delegate's cancel")
    func cancelFiresDelegate() {
        let vc = make(vmName: "MyVM", externals: [])
        let delegate = MockDelegate()
        vc.delegate = delegate
        vc.loadViewIfNeeded()

        guard let cancel = findButton(titled: "Cancel", in: vc.view) else {
            Issue.record("Expected a Cancel button")
            return
        }
        cancel.performClick(nil)
        #expect(delegate.cancelCount == 1)
        #expect(delegate.confirmedTrashChoices.isEmpty)
    }

    @Test("Move to Trash button fires delegate's confirm with current checkbox state")
    func confirmFiresDelegateWithCheckboxState() {
        let vc = make(vmName: "MyVM", externals: [])
        let delegate = MockDelegate()
        vc.delegate = delegate
        vc.loadViewIfNeeded()

        guard let confirm = findButton(titled: "Move to Trash", in: vc.view) else {
            Issue.record("Expected a Move to Trash button")
            return
        }
        // Checkbox starts unchecked.
        confirm.performClick(nil)
        #expect(delegate.confirmedTrashChoices == [false])

        guard let toggle = findButton(titled: "Also move these files to Trash", in: vc.view)
        else {
            Issue.record("Expected the trash-externals checkbox")
            return
        }
        toggle.state = .on
        confirm.performClick(nil)
        #expect(delegate.confirmedTrashChoices == [false, true])
    }

    @Test("Move to Trash button is the default (Return)")
    func confirmIsDefault() {
        let vc = make(vmName: "MyVM", externals: [])
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
        let vc = make(vmName: "MyVM", externals: [])
        vc.loadViewIfNeeded()
        guard let cancel = findButton(titled: "Cancel", in: vc.view) else {
            Issue.record("Expected a Cancel button")
            return
        }
        #expect(cancel.keyEquivalent == "\u{1B}")
    }

    // MARK: - Helpers

    @MainActor
    private func make(vmName: String, externals: [ExternalAttachment])
        -> DeleteVMSheetContentViewController
    {
        DeleteVMSheetContentViewController(vmName: vmName, externals: externals)
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
        var confirmedTrashChoices: [Bool] = []

        func deleteVMSheetDidCancel(_ vc: DeleteVMSheetContentViewController) {
            cancelCount += 1
        }

        func deleteVMSheet(
            _ vc: DeleteVMSheetContentViewController,
            didConfirmTrashExternals trashExternals: Bool
        ) {
            confirmedTrashChoices.append(trashExternals)
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
        // All button titles in the sheet (Cancel, Move to Trash, the
        // checkbox label) are unique, so a title match is sufficient.
        if let button = view as? NSButton, button.title == title {
            return button
        }
        for subview in view.subviews {
            if let match = findButton(titled: title, in: subview) { return match }
        }
        return nil
    }
}
