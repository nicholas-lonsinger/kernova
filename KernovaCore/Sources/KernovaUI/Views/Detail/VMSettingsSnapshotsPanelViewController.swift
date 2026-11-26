import AppKit
import KernovaAppKitShared
import KernovaCore
import KernovaLogging

/// The Snapshots category: the snapshot list, its inline edits, and the on-disk
/// size read behind them.
///
/// A single-section category, so the section draws no header of its own and
/// hands its info affordance and size readout to the panel header.
@MainActor
final class VMSettingsSnapshotsPanelViewController: NSViewController, VMSettingsPanel {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "VMSettingsSnapshotsPanel")

    let context: VMSettingsPanelContext
    let category = VMSettingsCategory.snapshots
    private(set) var chrome = VMSettingsPanelChrome()

    /// The Snapshots section, rebuilt per instance.
    private var snapshotSection: SnapshotSectionView?
    private let infoPresenter = PopoverPresenter()

    private let panelStack = NSStackView()

    init(context: VMSettingsPanelContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("VMSettingsSnapshotsPanelViewController does not support NSCoder")
    }

    override func loadView() {
        panelStack.orientation = .vertical
        panelStack.alignment = .leading
        panelStack.spacing = Spacing.section
        panelStack.translatesAutoresizingMaskIntoConstraints = false
        view = panelStack
    }

    func rebuild() {
        loadViewIfNeeded()
        panelStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let section = buildSnapshotsSection()
        addGroupedFormFullWidth(section, to: panelStack)
    }

    func prepareForDisappearance() {
        if infoPresenter.isShown { infoPresenter.close() }
        // Drop any in-flight inline edit so the flag can't pin the list in a
        // suppressed (never-rebuilds) state across an appear/disappear cycle.
        snapshotSection?.clearActiveEdit()
    }

    // MARK: - Build

    /// The Snapshots panel's only section, so its header moves to the panel
    /// header — which hosts the info affordance and the size readout the
    /// section would otherwise draw itself.
    private func buildSnapshotsSection() -> NSView {
        let section = SnapshotSectionView(showsHeader: false)
        section.onTakeSnapshot = { [weak self] in
            guard let self else { return }
            viewModel.requestTakeSnapshot(instance)
        }
        section.onRevert = { [weak self] snapshot in
            guard let self else { return }
            viewModel.requestRevert(instance, to: snapshot)
        }
        section.onDelete = { [weak self] snapshot in
            guard let self else { return }
            viewModel.requestDeleteSnapshot(instance, snapshot: snapshot)
        }
        section.onRename = { [weak self] snapshot, newName in
            self?.commitRename(of: snapshot, to: newName)
        }
        section.onSetNotes = { [weak self] snapshot, notes in
            self?.commitNotes(notes, on: snapshot)
        }
        section.onRequestInfo = { [weak self] snapshot, anchor in
            self?.presentSnapshotInfoPopover(snapshot, from: anchor)
        }
        snapshotSection = section
        chrome = VMSettingsPanelChrome(
            leading: [section.infoButton], trailing: [section.countReadout])
        return section
    }

    // MARK: - Refresh

    func refresh() {
        guard let snapshotSection else { return }
        let capabilities = viewModel.capabilities
        let manifest = instance.snapshotManifest
        snapshotSection.update(
            manifest: manifest,
            canTakeSnapshot: capabilities.isAvailable(.takeSnapshot, on: instance),
            canRevert: capabilities.isAvailable(.revertToSnapshot, on: instance),
            canRename: capabilities.isAvailable(.renameSnapshot, on: instance),
            canSetNotes: capabilities.isAvailable(.setSnapshotNotes, on: instance),
            canDelete: capabilities.isAvailable(.deleteSnapshot, on: instance),
            baselineID: instance.ephemeralBaselineSnapshot?.id)
        // The sizes walk every file each snapshot holds, so the pane reads them
        // off the main actor.
        snapshotSection.applySizes(resolved.snapshotSizes)
    }

    /// Get Info popover for one snapshot, with its size read off the main
    /// actor first.
    private func presentSnapshotInfoPopover(_ snapshot: VMSnapshot, from anchor: NSView) {
        let instanceID = instance.id
        Task { [weak self] in
            guard let self else { return }
            let sizes = await self.viewModel.snapshotSizes(for: self.instance)
            // The pane is reused across route and VM changes, so a read that
            // lands after the user moved on must not name the new VM's sizes.
            guard !self.context.isDismissed, self.instance.id == instanceID else { return }
            let content = SnapshotInfoPopoverContentViewController(
                snapshot: snapshot,
                size: sizes[snapshot.id],
                savedStateVersion: self.instance.savedStateVersion(ofSnapshot: snapshot.id),
                canEditNotes: self.viewModel.capabilities.isAvailable(
                    .setSnapshotNotes, on: self.instance),
                onCommitNotes: { [weak self] notes in
                    guard let self else { return }
                    // Looked up fresh: the popover outlives edits landing from
                    // elsewhere, and the copy it was built with can be stale.
                    guard let current = self.instance.snapshotManifest.snapshot(id: snapshot.id)
                    else { return }
                    self.viewModel.setSnapshotNotes(current, notes: notes, on: self.instance)
                    self.refresh()
                })
            content.onRequestClose = { [weak self] in self?.infoPresenter.close() }
            self.infoPresenter.show(content: content, from: anchor, preferredEdge: .minY)
        }
    }
}

// MARK: - Inline edits

extension VMSettingsSnapshotsPanelViewController {
    /// Commits an inline rename, deferred to the next runloop turn so the field
    /// editor's end-editing callback fully unwinds before the rebuild tears down
    /// and recreates the editing row. A name the snapshot is refused opens the
    /// edit again, holding that name, once the refusal is dismissed — as a
    /// virtual machine's rename does.
    private func commitRename(of snapshot: VMSnapshot, to newName: String) {
        Task { [weak self] in
            guard let self else { return }
            let instance = self.instance
            showingRefusal(
                "Couldn\u{2019}t Rename the Snapshot", in: self.view.window, logger: Self.logger,
                retry: { [weak self] in
                    guard let self, self.instance === instance else { return }
                    self.snapshotSection?.beginRename(snapshot.id, holding: newName)
                }
            ) { try self.viewModel.renameSnapshot(snapshot, newName: newName, on: instance) }
            // A no-op rename (empty / unchanged) fires no observation, so force a
            // refresh to pick up anything suppressed during the edit.
            self.refresh()
        }
    }

    /// Commits an inline note edit, deferred for the same reason a rename is.
    private func commitNotes(_ notes: String, on snapshot: VMSnapshot) {
        Task { [weak self] in
            guard let self else { return }
            self.viewModel.setSnapshotNotes(snapshot, notes: notes, on: self.instance)
            // A no-op edit (unchanged) fires no observation, so force a refresh
            // to pick up anything suppressed during the edit.
            self.refresh()
        }
    }
}
