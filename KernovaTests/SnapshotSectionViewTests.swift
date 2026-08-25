import AppKit
import Testing

@testable import Kernova

@Suite("SnapshotSectionView Tests", .admissionGated)
@MainActor
struct SnapshotSectionViewTests {
    /// Records what the section asks its host to do.
    private final class Recorder: SnapshotSectionViewDelegate {
        var takeRequests = 0
        var reverted: [VMSnapshot] = []
        var deleted: [VMSnapshot] = []
        var renamed: [(snapshot: VMSnapshot, name: String)] = []
        var infoRequests: [VMSnapshot] = []

        func snapshotSectionRequestedTakeSnapshot(_ view: SnapshotSectionView) {
            takeRequests += 1
        }
        func snapshotSection(_ view: SnapshotSectionView, requestedRevertTo snapshot: VMSnapshot) {
            reverted.append(snapshot)
        }
        func snapshotSection(_ view: SnapshotSectionView, requestedDeleteOf snapshot: VMSnapshot) {
            deleted.append(snapshot)
        }
        func snapshotSection(
            _ view: SnapshotSectionView, renamed snapshot: VMSnapshot, to newName: String
        ) {
            renamed.append((snapshot, newName))
        }
        func snapshotSection(
            _ view: SnapshotSectionView, requestedInfoFor snapshot: VMSnapshot, from anchor: NSView
        ) {
            infoRequests.append(snapshot)
        }
    }

    private func makeSnapshot(_ name: String, offsetSeconds: TimeInterval = 0) -> VMSnapshot {
        VMSnapshot(
            name: name, createdAt: Date(timeIntervalSince1970: 1_700_000_000 + offsetSeconds))
    }

    /// The recorder is held weakly by the view, so the caller must keep the
    /// returned pair alive for the length of the test.
    private func makeSection() -> (SnapshotSectionView, Recorder) {
        let recorder = Recorder()
        let view = SnapshotSectionView()
        view.delegate = recorder
        return (view, recorder)
    }

    private func revertButtons(in view: NSView) -> [NSButton] {
        allSubviews(NSButton.self, in: view) { $0.title == "Revert" }
    }

    // MARK: - Empty state

    @Test("A VM with no snapshots shows the empty row and no readout")
    func emptyState() {
        let (view, _) = makeSection()

        view.update(manifest: VMSnapshotManifest(), canTakeSnapshot: true, canRevert: false, canModify: true)

        #expect(findLabel(withText: "No snapshots", in: view) != nil)
        let readout = firstSubview(NSTextField.self, in: view) {
            $0.stringValue.contains("snapshot") && $0.stringValue.contains("\u{00B7}")
        }
        #expect(readout == nil)
    }

    // MARK: - Rows

    @Test("Rows render newest first")
    func rowsAreNewestFirst() {
        let (view, _) = makeSection()
        let older = makeSnapshot("Older")
        let newer = makeSnapshot("Newer", offsetSeconds: 60)

        view.update(
            manifest: VMSnapshotManifest(snapshots: [older, newer]),
            canTakeSnapshot: true, canRevert: true, canModify: true)

        let titles = collectLabels(in: view).map(\.stringValue)
        let newerIndex = titles.firstIndex(of: "Newer")
        let olderIndex = titles.firstIndex(of: "Older")
        #expect(newerIndex != nil)
        #expect(olderIndex != nil)
        #expect((newerIndex ?? 0) < (olderIndex ?? 0))
    }

    @Test("The header counts the snapshots before their sizes are known")
    func headerCountsBeforeSizes() {
        let (view, _) = makeSection()

        view.update(
            manifest: VMSnapshotManifest(snapshots: [
                makeSnapshot("One"), makeSnapshot("Two", offsetSeconds: 60),
            ]),
            canTakeSnapshot: true, canRevert: true, canModify: true)

        #expect(findLabel(withText: "2 snapshots", in: view) != nil)
    }

    @Test("The header and rows read on-disk sizes once they land")
    func sizesReachTheHeaderAndRows() {
        let (view, _) = makeSection()
        let first = makeSnapshot("One")
        let second = makeSnapshot("Two", offsetSeconds: 60)
        view.update(
            manifest: VMSnapshotManifest(snapshots: [first, second]),
            canTakeSnapshot: true, canRevert: true, canModify: true)

        view.applySizes([first.id: 1_000_000_000, second.id: 3_000_000_000])

        #expect(findLabel(containing: "2 snapshots \u{00B7} 4 GB on disk", in: view) != nil)
        #expect(findLabel(containing: "3 GB on disk", in: view) != nil)
    }

    @Test("A single snapshot reads in the singular")
    func singleSnapshotReadsSingular() {
        let (view, _) = makeSection()
        let only = makeSnapshot("Only")

        view.update(
            manifest: VMSnapshotManifest(snapshots: [only]), canTakeSnapshot: true,
            canRevert: true, canModify: true)
        view.applySizes([only.id: 2_000_000_000])

        #expect(findLabel(containing: "1 snapshot \u{00B7}", in: view) != nil)
    }

