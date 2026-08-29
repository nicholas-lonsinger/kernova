import AppKit

/// The Snapshots category: the snapshot list, its inline edits, and the on-disk
/// size read behind them.
///
/// A single-section category, so the section draws no header of its own and
/// hands its info affordance and size readout to the panel header.
@MainActor
final class VMSettingsSnapshotsPanelViewController: NSViewController, VMSettingsPanel {
    let context: VMSettingsPanelContext
    let category = VMSettingsCategory.snapshots
    private(set) var chrome = VMSettingsPanelChrome()

    /// The Snapshots section, rebuilt per instance.
    private var snapshotSection: SnapshotSectionView?
    /// The snapshot ids the size read was last issued for, so it re-runs when
    /// the set changes rather than on every `refresh()` pass.
    private var snapshotSizeIDs: [UUID]?
    private var snapshotSizeTask: Task<Void, Never>?
    /// What every snapshot occupies together, from the last size read.
    private var snapshotTotalBytes: UInt64?
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
        panelStack.addArrangedSubview(section)
        section.widthAnchor.constraint(equalTo: panelStack.widthAnchor).isActive = true
    }

    func prepareForDisappearance() {
        if infoPresenter.isShown { infoPresenter.close() }
        // Drop any in-flight inline edit so the flag can't pin the list in a
        // suppressed (never-rebuilds) state across an appear/disappear cycle.
        snapshotSection?.clearActiveEdit()
        snapshotSizeTask?.cancel()
        snapshotSizeTask = nil
        // Re-read on the next appear: the sizes may have moved while away.
        snapshotSizeIDs = nil
    }

    // MARK: - Build

    /// The Snapshots panel's only section, so its header moves to the panel
    /// header — which hosts the info affordance and the size readout the
    /// section would otherwise draw itself.
    private func buildSnapshotsSection() -> NSView {
        let section = SnapshotSectionView(showsHeader: false)
        section.delegate = self
        snapshotSection = section
        chrome = VMSettingsPanelChrome(
            leading: [section.infoButton], trailing: [section.sizeReadout])
        // A fresh section has no sizes yet, so the read must be re-issued.
        snapshotSizeIDs = nil
        return section
    }

    // MARK: - Refresh

    /// The card states the capture command and the snapshots' footprint, both of
    /// which only this panel resolves.
    func contribute(to resolved: inout VMOverviewResolved) {
        resolved.canTakeSnapshot = viewModel.canTakeSnapshot(instance)
        resolved.snapshotTotalBytes = snapshotTotalBytes
    }

    func refresh() {
        guard let snapshotSection else { return }
        snapshotSection.update(
            manifest: instance.snapshotManifest,
            canTakeSnapshot: viewModel.canTakeSnapshot(instance),
            canRevert: viewModel.canRevertToSnapshot(instance),
            canDelete: viewModel.canDeleteSnapshots(instance),
            baselineID: instance.ephemeralBaselineSnapshot?.id)

        // The sizes are a directory walk over gigabyte-scale copies, so they are
        // read off the main actor and only when the set of snapshots changed.
        let ids = instance.snapshotManifest.ordered.map(\.id)
        guard ids != snapshotSizeIDs else { return }
        snapshotSizeIDs = ids
        snapshotSizeTask?.cancel()
        guard !ids.isEmpty else {
            snapshotTotalBytes = nil
            snapshotSection.applySizes([:])
            return
        }
        let instanceID = instance.id
        snapshotSizeTask = Task { [weak self] in
            guard let self else { return }
            let sizes = await self.viewModel.snapshotOnDiskBytes(for: self.instance)
            // The pane is reused across route and VM changes, so a read that
            // lands after the user moved on must not paint the new VM's rows.
            guard !Task.isCancelled, !self.context.isDismissed, self.instance.id == instanceID
            else {
                return
            }
            self.snapshotSection?.applySizes(sizes)
            self.snapshotTotalBytes = sizes.values.reduce(0, +)
            // The overview states the same total, and this read is issued only
            // when the snapshot set changes — so the pass that paints it has to
            // be asked for rather than waited on.
            self.requestFullRefresh()
        }
    }

    /// Get Info popover for one snapshot, with its on-disk footprint read off
    /// the main actor first.
    private func presentSnapshotInfoPopover(_ snapshot: VMSnapshot, from anchor: NSView) {
        let instanceID = instance.id
        Task { [weak self] in
            guard let self else { return }
            let sizes = await self.viewModel.snapshotOnDiskBytes(for: self.instance)
            // The pane is reused across route and VM changes, so a read that
            // lands after the user moved on must not name the new VM's sizes.
            guard !self.context.isDismissed, self.instance.id == instanceID else { return }
            let content = SnapshotInfoPopoverContentViewController(
                snapshot: snapshot,
                onDiskText: sizes[snapshot.id].map { DataFormatters.formatBytes($0) } ?? "\u{2014}",
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

// MARK: - SnapshotSectionViewDelegate

extension VMSettingsSnapshotsPanelViewController: SnapshotSectionViewDelegate {
    func snapshotSectionRequestedTakeSnapshot(_ view: SnapshotSectionView) {
        viewModel.requestTakeSnapshot(instance)
    }

    func snapshotSection(_ view: SnapshotSectionView, requestedRevertTo snapshot: VMSnapshot) {
        viewModel.confirmRevert(instance, to: snapshot)
    }

    func snapshotSection(_ view: SnapshotSectionView, requestedDeleteOf snapshot: VMSnapshot) {
        viewModel.confirmDeleteSnapshot(instance, snapshot: snapshot)
    }

    /// Commits an inline rename, deferred to the next runloop turn so the field
    /// editor's end-editing callback fully unwinds before the rebuild tears down
    /// and recreates the editing row.
    func snapshotSection(
        _ view: SnapshotSectionView, renamed snapshot: VMSnapshot, to newName: String
    ) {
        Task { [weak self] in
            guard let self else { return }
            self.viewModel.renameSnapshot(snapshot, newName: newName, on: self.instance)
            // A no-op rename (empty / unchanged) fires no observation, so force a
            // refresh to pick up anything suppressed during the edit.
            self.refresh()
        }
    }

    /// Commits an inline note edit, deferred for the same reason a rename is.
    func snapshotSection(
        _ view: SnapshotSectionView, setNotes notes: String, on snapshot: VMSnapshot
    ) {
        Task { [weak self] in
            guard let self else { return }
            self.viewModel.setSnapshotNotes(snapshot, notes: notes, on: self.instance)
            // A no-op edit (unchanged) fires no observation, so force a refresh
            // to pick up anything suppressed during the edit.
            self.refresh()
        }
    }

    func snapshotSection(
        _ view: SnapshotSectionView, requestedInfoFor snapshot: VMSnapshot, from anchor: NSView
    ) {
        presentSnapshotInfoPopover(snapshot, from: anchor)
    }
}
