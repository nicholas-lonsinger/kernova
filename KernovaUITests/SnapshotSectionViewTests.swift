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

    // MARK: - Empty state

    @Test("A VM with no snapshots shows the empty row and no readout")
    func emptyState() {
        let view = SnapshotSectionView()

        render(
            view, manifest: VMSnapshotManifest(), canTakeSnapshot: true, canRevert: false)

        #expect(findLabel(withText: "No snapshots", in: view) != nil)
        #expect(view.countReadout.isHidden)
    }

    // MARK: - Rows

    @Test("Rows read their sizes once they land, and the header stays a count")
    func sizesReachTheRowsNotTheHeader() {
        let view = SnapshotSectionView()
        let first = makeSnapshot("One")
        let second = makeSnapshot("Two", offsetSeconds: 60)
        render(
            view, manifest: VMSnapshotManifest(snapshots: [first, second]),
            canTakeSnapshot: true, canRevert: true)
        #expect(findLabel(withText: "2 snapshots", in: view) != nil)

        view.applySizes([
            first.id: SnapshotSize(bytes: 1_000_000_000, privateBytes: nil),
            second.id: SnapshotSize(bytes: 3_000_000_000, privateBytes: nil),
        ])

        #expect(findLabel(withText: "2 snapshots", in: view) != nil)
        #expect(findLabel(containing: "3 GB", in: view) != nil)
        #expect(findLabel(containing: "4 GB", in: view) == nil)
        #expect(!view.countReadout.isHidden)
        #expect(view.sizeInfoButton.paragraphs == SnapshotSectionView.sizeExplanation)
    }

    @Test("On a cloning volume a row's size carries its private bytes in parentheses")
    func cloningVolumeRowShowsPrivateBytes() {
        let view = SnapshotSectionView()
        let snapshot = makeSnapshot("Cloned")
        render(
            view, manifest: VMSnapshotManifest(snapshots: [snapshot]), canTakeSnapshot: true,
            canRevert: true)

        view.applySizes([
            snapshot.id: SnapshotSize(bytes: 72_400_000_000, privateBytes: 8_400_000_000)
        ])

        #expect(
            view.subtitleText(for: snapshot)
                == "\(SnapshotDateFormat.string(from: snapshot.createdAt)) \u{00B7} "
                + "\(SnapshotKindCopy.stateLabel(snapshot.kind)) \u{00B7} "
                + "\(DataFormatters.formatBytes(72_400_000_000)) "
                + "(\(DataFormatters.formatBytes(8_400_000_000)) private)")
    }

    @Test("A single snapshot reads in the singular")
    func singleSnapshotReadsSingular() {
        let view = SnapshotSectionView()
        let only = makeSnapshot("Only")

        render(
            view, manifest: VMSnapshotManifest(snapshots: [only]), canTakeSnapshot: true,
            canRevert: true)
        view.applySizes([only.id: SnapshotSize(bytes: 2_000_000_000, privateBytes: nil)])

        #expect(findLabel(withText: "1 snapshot", in: view) != nil)
    }

    @Test("An in-place update moves the current marker without a rebuild")
    func currentMarkerFollowsAnInPlaceUpdate() {
        let view = SnapshotSectionView()
        let first = makeSnapshot("One")
        let second = makeSnapshot("Two", offsetSeconds: 60)
        let manifest = VMSnapshotManifest(snapshots: [first, second], currentID: second.id)
        render(
            view, manifest: manifest, canTakeSnapshot: true, canRevert: true)
        #expect(
            allSubviews(NSTextField.self, in: view) {
                $0.stringValue == "Current" && isVisible($0, within: view)
            }.count == 1)

        var moved = manifest
        moved.currentID = first.id
        render(
            view, manifest: moved, canTakeSnapshot: true, canRevert: true)

        let markers = allSubviews(NSTextField.self, in: view) {
            $0.stringValue == "Current" && isVisible($0, within: view)
        }
        #expect(markers.count == 1)
    }

    // MARK: - Ephemeral baseline

    @Test("The baseline row reads both roles when it is also the current snapshot")
    func baselineAndCurrentReadAsOneMarker() {
        let view = SnapshotSectionView()
        let baseline = makeSnapshot("Clean install")
        let later = makeSnapshot("Mid-session", offsetSeconds: 60)

        render(
            view, manifest: VMSnapshotManifest(snapshots: [baseline, later], currentID: baseline.id),
            canTakeSnapshot: true, canRevert: true, baseline: baseline)

        let markers = allSubviews(NSTextField.self, in: view) {
            $0.stringValue == "Baseline \u{00B7} Current" && isVisible($0, within: view)
        }
        #expect(markers.count == 1)
        #expect(
            allSubviews(NSTextField.self, in: view) {
                $0.stringValue == "Current" && isVisible($0, within: view)
            }.isEmpty)
    }

    @Test("A baseline that isn't the current snapshot reads as Baseline alone")
    func baselineAloneReadsAsBaseline() {
        let view = SnapshotSectionView()
        let baseline = makeSnapshot("Clean install")
        let later = makeSnapshot("Mid-session", offsetSeconds: 60)

        render(
            view, manifest: VMSnapshotManifest(snapshots: [baseline, later], currentID: later.id),
            canTakeSnapshot: true, canRevert: true, baseline: baseline)

        #expect(
            allSubviews(NSTextField.self, in: view) {
                $0.stringValue == "Baseline" && isVisible($0, within: view)
            }.count == 1)
        #expect(
            allSubviews(NSTextField.self, in: view) {
                $0.stringValue == "Current" && isVisible($0, within: view)
            }.count == 1)
    }

    // MARK: - Enablement

    @Test("Revert is disabled while the VM can't be taken there")
    func revertDisabledWhenNotRevertible() {
        let view = SnapshotSectionView()

        render(
            view, manifest: VMSnapshotManifest(snapshots: [makeSnapshot("One")]),
            canTakeSnapshot: false, canRevert: false)

        #expect(revertButtons(in: view).allSatisfy { !$0.isEnabled })
    }

    @Test("The Take Snapshot link follows whether a snapshot can be taken")
    func takeLinkFollowsCapability() {
        let view = SnapshotSectionView()

        render(
            view, manifest: VMSnapshotManifest(), canTakeSnapshot: false, canRevert: false)
        #expect(findButton(titled: "Take Snapshot\u{2026}", in: view)?.isEnabled == false)

        render(
            view, manifest: VMSnapshotManifest(), canTakeSnapshot: true, canRevert: false)
        #expect(findButton(titled: "Take Snapshot\u{2026}", in: view)?.isEnabled == true)
    }

    // MARK: - Actions

    @Test("The footer link asks for a new snapshot")
    func takeLinkAsksForASnapshot() {
        let view = SnapshotSectionView()
        var takeRequests = 0
        view.onTakeSnapshot = { takeRequests += 1 }
        render(
            view, manifest: VMSnapshotManifest(), canTakeSnapshot: true, canRevert: false)

        let button = findButton(titled: "Take Snapshot\u{2026}", in: view)
        button.map { _ = $0.target?.perform($0.action, with: $0) }

        #expect(takeRequests == 1)
    }

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

    @Test("The row menu's Get Info names its snapshot")
    func rowMenuGetInfoNamesItsSnapshot() {
        let view = SnapshotSectionView()
        var infoRequests: [VMSnapshot] = []
        view.onRequestInfo = { snapshot, _ in infoRequests.append(snapshot) }
        let snapshot = makeSnapshot("One")
        render(
            view, manifest: VMSnapshotManifest(snapshots: [snapshot]), canTakeSnapshot: true,
            canRevert: true)

        let menu = view.makeRowMenu(
            for: snapshot, canRevert: true, canRename: true, canSetNotes: true, canDelete: true)
        let info = menu.items.first { $0.title == "Get Info" }
        info.map { _ = $0.target?.perform($0.action, with: $0) }

        #expect(infoRequests == [snapshot])
    }

    // MARK: - Rename

    @Test("A rename in flight suppresses the structural rebuild")
    func renameSuppressesRebuild() {
        let view = SnapshotSectionView()
        let first = makeSnapshot("One")
        render(
            view, manifest: VMSnapshotManifest(snapshots: [first]), canTakeSnapshot: true,
            canRevert: true)
        showInTestWindow(view, size: NSSize(width: 480, height: 200))

        view.beginRename(first.id)
        #expect(view.activeEdit == first.id)

        // A snapshot arriving mid-edit must not tear the editing field down.
        render(
            view,
            manifest: VMSnapshotManifest(snapshots: [
                first, makeSnapshot("Two", offsetSeconds: 60),
            ]),
            canTakeSnapshot: true, canRevert: true)
        #expect(findLabel(withText: "Two", in: view) == nil)

        view.clearActiveEdit()
        render(
            view,
            manifest: VMSnapshotManifest(snapshots: [
                first, makeSnapshot("Two", offsetSeconds: 60),
            ]),
            canTakeSnapshot: true, canRevert: true)
        #expect(findLabel(withText: "Two", in: view) != nil)
    }

    @Test("Cancelling a rename renders what arrived while it was open")
    func cancelRenameRendersTheStoredManifest() async {
        let view = SnapshotSectionView()
        let first = makeSnapshot("One")
        render(
            view, manifest: VMSnapshotManifest(snapshots: [first]), canTakeSnapshot: true,
            canRevert: true)
        showInTestWindow(view, size: NSSize(width: 480, height: 200))

        view.beginRename(first.id)
        render(
            view,
            manifest: VMSnapshotManifest(snapshots: [
                first, makeSnapshot("Two", offsetSeconds: 60),
            ]),
            canTakeSnapshot: true, canRevert: true)
        #expect(findLabel(withText: "Two", in: view) == nil)

        // Escape: the field editor's cancel command, which the label turns into
        // `onRenameCancelled`.
        escape(nameLabel(named: "One", in: view))
        await drainMainQueue()

        #expect(view.activeEdit == nil)
        #expect(findLabel(withText: "Two", in: view) != nil)
    }

    // MARK: - Notes

    @Test("Cancelling a note edit ends it")
    func cancelNotesEditEndsIt() async {
        let view = SnapshotSectionView()
        let first = makeSnapshot("One", notes: "before")
        render(
            view, manifest: VMSnapshotManifest(snapshots: [first]), canTakeSnapshot: true,
            canRevert: true)
        showInTestWindow(view, size: NSSize(width: 480, height: 200))

        view.beginNotesEditing(first.id)
        escape(nameLabel(named: "before", in: view))
        await drainMainQueue()

        #expect(view.activeEdit == nil)
    }

    @Test("The row menu offers Edit Notes regardless of whether the list can be deleted from")
    func rowMenuOffersEditNotes() {
        let view = SnapshotSectionView()
        let snapshot = makeSnapshot("One")
        render(
            view, manifest: VMSnapshotManifest(snapshots: [snapshot]), canTakeSnapshot: true,
            canRevert: true, canDelete: false)

        #expect(
            view.makeRowMenu(
                for: snapshot, canRevert: true, canRename: true, canSetNotes: true, canDelete: false
            )
            .items.first { $0.title == "Edit Notes" }?.isEnabled == true)
        #expect(
            view.makeRowMenu(
                for: snapshot, canRevert: false, canRename: true, canSetNotes: true, canDelete: false
            )
            .items.first { $0.title == "Edit Notes" }?.isEnabled == true)
    }

    @Test("Edit Notes on a row with no note starts an edit that commits what is typed")
    func editNotesCommitsTypedText() async {
        let view = SnapshotSectionView()
        var noted: [(snapshot: VMSnapshot, notes: String)] = []
        view.onSetNotes = { noted.append(($0, $1)) }
        let first = makeSnapshot("One")
        render(
            view, manifest: VMSnapshotManifest(snapshots: [first]), canTakeSnapshot: true,
            canRevert: true)
        showInTestWindow(view, size: NSSize(width: 480, height: 200))

        view.beginNotesEditing(first.id)
        let field = allSubviews(InlineEditableLabel.self, in: view) { $0.isEditable }.first
        field?.stringValue = "tools configured"
        field.map { $0.controlTextDidEndEditing(Notification(name: .init("test"), object: $0)) }
        await drainMainQueue()

        #expect(noted.count == 1)
        #expect(noted.first?.notes == "tools configured")
        #expect(view.activeEdit == nil)
    }

    /// The inline label showing `text`, which is how a test reaches one part of
    /// a row's title line.
    private func nameLabel(named text: String, in view: NSView) -> InlineEditableLabel? {
        allSubviews(InlineEditableLabel.self, in: view) { $0.stringValue == text }.first
    }

    /// Sends the field editor's cancel command, the way Escape reaches a label.
    private func escape(_ label: InlineEditableLabel?) {
        _ = label?.control(
            NSControl(), textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    }
}