    @Test("Only the current snapshot's row shows the marker")
    func currentMarkerIsOnOneRow() {
        let (view, _) = makeSection()
        let first = makeSnapshot("One")
        let second = makeSnapshot("Two", offsetSeconds: 60)

        view.update(
            manifest: VMSnapshotManifest(snapshots: [first, second], currentID: second.id),
            canTakeSnapshot: true, canRevert: true, canModify: true)

        let visible = allSubviews(NSTextField.self, in: view) {
            $0.stringValue == "Current" && isVisible($0, within: view)
        }
        #expect(visible.count == 1)
    }

    @Test("An in-place update moves the current marker without a rebuild")
    func currentMarkerFollowsAnInPlaceUpdate() {
        let (view, _) = makeSection()
        let first = makeSnapshot("One")
        let second = makeSnapshot("Two", offsetSeconds: 60)
        let manifest = VMSnapshotManifest(snapshots: [first, second], currentID: second.id)
        view.update(manifest: manifest, canTakeSnapshot: true, canRevert: true, canModify: true)

        var moved = manifest
        moved.currentID = first.id
        view.update(manifest: moved, canTakeSnapshot: true, canRevert: true, canModify: true)

        let markers = allSubviews(NSTextField.self, in: view) {
            $0.stringValue == "Current" && isVisible($0, within: view)
        }
        #expect(markers.count == 1)
    }

    // MARK: - Enablement

    @Test("Revert is disabled while the VM can't be taken there")
    func revertDisabledWhenNotRevertible() {
        let (view, _) = makeSection()

        view.update(
            manifest: VMSnapshotManifest(snapshots: [makeSnapshot("One")]),
            canTakeSnapshot: false, canRevert: false, canModify: true)

        #expect(revertButtons(in: view).allSatisfy { !$0.isEnabled })
    }

    @Test("The Take Snapshot link follows whether a snapshot can be taken")
    func takeLinkFollowsCapability() {
        let (view, _) = makeSection()

        view.update(manifest: VMSnapshotManifest(), canTakeSnapshot: false, canRevert: false, canModify: true)
        #expect(findButton(titled: "Take Snapshot\u{2026}", in: view)?.isEnabled == false)

        view.update(manifest: VMSnapshotManifest(), canTakeSnapshot: true, canRevert: false, canModify: true)
        #expect(findButton(titled: "Take Snapshot\u{2026}", in: view)?.isEnabled == true)
    }

    // MARK: - Actions

    @Test("The footer link asks for a new snapshot")
    func takeLinkAsksForASnapshot() {
        let (view, recorder) = makeSection()
        view.update(manifest: VMSnapshotManifest(), canTakeSnapshot: true, canRevert: false, canModify: true)

        let button = findButton(titled: "Take Snapshot\u{2026}", in: view)
        button.map { _ = $0.target?.perform($0.action, with: $0) }

        #expect(recorder.takeRequests == 1)
    }

    @Test("A row's Revert button names that row's snapshot")
    func revertButtonNamesItsRow() {
        let (view, recorder) = makeSection()
        let older = makeSnapshot("Older")
        let newer = makeSnapshot("Newer", offsetSeconds: 60)
        view.update(
            manifest: VMSnapshotManifest(snapshots: [older, newer]),
            canTakeSnapshot: true, canRevert: true, canModify: true)

        // Rows render newest first, so the second button belongs to "Older".
        let buttons = revertButtons(in: view)
        #expect(buttons.count == 2)
        buttons.last.map { _ = $0.target?.perform($0.action, with: $0) }

        #expect(recorder.reverted == [older])
    }

    // MARK: - Row menu

