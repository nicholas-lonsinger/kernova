import AppKit
import Testing

@testable import Kernova

@Suite("SnapshotInfoPopover Tests", .admissionGated)
@MainActor
struct SnapshotInfoPopoverContentViewControllerTests {
    private func makeController(
        kind: VMSnapshotKind, notes: String = ""
    ) -> SnapshotInfoPopoverContentViewController {
        let snapshot = VMSnapshot(
            name: "Before the update", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            notes: notes, kind: kind)
        let controller = SnapshotInfoPopoverContentViewController(
            snapshot: snapshot, onDiskText: "2 GB")
        controller.loadViewIfNeeded()
        return controller
    }

    @Test("The facts grid says what a memory-and-disks snapshot holds")
    func warmNamesMemoryAndDisks() {
        let controller = makeController(kind: .warm)
        #expect(findLabel(withText: "Captured", in: controller.view) != nil)
        #expect(findLabel(withText: "Memory and disks", in: controller.view) != nil)
    }

    @Test("The facts grid says what a disks-only snapshot holds")
    func coldNamesDisksOnly() {
        let controller = makeController(kind: .cold)
        #expect(findLabel(withText: "Disks only", in: controller.view) != nil)
    }

    @Test("Notes are shown only when the snapshot carries one")
    func notesAppearOnlyWhenPresent() {
        #expect(findLabel(withText: "Notes", in: makeController(kind: .warm).view) == nil)
        let annotated = makeController(kind: .warm, notes: "tools configured")
        #expect(findLabel(withText: "tools configured", in: annotated.view) != nil)
    }
}
