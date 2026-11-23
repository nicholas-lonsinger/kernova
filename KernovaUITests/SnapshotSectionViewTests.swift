import AppKit
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

@Suite("SnapshotSectionView Tests", .caseScoped, .scopedWindows)
@MainActor
struct SnapshotSectionViewTests {
    private func makeSnapshot(
        _ name: String, offsetSeconds: TimeInterval = 0, notes: String = ""
    ) -> VMSnapshot {
        VMSnapshot(
            name: name, createdAt: Date(timeIntervalSince1970: 1_700_000_000 + offsetSeconds),
            notes: notes, macAddress: nil)
    }

    private func revertButtons(in view: NSView) -> [NSButton] {
        allSubviews(NSButton.self, in: view) { $0.title == "Revert" }
    }

    /// Renders the section the way the panel does, `baseline`'s row marked as
    /// the Ephemeral baseline when one is given.
    private func render(
        _ view: SnapshotSectionView, manifest: VMSnapshotManifest, canTakeSnapshot: Bool,
        canRevert: Bool, canDelete: Bool = true, baseline: VMSnapshot? = nil,
        canEditMetadata: Bool = true
    ) {
        view.update(
            manifest: manifest, canTakeSnapshot: canTakeSnapshot, canRevert: canRevert,
            canRename: canEditMetadata, canSetNotes: canEditMetadata, canDelete: canDelete,
            baselineID: baseline?.id)
    }

    // MARK: - Actions

    @Test("A row's Revert button names that row's snapshot")
    func revertButtonNamesItsRow() {
        let view = SnapshotSectionView()
        var reverted: [VMSnapshot] = []
        view.onRevert = { reverted.append($0) }
        let older = makeSnapshot("Older")
        let newer = makeSnapshot("Newer", offsetSeconds: 60)
        render(
            view, manifest: VMSnapshotManifest(snapshots: [older, newer]),
            canTakeSnapshot: true, canRevert: true)

        // Rows render newest first, so the second button belongs to "Older".
        let buttons = revertButtons(in: view)
        #expect(buttons.count == 2)
        buttons.last.map { _ = $0.target?.perform($0.action, with: $0) }

        #expect(reverted == [older])
    }

    // MARK: - Row menu

    @Test("The row menu's Delete names its snapshot")
    func rowMenuDeleteNamesItsSnapshot() {
        let view = SnapshotSectionView()
        var deleted: [VMSnapshot] = []
        view.onDelete = { deleted.append($0) }
        let snapshot = makeSnapshot("One")
        render(
            view, manifest: VMSnapshotManifest(snapshots: [snapshot]), canTakeSnapshot: true,
            canRevert: true)

        let menu = view.makeRowMenu(
            for: snapshot, canRevert: true, canRename: true, canSetNotes: true, canDelete: true)
        let delete = menu.items.first { $0.title == "Delete\u{2026}" }
        delete.map { _ = $0.target?.perform($0.action, with: $0) }

        #expect(deleted == [snapshot])
    }
}