    @Test("The row menu offers rename, info, revert, and delete")
    func rowMenuOffersEveryAction() {
        let (view, _) = makeSection()
        let snapshot = makeSnapshot("One")
        view.update(
            manifest: VMSnapshotManifest(snapshots: [snapshot]), canTakeSnapshot: true,
            canRevert: true, canModify: true)

        let menu = view.makeRowMenu(for: snapshot, canRevert: true, canModify: true)

        #expect(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title) == [
                "Rename", "Get Info", "Revert", "Delete\u{2026}",
            ])
    }

    @Test("The row menu's Revert is disabled when the VM can't be reverted")
    func rowMenuRevertFollowsCapability() {
        let (view, _) = makeSection()
        let snapshot = makeSnapshot("One")
        view.update(
            manifest: VMSnapshotManifest(snapshots: [snapshot]), canTakeSnapshot: false,
            canRevert: false, canModify: true)

        let menu = view.makeRowMenu(for: snapshot, canRevert: false, canModify: true)

        #expect(menu.items.first { $0.title == "Revert" }?.isEnabled == false)
    }

    @Test("The row menu's Delete names its snapshot")
    func rowMenuDeleteNamesItsSnapshot() {
        let (view, recorder) = makeSection()
        let snapshot = makeSnapshot("One")
        view.update(
            manifest: VMSnapshotManifest(snapshots: [snapshot]), canTakeSnapshot: true,
            canRevert: true, canModify: true)

        let menu = view.makeRowMenu(for: snapshot, canRevert: true, canModify: true)
        let delete = menu.items.first { $0.title == "Delete\u{2026}" }
        delete.map { _ = $0.target?.perform($0.action, with: $0) }

        #expect(recorder.deleted == [snapshot])
    }

    @Test("The row menu's Get Info names its snapshot")
    func rowMenuGetInfoNamesItsSnapshot() {
        let (view, recorder) = makeSection()
        let snapshot = makeSnapshot("One")
        view.update(
            manifest: VMSnapshotManifest(snapshots: [snapshot]), canTakeSnapshot: true,
            canRevert: true, canModify: true)

        let menu = view.makeRowMenu(for: snapshot, canRevert: true, canModify: true)
        let info = menu.items.first { $0.title == "Get Info" }
        info.map { _ = $0.target?.perform($0.action, with: $0) }

        #expect(recorder.infoRequests == [snapshot])
    }

    // MARK: - Rename

    @Test("A rename in flight suppresses the structural rebuild")
    func renameSuppressesRebuild() {
        let (view, _) = makeSection()
        let first = makeSnapshot("One")
        view.update(
            manifest: VMSnapshotManifest(snapshots: [first]), canTakeSnapshot: true,
            canRevert: true, canModify: true)
        let window = showInTestWindow(view, size: NSSize(width: 480, height: 200))
        defer { window.close() }

        view.beginRename(first.id)
        #expect(view.activeRename == first.id)

        // A snapshot arriving mid-edit must not tear the editing field down.
        view.update(
            manifest: VMSnapshotManifest(snapshots: [
                first, makeSnapshot("Two", offsetSeconds: 60),
            ]),
            canTakeSnapshot: true, canRevert: true, canModify: true)
        #expect(findLabel(withText: "Two", in: view) == nil)

        view.clearActiveRename()
        view.update(
            manifest: VMSnapshotManifest(snapshots: [
                first, makeSnapshot("Two", offsetSeconds: 60),
            ]),
            canTakeSnapshot: true, canRevert: true, canModify: true)
        #expect(findLabel(withText: "Two", in: view) != nil)
    }

    @Test("Cancelling a rename renders what arrived while it was open")
    func cancelRenameRendersTheStoredManifest() async {
        let (view, _) = makeSection()
        let first = makeSnapshot("One")
        view.update(
            manifest: VMSnapshotManifest(snapshots: [first]), canTakeSnapshot: true,
            canRevert: true, canModify: true)
        let window = showInTestWindow(view, size: NSSize(width: 480, height: 200))
        defer { window.close() }

        view.beginRename(first.id)
        view.update(
            manifest: VMSnapshotManifest(snapshots: [
                first, makeSnapshot("Two", offsetSeconds: 60),
            ]),
            canTakeSnapshot: true, canRevert: true, canModify: true)
        #expect(findLabel(withText: "Two", in: view) == nil)

        // Escape: the field editor's cancel command, which the title view turns
        // into `onRenameCancelled`.
        let title = allSubviews(InlineRenameTitleView.self, in: view) { $0.itemID == first.id }
            .first
        _ = title?.control(
            NSControl(), textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        await Task.yield()

        #expect(view.activeRename == nil)
        #expect(findLabel(withText: "Two", in: view) != nil)
    }

    // MARK: - Editing gate

    @Test("The row menu's Rename and Delete follow whether the list can be edited")
    func rowMenuEditingFollowsTheGate() {
        let (view, _) = makeSection()
        let snapshot = makeSnapshot("One")
        view.update(
            manifest: VMSnapshotManifest(snapshots: [snapshot]), canTakeSnapshot: false,
            canRevert: false, canModify: false)

        let menu = view.makeRowMenu(for: snapshot, canRevert: false, canModify: false)

        #expect(menu.items.first { $0.title == "Rename" }?.isEnabled == false)
        #expect(menu.items.first { $0.title == "Delete\u{2026}" }?.isEnabled == false)
        // Reading a snapshot's details changes nothing, so it stays available.
        #expect(menu.items.first { $0.title == "Get Info" }?.isEnabled == true)
    }

    // MARK: - Link appearance

    @Test("A disabled Take Snapshot link is visibly dimmed, not link-tinted")
    func disabledLinkIsDimmed() {
        let (view, _) = makeSection()

        view.update(
            manifest: VMSnapshotManifest(), canTakeSnapshot: true, canRevert: false,
            canModify: true)
        #expect(
            findButton(titled: "Take Snapshot\u{2026}", in: view)?.contentTintColor == .linkColor)

        view.update(
            manifest: VMSnapshotManifest(), canTakeSnapshot: false, canRevert: false,
            canModify: true)
        #expect(
            findButton(titled: "Take Snapshot\u{2026}", in: view)?.contentTintColor
                == .disabledControlTextColor)
    }

    @Test("A disabled row Revert link dims the same way")
    func disabledRevertLinkIsDimmed() {
        let (view, _) = makeSection()

        view.update(
            manifest: VMSnapshotManifest(snapshots: [makeSnapshot("One")]), canTakeSnapshot: false,
            canRevert: false, canModify: true)

        #expect(revertButtons(in: view).allSatisfy { $0.contentTintColor == .disabledControlTextColor })
    }
}
