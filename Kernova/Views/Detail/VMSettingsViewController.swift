import AVFoundation
import AppKit
import UniformTypeIdentifiers
import os

/// Pure-AppKit settings pane for editing a stopped VM's configuration, or
/// viewing a running VM's configuration in read-only mode.
///
/// The AppKit reimplementation of the former SwiftUI `VMSettingsView`. The
/// SwiftUI version is the behavioral spec; this is idiomatic AppKit: a single
/// concrete `NSViewController` that builds a grouped form (matching the creation
/// wizard's `GroupedFormStyle`), writes every config change through
/// `viewModel.updateConfiguration`, and refreshes its chrome from an
/// idempotent ``apply()`` driven by an ``ObservationLoop``.
///
/// Structure that depends on the *instance* (guest-agent section visibility,
/// MAC-address row, OS-specific help text) is fixed per instance and built in
/// ``buildForm()``; switching VMs rebuilds the form (mirroring the SwiftUI
/// `.id(selected.id)` reset). ``apply()`` only updates mutable state: control
/// values, lock/enabled state, the dynamic attachment lists, and the microphone
/// permission warning.
@MainActor
final class VMSettingsViewController: NSViewController {
    private static let logger = Logger(
        subsystem: "app.kernova", category: "VMSettingsViewController")

    private(set) var instance: VMInstance
    private var viewModel: VMLibraryViewModel
    private var isReadOnly: Bool

    // MARK: - Observation & live state

    private let fileMonitor = AttachmentFileMonitor()
    /// Flashes the form's scroller once when its content overflows the viewport,
    /// signaling there's more below — a light, overlay-free cue (`.flash` only,
    /// see ``ScrollMoreCues``).
    private var scrollMoreIndicator: ScrollMoreIndicator?
    private var modelObservation: ObservationLoop?
    private var hasDisappeared = false
    /// Identifies the current file-monitor observation cycle.
    ///
    /// A new token is minted each `viewDidAppear`; a re-arming callback from an
    /// older cycle (which `hasDisappeared` alone can't cancel —
    /// `withObservationTracking` has no unregister) bails when its token no
    /// longer matches, so stale chains can't accumulate across appear/disappear
    /// cycles.
    private var fileMonitorObservationToken: UUID?
    private var micPermission: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    // MARK: - Presenters & coordinators

    private let reorderSheetPresenter = SheetPresenter()
    private let micPermissionPresenter = PopoverPresenter()
    private let attachmentInfoPresenter = PopoverPresenter()
    private lazy var storageDiskCoordinator = DiskSizePopoverCoordinator(
        headline: "Create New Disk",
        caption:
            "Creates an ASIF sparse disk image inside the VM bundle. Physical size grows as data is written.",
        onConfirm: { [weak self] sizeInGB in
            guard let self else { return }
            self.viewModel.createStorageDisk(for: self.instance, sizeInGB: sizeInGB)
        }
    )
    private lazy var removableMediaCoordinator = DiskSizePopoverCoordinator(
        headline: "Create New Removable Disk",
        caption:
            "Creates a writable ASIF sparse disk image at a location you choose, attached as a hot-pluggable USB drive. The file lives outside the VM bundle.",
        onConfirm: { [weak self] sizeInGB in
            self?.presentRemovableSavePanel(sizeInGB: sizeInGB)
        }
    )

    // MARK: - Persistent chrome (rebuilt per instance in `buildForm`)

    private let formStack = NSStackView()
    private var bannerContainer = NSView()

    /// Lock icons on lockable section headers; shown only while read-only.
    private var lockIcons: [NSImageView] = []
    /// Persistent controls disabled while read-only (per-row controls set their
    /// own enabled state when the dynamic lists are rebuilt).
    private var persistentLockableControls: [NSControl] = []

    // General
    private var nameButton = NSButton()
    private let nameField = NSTextField()
    private var nameDisplayRow = NSView()
    private var nameEditRow = NSView()
    private var nameRowIsEditing = false
    /// Suppresses the end-editing commit while a path that already settled the
    /// rename (Escape's cancel) resigns the field editor — the counterpart of
    /// `SidebarVMRowCellView.isCancellingRename`.
    private var suppressNameEndEditingCommit = false
    /// Caps the name edit box at its text width so it hugs the name and grows as
    /// you type (right-aligned, the leading spacer absorbs the slack).
    ///
    /// A `<=` bound, not `==`, so a name wider than the form fills the available
    /// width and scrolls instead of the box stretching the window. Matches the
    /// storage-disk and sidebar rename boxes.
    ///
    /// Created once for the lifetime of the reused `nameField`, *not* per
    /// `buildForm()`: a width constraint lives on the field itself, so a copy
    /// minted on every instance swap would outlive its build cycle — the `<=`
    /// caps accumulate, the smallest constant wins, and a cycle whose rename
    /// never ran pins the box at the initial 0 forever (#283's collapsed
    /// single-character box).
    private lazy var nameEditMaxWidth: NSLayoutConstraint = {
        let constraint = nameField.widthAnchor.constraint(lessThanOrEqualToConstant: 0)
        constraint.priority = .defaultHigh
        return constraint
    }()
    /// Active only while renaming: ends the edit on a click outside the name field.
    ///
    /// Resigns the field editor (committing the current text) — AppKit doesn't end
    /// field editing when a click lands on the settings card's non-focusable space,
    /// so without this the box would linger. Mirrors the storage-disk row's
    /// outside-click monitor.
    private var nameOutsideClickMonitor: Any?

    // Resources
    private var cpuField = NSTextField()
    private var cpuStepper = NSStepper()
    private var memoryField = NSTextField()
    private var memoryStepper = NSStepper()

    // Storage Disks
    private var storageListStack = NSStackView()
    private var attachStorageButton = NSButton()
    private var createStorageButton = NSButton()
    private var editBootOrderButton = NSButton()
    /// Live storage row views keyed by disk id, so the context-menu "Rename"
    /// item can start inline editing on the right row.
    private var storageRowsByID: [UUID: AttachmentRowView] = [:]
    /// The disk being renamed inline, or `nil`.
    ///
    /// While set, `refreshStorageList` skips its rebuild so an async usage
    /// refresh landing mid-edit can't destroy the editing field.
    private var activeStorageRename: UUID?

    // Removable Media
    private var removableListStack = NSStackView()
    private var createRemovableButton: NSButton?
    /// Live removable-media row views keyed by item id (mirrors `storageRowsByID`).
    private var removableRowsByID: [UUID: AttachmentRowView] = [:]
    /// The removable medium being renamed inline, or `nil` (mirrors
    /// `activeStorageRename`; suppresses `refreshRemovableList` mid-edit).
    private var activeRemovableRename: UUID?

    // Shared Directories
    private var sharedListStack = NSStackView()

    // Network
    private var networkSwitch = NSSwitch()

    // Audio
    private var audioInputSwitch = NSSwitch()
    private var audioOutputSwitch = NSSwitch()
    private var audioWarningContainer = NSStackView()

    // Guest Agent
    private var logForwardingSwitch = NSSwitch()
    private var installReminderSwitch = NSSwitch()

    // Clipboard
    private var clipboardSwitch = NSSwitch()
    private var clipboardCaption = NSView()

    // Serial Console
    private var serialRelaySwitch = NSSwitch()
    private var revealSerialLogButton = NSButton()

    // MARK: - Rendered-list snapshots (early-out keys)

    /// Value snapshot of one attachment row's rendered appearance, used to
    /// skip rebuilding a list when nothing it displays has changed.
    private struct RenderedRow: Equatable {
        let id: UUID
        let iconSystemName: String
        let title: String
        let subtitle: String
        let isMissing: Bool
        let missingPath: String?
        let readOnly: Bool
        let controlsEnabled: Bool
    }
    private var renderedStorageRows: [RenderedRow]?
    private var renderedRemovableRows: [RenderedRow]?
    private var renderedSharedRows: [RenderedRow]?
    private var renderedAudioWarning: MicWarningState?

    // MARK: - Init

    init(instance: VMInstance, viewModel: VMLibraryViewModel, isReadOnly: Bool) {
        self.instance = instance
        self.viewModel = viewModel
        self.isReadOnly = isReadOnly
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("VMSettingsViewController does not support NSCoder")
    }

    /// Rebinds the controller to a (possibly different) instance / view model and
    /// read-only state without recreating the controller.
    ///
    /// Switching to a different VM rebuilds the form (per-instance structure)
    /// and restarts the per-instance side effects; a same-instance read-only
    /// flip only re-applies mutable state.
    func reconfigure(instance: VMInstance, viewModel: VMLibraryViewModel, isReadOnly: Bool) {
        let instanceChanged = instance.id != self.instance.id
        // End an in-flight name rename for the outgoing instance while it is
        // still bound: `buildForm()` resets the session flags without
        // commit/cancel, which would drop the typed text, strand `activeRename`
        // at the old id (re-selecting that VM would spontaneously reopen the
        // box), and leave the outside-click monitor installed.
        if instanceChanged, isViewLoaded, nameRowIsEditing {
            endNameRenameSession()
        }
        self.instance = instance
        self.viewModel = viewModel
        self.isReadOnly = isReadOnly

        guard isViewLoaded else { return }

        if instanceChanged {
            buildForm()
            startInstanceSideEffects()
            // Re-arm the model observation on the new instance. `withObservationTracking`
            // is one-shot and re-registers only after it fires, so without this the loop
            // stays bound to the previous instance and reactive updates (disk usage,
            // config/status changes) for the new VM wouldn't fire. Only restart when
            // already observing (i.e. the view has appeared); otherwise `viewDidAppear`
            // sets it up — creating it here early would skip the notification observer.
            if modelObservation != nil {
                restartModelObservation()
            }
        }
        apply()

        if instanceChanged {
            // Re-arm the overflow flash for the freshly built form and re-evaluate
            // against its laid-out geometry. The indicator is reused across VM
            // switches, so without this only the first overflowing pane in a
            // session would flash. Force layout so overflow is measured on the new
            // form's real height, not the outgoing VM's.
            view.layoutSubtreeIfNeeded()
            scrollMoreIndicator?.rearmFlash()
        }
    }

    // MARK: - Lifecycle

    override func loadView() {
        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = Spacing.section
        formStack.translatesAutoresizingMaskIntoConstraints = false

        // Margin only at the bottom; the top sits flush under the toolbar.
        let scrollView = makeGroupedFormScrollView(documentView: formStack, bottomInset: 16)
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)

        // Flash the scroller when the form overflows — this is the app's longest
        // grouped form. Flash-only (no chevron/fade overlays): the root is an
        // `NSStackView`, which shouldn't host unmanaged overlay subviews, and a
        // brief flash is cue enough here. The indicator is reused across VM
        // switches; `reconfigure` re-arms the flash so each overflowing pane gets
        // the cue, not just the first shown in the session.
        scrollMoreIndicator = ScrollMoreIndicator(scrollView: scrollView, cues: .flash)

        bannerContainer = makeBannerContainer()

        let root = NSStackView(views: [bannerContainer, scrollView])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = Spacing.none
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bannerContainer.widthAnchor.constraint(equalTo: root.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])

        view = root
        buildForm()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        hasDisappeared = false
        startInstanceSideEffects()
        if modelObservation == nil {
            restartModelObservation()
            NotificationCenter.default.addObserver(
                self, selector: #selector(appDidBecomeActive),
                name: NSApplication.didBecomeActiveNotification, object: nil)
        }
        let token = UUID()
        fileMonitorObservationToken = token
        observeFileMonitor(token: token)
        apply()
    }

    /// (Re)starts the model observation loop, cancelling any prior one so it
    /// tracks the current instance.
    private func restartModelObservation() {
        modelObservation?.cancel()
        modelObservation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = self.instance.configuration
                _ = self.instance.status
                _ = self.viewModel.activeRename
            },
            apply: { [weak self] in self?.apply() }
        )
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        hasDisappeared = true
        // End an in-flight name rename through the commit path (focus loss
        // commits): leaving the session flags armed would re-show the edit box
        // on reappear with no outside-click monitor and a stale marker.
        if nameRowIsEditing {
            endNameRenameSession()
        }
        removeNameOutsideClickMonitor()
        modelObservation?.cancel()
        modelObservation = nil
        NotificationCenter.default.removeObserver(
            self, name: NSApplication.didBecomeActiveNotification, object: nil)
        if reorderSheetPresenter.isShown { reorderSheetPresenter.close() }
        if micPermissionPresenter.isShown { micPermissionPresenter.close() }
        if attachmentInfoPresenter.isShown { attachmentInfoPresenter.close() }
        // Drop any in-flight inline rename so the flag can't pin a list in a
        // suppressed (never-rebuilds) state across an appear/disappear cycle.
        activeStorageRename = nil
        activeRemovableRename = nil
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        // Fallback teardown of the name-rename monitor for any path that reaches
        // `viewDidDisappear` without `viewWillDisappear` (mirrors the safety net
        // `AttachmentRowView` installs via `viewDidMoveToWindow`).
        removeNameOutsideClickMonitor()
    }

    /// Starts the per-instance side effects: seeding the file monitor with the
    /// current attachment paths and refreshing the main disk's usage stats.
    private func startInstanceSideEffects() {
        let paths = externalAttachmentPaths(for: instance.configuration)
        Task { await fileMonitor.setPaths(paths) }
    }

    /// Re-arming `withObservationTracking` on `fileMonitor.existsByPath`, so the
    /// missing-file affordance on attachment rows updates live.
    ///
    /// Mirrors the Boot Order sheet's pattern (the `hasDisappeared` guard breaks
    /// the chain on dismissal), with an added `token`: `withObservationTracking`
    /// can't unregister, so a callback from a prior appear cycle bails when its
    /// token no longer matches the current one, preventing chains from piling up
    /// across repeated appear/disappear cycles.
    private func observeFileMonitor(token: UUID) {
        if hasDisappeared || fileMonitorObservationToken != token { return }
        withObservationTracking { [fileMonitor] in
            _ = fileMonitor.existsByPath
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.hasDisappeared, self.fileMonitorObservationToken == token
                else { return }
                self.refreshStorageList()
                self.refreshRemovableList()
                self.observeFileMonitor(token: token)
            }
        }
    }

    // MARK: - Read accessors (materialize defaults, matching the SwiftUI bindings)

    private var currentStorageDisks: [StorageDisk] {
        if let disks = instance.configuration.storageDisks, !disks.isEmpty {
            return disks
        }
        return VMLibraryViewModel.defaultStorageDisks(for: instance)
    }

    private var currentRemovableMedia: [RemovableMediaItem] {
        instance.configuration.removableMedia ?? []
    }

    private var currentSharedDirectories: [SharedDirectory] {
        instance.configuration.sharedDirectories ?? []
    }

    private var isRenaming: Bool {
        viewModel.activeRename == .detail(instance.id)
    }

    // MARK: - Write helpers (route through updateConfiguration)

    private func writeStorageDisks(_ disks: [StorageDisk]) {
        viewModel.updateConfiguration(of: instance) { $0.storageDisks = disks.isEmpty ? nil : disks }
    }

    private func writeRemovableMedia(_ items: [RemovableMediaItem]) {
        viewModel.updateConfiguration(of: instance) { $0.removableMedia = items.isEmpty ? nil : items }
    }

    private func writeSharedDirectories(_ directories: [SharedDirectory]) {
        viewModel.updateConfiguration(of: instance) {
            $0.sharedDirectories = directories.isEmpty ? nil : directories
        }
    }

    private func writeConfig(_ mutate: (inout VMConfiguration) -> Void) {
        viewModel.updateConfiguration(of: instance, mutate: mutate)
    }
}

// MARK: - Form construction (per-instance structure)

extension VMSettingsViewController {
    /// Rebuilds the whole form for the current instance.
    ///
    /// Called on first load and whenever the bound instance changes (the AppKit
    /// analogue of SwiftUI's `.id(selected.id)` identity reset).
    private func buildForm() {
        formStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        lockIcons.removeAll()
        persistentLockableControls.removeAll()
        nameRowIsEditing = false
        activeStorageRename = nil
        activeRemovableRename = nil
        storageRowsByID.removeAll()
        removableRowsByID.removeAll()
        // The list stacks and audio-warning container are recreated below, so
        // invalidate the render snapshots that guard their refreshes.
        renderedStorageRows = nil
        renderedRemovableRows = nil
        renderedSharedRows = nil
        renderedAudioWarning = nil

        addSection(buildGeneralSection())
        addSection(buildResourcesSection())
        addSection(buildStorageSection())
        addSection(buildRemovableMediaSection())
        addSection(buildSharedDirectoriesSection())
        addSection(buildNetworkSection())
        addSection(buildAudioSection())
        if isGuestAgentSectionVisible(guestOS: instance.configuration.guestOS) {
            // macOS: clipboard rides the agent's vsock channel, so it joins the
            // agent group as a nested row rather than a sibling section.
            addSection(buildGuestAgentSection())
        } else {
            // Linux: clipboard is SPICE-based and independent of the Kernova
            // guest agent, so it stays a standalone section.
            addSection(buildClipboardSection())
        }
        addSection(buildSerialRelaySection())
    }

    private func addSection(_ section: NSView) {
        formStack.addArrangedSubview(section)
        section.widthAnchor.constraint(equalTo: formStack.widthAnchor).isActive = true
    }

    private func makeSection(_ subviews: [NSView]) -> NSStackView {
        let stack = NSStackView(views: subviews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.small
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in subviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    /// Section header: optional orange lock icon, the title, optional info
    /// button, then a trailing spacer.
    ///
    /// Lock icons are registered in ``lockIcons`` and toggled by ``apply()``.
    private func makeHeader(
        _ title: String, lockable: Bool = false, paragraphs: [InfoPopoverParagraph] = []
    ) -> NSView {
        var views: [NSView] = []
        if lockable {
            let lock = NSImageView(
                image: .systemSymbol("lock.fill", accessibilityDescription: "Locked while the VM is running"))
            lock.symbolConfiguration = NSImage.SymbolConfiguration(scale: .small)
            lock.contentTintColor = .systemOrange
            lock.toolTip = "Locked while the VM is running"
            lock.setContentHuggingPriority(.required, for: .horizontal)
            lock.isHidden = true
            lockIcons.append(lock)
            views.append(lock)
        }
        views.append(makeGroupedFormSectionHeader(title))
        if !paragraphs.isEmpty {
            let info = InfoButtonView()
            info.configure(label: title, paragraphs: paragraphs)
            views.append(info)
        }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        views.append(spacer)

        let header = NSStackView(views: views)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = Spacing.small
        return header
    }

    private func makeBannerContainer() -> NSView {
        let banner = makeGroupedFormBanner(
            symbolName: "lock.fill",
            tint: .systemOrange,
            message:
                "Sections marked with a lock are locked while the VM is running. Stop the VM to change them. Other sections can be edited live."
        )
        let container = NSView()
        container.addSubview(banner)
        banner.translatesAutoresizingMaskIntoConstraints = false
        let inset = GroupedFormStyle.contentSideInset
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            // Buffer below the banner so it doesn't crowd the first section title;
            // matches the inter-section rhythm of the form below.
            banner.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Spacing.section),
            banner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            banner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
        ])
        return container
    }

    // MARK: General

    private func buildGeneralSection() -> NSView {
        nameButton = NSButton(title: instance.name, target: self, action: #selector(startRename))
        nameButton.isBordered = false
        nameButton.alignment = .right
        nameButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Right-click "Rename" too, matching the storage rows and sidebar (the
        // item is gated by `validateMenuItem` when the VM can't be renamed).
        let renameMenu = NSMenu()
        let renameItem = NSMenuItem(title: "Rename", action: #selector(startRename), keyEquivalent: "")
        renameItem.target = self
        renameMenu.addItem(renameItem)
        nameButton.menu = renameMenu
        nameDisplayRow = makeGroupedFormCardRow("Name", control: nameButton)

        nameField.placeholderString = "Name"
        nameField.alignment = .right
        nameField.delegate = self
        nameField.cell?.isScrollable = true
        // The field fills the row (the leading spacer absorbs the slack) and
        // `nameEditMaxWidth` caps it at the text width, so the box hugs the name
        // and grows as you type. The cap is a `<=` bound, *not* `==`: it never
        // demands width, so a name wider than the form fills the available width
        // and scrolls instead of the box stretching the form (and the window)
        // wider. Hug is one step below the spacer's so the field claims the slack
        // first; compression is low so it yields (scrolls) rather than pushes.
        nameField.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameEditRow = makeGroupedFormCardRow("Name", control: nameField)
        // `.fill` (vs the default gravity-areas) actually stretches the field to
        // fill the row, so it claims the slack and the `<=` cap below binds —
        // otherwise the scrollable field sits at its sliver-sized intrinsic.
        (nameEditRow as? NSStackView)?.distribution = .fill
        nameEditRow.isHidden = true

        nameEditMaxWidth.isActive = true

        let nameRow = NSStackView(views: [nameDisplayRow, nameEditRow])
        nameRow.orientation = .vertical
        nameRow.alignment = .leading
        nameRow.spacing = Spacing.none
        nameDisplayRow.widthAnchor.constraint(equalTo: nameRow.widthAnchor).isActive = true
        nameEditRow.widthAnchor.constraint(equalTo: nameRow.widthAnchor).isActive = true

        let card = makeGroupedFormCard(rows: [
            nameRow,
            makeGroupedFormCardRow(
                "Type", control: makeGroupedFormValueLabel(instance.configuration.guestOS.displayName)),
            makeGroupedFormCardRow(
                "Boot Mode", control: makeGroupedFormValueLabel(instance.configuration.bootMode.displayName)),
            makeGroupedFormCardRow(
                "Created",
                control: makeGroupedFormValueLabel(
                    instance.configuration.createdAt.formatted(date: .abbreviated, time: .shortened))),
        ])
        return makeSection([makeHeader("General"), card])
    }

    // MARK: Resources

    private func buildResourcesSection() -> NSView {
        let os = instance.configuration.guestOS
        cpuField = NSTextField()
        cpuStepper = NSStepper()
        memoryField = NSTextField()
        memoryStepper = NSStepper()
        configureNumeric(
            field: cpuField, stepper: cpuStepper, min: os.minCPUCount, max: os.maxCPUCount,
            value: instance.configuration.cpuCount, stepperAction: #selector(cpuStepperChanged))
        configureNumeric(
            field: memoryField, stepper: memoryStepper, min: os.minMemoryInGB, max: os.maxMemoryInGB,
            value: instance.configuration.memorySizeInGB, stepperAction: #selector(memoryStepperChanged))
        persistentLockableControls += [cpuField, cpuStepper, memoryField, memoryStepper]

        let card = makeGroupedFormCard(rows: [
            makeGroupedFormCardRow("CPU Cores", control: steppedControl(cpuField, cpuStepper, unit: "")),
            makeGroupedFormCardRow("Memory", control: steppedControl(memoryField, memoryStepper, unit: "GB")),
        ])
        return makeSection([
            makeHeader(
                "Resources", lockable: true,
                paragraphs: [
                    .body(
                        "Memory is committed to the VM up-front at start time — keep enough free on the host to avoid swap pressure. CPU cores are scheduled by the host; over-committing is fine but reduces per-core performance under load."
                    )
                ]), card,
        ])
    }

    // MARK: Storage Disks

    private func buildStorageSection() -> NSView {
        storageListStack = makeListStack()
        attachStorageButton = makePushButton("Attach Disk…", action: #selector(attachStorageTapped))
        createStorageButton = makePushButton("Create New Disk…", action: #selector(createStorageTapped))
        editBootOrderButton = makePushButton("Edit Boot Order…", action: #selector(editBootOrderTapped))
        persistentLockableControls += [attachStorageButton, createStorageButton, editBootOrderButton]

        let buttonRow = makeButtonRow([attachStorageButton, createStorageButton, editBootOrderButton])
        let card = makeGroupedFormCard(rows: [storageListStack, buttonRow])

        let paragraphs: [InfoPopoverParagraph] =
            instance.configuration.guestOS == .linux
            ? [
                .body(
                    "Position 1 boots first on EFI guests; on Linux Kernel boot, position affects device enumeration but not boot priority."
                ),
                .body("Permanent disks attach as virtio block devices (`/dev/vda`, `/dev/vdb`, …)."),
                .body(
                    "Installer images (.iso, .dmg) attach as USB Mass Storage entries on this list — still bootable, separate from hot-pluggable Removable Media — so reordering an installer doesn't change your main disk's `/dev/vda` letter."
                ),
            ]
            : [
                .body("Position 1 is the main system disk; subsequent positions follow in order."),
                .body("Permanent disks attach as virtio block devices."),
                .body(
                    "Installer images (.iso, .dmg) attach as USB Mass Storage entries on this list — still bootable, separate from hot-pluggable Removable Media."
                ),
            ]
        return makeSection([makeHeader("Storage Disks", lockable: true, paragraphs: paragraphs), card])
    }

    // MARK: Removable Media

    private func buildRemovableMediaSection() -> NSView {
        removableListStack = makeListStack()
        let attach = makePushButton("Attach Disk…", action: #selector(attachRemovableTapped))
        let create = makePushButton("Create New Disk…", action: #selector(createRemovableTapped))
        createRemovableButton = create
        // Not lockable — removable media is hot-pluggable.
        let buttonRow = makeButtonRow([attach, create])
        let card = makeGroupedFormCard(rows: [removableListStack, buttonRow])

        let firstParagraph: InfoPopoverParagraph =
            instance.configuration.guestOS == .linux
            ? .body(
                "Appears as a USB Mass Storage device (typically `/dev/sda` or similar). Most desktop distros auto-mount; headless installs need an explicit `mount`."
            )
            : .body("Appears as a removable USB drive in Finder; auto-mounts.")
        return makeSection([
            makeHeader(
                "Removable Media",
                paragraphs: [
                    firstParagraph,
                    .body(
                        "Hot-pluggable — changes take effect immediately while the VM is running. For boot media, use Storage Disks instead."
                    ),
                ]), card,
        ])
    }

    // MARK: Shared Directories

    private func buildSharedDirectoriesSection() -> NSView {
        sharedListStack = makeListStack()
        let add = makePushButton("Add Shared Directory…", action: #selector(addSharedTapped))
        persistentLockableControls.append(add)
        let card = makeGroupedFormCard(rows: [sharedListStack, makeButtonRow([add])])

        let paragraphs: [InfoPopoverParagraph] =
            instance.configuration.guestOS == .linux
            ? [
                .body(
                    "Exposed as virtiofs mounts. Each share gets a numbered tag (`share0`, `share1`, …) in list order. Mount with:"
                ),
                .code("mount -t virtiofs share0 /mnt/myshare"),
                .body(
                    "VirtioFS has known framework limitations — files may intermittently appear missing, and host/guest permission mapping can differ."
                ),
            ]
            : [
                .body("Auto-mounts at `/Volumes/My Shared Files/` in the guest."),
                .body(
                    "VirtioFS has known framework limitations — files may intermittently appear missing, and host/guest permission mapping can differ."
                ),
            ]
        return makeSection([makeHeader("Shared Directories", lockable: true, paragraphs: paragraphs), card])
    }

    // MARK: Network

    private func buildNetworkSection() -> NSView {
        networkSwitch = makeSwitch(action: #selector(networkToggled))
        persistentLockableControls.append(networkSwitch)

        var rows: [NSView] = [makeGroupedFormCardRow("Networking Enabled", control: networkSwitch)]
        if let mac = instance.configuration.macAddress {
            rows.append(makeGroupedFormCardRow("MAC Address", control: makeGroupedFormValueLabel(mac)))
        }

        var paragraphs: [InfoPopoverParagraph] = [
            .body(
                "NAT-mode networking. The host assigns the guest a DHCP address on a private subnet. Outbound connections work; there is no port forwarding from host to guest — incoming connections require knowing the guest's IP."
            )
        ]
        if instance.configuration.guestOS == .linux {
            paragraphs.append(
                .body(
                    "The interface usually appears as `enp0s1`. If networking doesn't come up, make sure your distro's DHCP client or NetworkManager is running."
                ))
        }
        return makeSection([
            makeHeader("Network", lockable: true, paragraphs: paragraphs),
            makeGroupedFormCard(rows: rows),
        ])
    }

    // MARK: Audio

    private func buildAudioSection() -> NSView {
        audioInputSwitch = makeSwitch(action: #selector(audioInputToggled))
        audioOutputSwitch = makeSwitch(action: #selector(audioOutputToggled))
        persistentLockableControls.append(audioInputSwitch)
        persistentLockableControls.append(audioOutputSwitch)

        audioWarningContainer = NSStackView()
        audioWarningContainer.orientation = .vertical
        audioWarningContainer.alignment = .leading
        audioWarningContainer.spacing = Spacing.small
        audioWarningContainer.translatesAutoresizingMaskIntoConstraints = false

        var paragraphs: [InfoPopoverParagraph] = [
            .body(
                "Exposes a VirtioSound device with independent streams. Audio Input lets the guest capture from your Mac's audio input; Audio Output plays guest sound through your Mac."
            )
        ]
        if instance.configuration.guestOS == .linux {
            paragraphs.append(.body("Requires Linux kernel 5.14 or newer to detect the VirtioSound device."))
        }
        return makeSection([
            makeHeader("Audio", lockable: true, paragraphs: paragraphs),
            makeGroupedFormCard(rows: [
                makeGroupedFormCardRow("Audio Input", control: audioInputSwitch),
                makeGroupedFormCardRow("Audio Output", control: audioOutputSwitch),
            ]),
            audioWarningContainer,
        ])
    }

    // MARK: Guest Agent

    /// Caption shown beneath the macOS Guest Agent card.
    ///
    /// Makes the cohort's shared dependency legible at a glance; extracted so
    /// tests can assert it verbatim.
    static let agentDependencyCaption =
        "Clipboard sharing and log forwarding require the Kernova guest agent. Kernova offers to install it from the clipboard window."

    /// Guest Agent group for **macOS** guests.
    ///
    /// Holds the two agent-management toggles plus Clipboard Sharing, which
    /// rides the agent's vsock channel and is therefore agent-dependent.
    /// Grouping them under a dependency caption makes it obvious which features
    /// go inert when the agent isn't installed or connected. Linux clipboard is
    /// SPICE-based — see `buildClipboardSection()`.
    private func buildGuestAgentSection() -> NSView {
        logForwardingSwitch = makeSwitch(action: #selector(logForwardingToggled))
        installReminderSwitch = makeSwitch(action: #selector(installReminderToggled))
        clipboardSwitch = makeSwitch(action: #selector(clipboardToggled))
        // Not lockable — every toggle here takes effect live. Future
        // agent-backed features belong in this group too, so the cohort that
        // depends on the guest agent stays intact rather than spawning new
        // top-level sections.
        // Capability toggles first (the cohort the caption names), then the
        // install-reminder nudge control last.
        let card = makeGroupedFormCard(rows: [
            makeToggleRowWithInfo(
                "Forward guest logs", control: logForwardingSwitch,
                paragraphs: [
                    .body(
                        "Streams `os.Logger` records from the macOS guest agent to the host so they appear in Console.app under `app.kernova.guest`. Off by default; can be toggled while the VM is running."
                    )
                ]),
            makeToggleRowWithInfo(
                "Clipboard Sharing", control: clipboardSwitch,
                paragraphs: [
                    .body(
                        "Exchanges clipboard text between host and guest. Uses the bundled Kernova guest agent."
                    )
                ]),
            makeToggleRowWithInfo(
                "Show install reminder", control: installReminderSwitch,
                paragraphs: [
                    .body(
                        "Surfaces the install icon in the sidebar when the guest agent has not yet connected. Turn off to suppress the nudge for this VM. The more urgent indicators (update available, didn't reconnect, unresponsive) are not affected."
                    )
                ]),
        ])
        return makeSection([
            makeHeader("Guest Agent"), card, makeGroupedFormCaption(Self.agentDependencyCaption),
        ])
    }

    // MARK: Clipboard

    /// Standalone Clipboard section for **Linux** guests, whose clipboard rides
    /// SPICE (`spice-vdagent`) and is independent of the Kernova guest agent.
    /// macOS clipboard is agent-dependent and lives in `buildGuestAgentSection()`.
    private func buildClipboardSection() -> NSView {
        clipboardSwitch = makeSwitch(action: #selector(clipboardToggled))
        let caption = makeGroupedFormCaption(
            "Takes effect on next start — Linux guests configure SPICE at VM start time.")
        caption.textColor = .systemOrange
        caption.isHidden = true
        clipboardCaption = caption

        let body: InfoPopoverParagraph = .body(
            "Exchanges clipboard text between host and guest. Requires `spice-vdagent` installed in the guest via its package manager."
        )
        return makeSection([
            makeHeader("Clipboard", paragraphs: [body]),
            makeGroupedFormCard(rows: [makeGroupedFormCardRow("Clipboard Sharing", control: clipboardSwitch)]),
            clipboardCaption,
        ])
    }

    // MARK: Serial Console

    private func buildSerialRelaySection() -> NSView {
        serialRelaySwitch = makeSwitch(action: #selector(serialRelayToggled))
        revealSerialLogButton = makePushButton(
            "Reveal serial.log in Finder", action: #selector(revealSerialLog))
        let socketPath = VMInstance.serialSocketPath(for: instance.id)
        let card = makeGroupedFormCard(rows: [
            makeToggleRowWithInfo(
                "Expose Serial Socket", control: serialRelaySwitch,
                paragraphs: [
                    .body(
                        "Exposes the running VM's serial port over a local UNIX socket so an external terminal can attach. Output is always captured to `serial.log` regardless of this setting."
                    ),
                    .body(
                        "While the VM is running, connect with `socat` (best for full-screen apps; `brew install socat`):"
                    ),
                    .code("socat -,raw,echo=0 UNIX-CONNECT:\(socketPath)"),
                    .body("…or the built-in `nc` (line mode):"),
                    .code("nc -U \(socketPath)"),
                ]),
            makeButtonRow([revealSerialLogButton]),
        ])
        return makeSection([makeHeader("Serial Console"), card])
    }
}

// MARK: - Small control/layout factories

extension VMSettingsViewController {
    private func makeListStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.standard
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func makePushButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func makeButtonRow(_ buttons: [NSButton]) -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: buttons + [spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Spacing.standard
        return row
    }

    private func makeSwitch(action: Selector) -> NSSwitch {
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = action
        return toggle
    }

    private func makeToggleRowWithInfo(
        _ title: String, control: NSControl, paragraphs: [InfoPopoverParagraph]
    ) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = Typography.body
        label.isSelectable = false
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let info = InfoButtonView()
        info.configure(label: title, paragraphs: paragraphs)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [label, info, spacer, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Spacing.small
        return row
    }

    private func steppedControl(_ field: NSTextField, _ stepper: NSStepper, unit: String) -> NSStackView {
        let unitLabel = NSTextField(labelWithString: unit)
        unitLabel.font = Typography.body
        unitLabel.textColor = .secondaryLabelColor
        unitLabel.isSelectable = false
        unitLabel.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let control = NSStackView(views: [field, stepper, unitLabel])
        control.orientation = .horizontal
        control.alignment = .centerY
        control.spacing = Spacing.tight
        return control
    }

    private func configureNumeric(
        field: NSTextField, stepper: NSStepper, min: Int, max: Int, value: Int, stepperAction: Selector
    ) {
        let clamped = Swift.min(Swift.max(value, min), max)
        field.alignment = .right
        field.delegate = self
        field.integerValue = clamped
        field.widthAnchor.constraint(equalToConstant: 44).isActive = true

        stepper.controlSize = .small
        stepper.minValue = Double(min)
        stepper.maxValue = Double(max)
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.integerValue = clamped
        stepper.target = self
        stepper.action = stepperAction
    }

    private func makeReadOnlySwitch(id: UUID, isOn: Bool, enabled: Bool, action: Selector) -> NSSwitch {
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.state = isOn ? .on : .off
        toggle.isEnabled = enabled
        toggle.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        toggle.target = self
        toggle.action = action
        return toggle
    }

    private func makeReadOnlyCaption() -> NSTextField {
        let caption = NSTextField(labelWithString: "Read Only")
        caption.font = .preferredFont(forTextStyle: .caption1)
        caption.textColor = .secondaryLabelColor
        caption.isSelectable = false
        caption.setContentHuggingPriority(.required, for: .horizontal)
        return caption
    }

    /// An inline trailing "eject" button for an attachment/share row.
    ///
    /// Tinted with the secondary label color rather than destructive red: on
    /// removable media the button ejects (detach only, file untouched) and a
    /// shared directory's button merely stops sharing — both non-destructive and
    /// re-attachable — so the eject glyph and a neutral tint read truer than a
    /// red minus.
    private func makeEjectButton(id: UUID, enabled: Bool, action: Selector) -> NSButton {
        let button = NSButton()
        button.image = .systemSymbol("eject.circle.fill", accessibilityDescription: "Eject")
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.isEnabled = enabled
        button.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        button.target = self
        button.action = action
        return button
    }

    /// Builds an attachment list row: leading icon, title + subtitle, a
    /// read-only switch with its caption, and a trailing eject button wired to
    /// `deleteSelector` (neutral-tinted; the row's removal is non-destructive).
    private func makeListRow(
        icon: NSView, title: String, subtitle: NSTextField, id: UUID, readOnly: Bool,
        controlsEnabled: Bool, readOnlySelector: Selector, deleteSelector: Selector
    ) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = Typography.body
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.isSelectable = false

        let textStack = NSStackView(views: [titleLabel, subtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = Spacing.hairline

        let readOnlyToggle = makeReadOnlySwitch(
            id: id, isOn: readOnly, enabled: controlsEnabled, action: readOnlySelector)
        let readOnlyCaption = makeReadOnlyCaption()

        let eject = makeEjectButton(id: id, enabled: controlsEnabled, action: deleteSelector)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [icon, textStack, spacer, readOnlyToggle, readOnlyCaption, eject])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Spacing.standard
        return row
    }

    private func uuid(from sender: Any?) -> UUID? {
        guard let raw = (sender as? NSView)?.identifier?.rawValue else { return nil }
        return UUID(uuidString: raw)
    }
}

// MARK: - apply() and per-section refresh

extension VMSettingsViewController {
    /// Idempotently refreshes all mutable chrome from the model.
    ///
    /// Safe to call repeatedly; the single source of truth for enable/disable
    /// and the dynamic lists.
    private func apply() {
        guard isViewLoaded else { return }
        bannerContainer.isHidden = !isReadOnly
        lockIcons.forEach { $0.isHidden = !isReadOnly }
        persistentLockableControls.forEach { $0.isEnabled = !isReadOnly }

        refreshGeneral()
        refreshResources()
        refreshNetwork()
        refreshAudio()
        refreshGuestAgent()
        refreshClipboard()
        refreshSerialRelay()
        refreshStorageList()
        refreshRemovableList()
        refreshSharedList()

        let paths = externalAttachmentPaths(for: instance.configuration)
        Task { await fileMonitor.setPaths(paths) }
    }

    private func refreshGeneral() {
        nameButton.title = instance.name
        nameButton.isEnabled = instance.status.canRename
        let renaming = isRenaming
        if renaming != nameRowIsEditing {
            if renaming {
                nameRowIsEditing = true
                nameDisplayRow.isHidden = true
                nameEditRow.isHidden = false
                nameField.stringValue = instance.name
                view.window?.makeFirstResponder(nameField)
                // Re-seed after taking focus: the makeFirstResponder above can
                // synchronously commit the *other* surface's pending rename
                // (mid-handoff), changing `instance.name` after the seed — and
                // the mutation lands inside this very apply() pass, so no
                // later pass repairs an already-open box. Reading the name
                // again guarantees the box shows what a commit would produce.
                nameField.stringValue = instance.name
                if let editor = nameField.currentEditor() {
                    editor.string = instance.name
                    editor.selectAll(nil)
                }
                nameEditMaxWidth.constant = InlineRenameSizing.boxWidth(
                    for: instance.name, font: Typography.body)
                installNameOutsideClickMonitor()
            } else {
                removeNameOutsideClickMonitor()
                // End a still-active editor session BEFORE flipping the local
                // session flag or hiding the row: the resign flows through
                // `controlTextDidEndEditing`, whose commit gate reads
                // `nameRowIsEditing` — a superseded rename's in-flight text
                // then still commits instead of being silently dropped, and no
                // orphaned, focused-but-invisible editor survives to swallow
                // keystrokes.
                if nameField.currentEditor() != nil {
                    Self.logger.debug(
                        "Ending superseded name rename session via end-editing commit")
                    view.window?.makeFirstResponder(nil)
                }
                nameRowIsEditing = false
                nameDisplayRow.isHidden = false
                nameEditRow.isHidden = true
            }
        }
    }

    /// Installs a local mouse-down monitor that ends the rename on an outside click.
    ///
    /// Resigns the field editor so `controlTextDidEndEditing` commits when the user
    /// clicks anywhere outside the name field — AppKit doesn't end field editing on
    /// clicks that land on non-focusable space in the settings card. Mirrors the
    /// storage-disk row's outside-click monitor.
    private func installNameOutsideClickMonitor() {
        removeNameOutsideClickMonitor()
        nameOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, self.isRenaming else { return event }
            let pointInField = self.nameField.convert(event.locationInWindow, from: nil)
            if !self.nameField.bounds.contains(pointInField) {
                self.view.window?.makeFirstResponder(nil)
            }
            return event
        }
    }

    private func removeNameOutsideClickMonitor() {
        if let monitor = nameOutsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            nameOutsideClickMonitor = nil
        }
    }

    /// Ends an in-flight name rename through the end-editing commit path.
    ///
    /// For paths that bypass `refreshGeneral`'s teardown transition (instance
    /// rebind, view disappearance): those reset `nameRowIsEditing` out-of-band,
    /// which would otherwise strand the typed text, the marker, and the
    /// outside-click monitor.
    private func endNameRenameSession() {
        if nameField.currentEditor() != nil {
            view.window?.makeFirstResponder(nil)
        }
        removeNameOutsideClickMonitor()
        nameRowIsEditing = false
        nameDisplayRow.isHidden = false
        nameEditRow.isHidden = true
    }

    private func refreshResources() {
        let os = instance.configuration.guestOS
        cpuStepper.minValue = Double(os.minCPUCount)
        cpuStepper.maxValue = Double(os.maxCPUCount)
        cpuStepper.integerValue = instance.configuration.cpuCount
        cpuField.integerValue = instance.configuration.cpuCount
        memoryStepper.minValue = Double(os.minMemoryInGB)
        memoryStepper.maxValue = Double(os.maxMemoryInGB)
        memoryStepper.integerValue = instance.configuration.memorySizeInGB
        memoryField.integerValue = instance.configuration.memorySizeInGB
    }

    private func refreshNetwork() {
        networkSwitch.state = instance.configuration.networkEnabled ? .on : .off
    }

    private func refreshAudio() {
        audioInputSwitch.state = instance.configuration.audioInputEnabled ? .on : .off
        audioOutputSwitch.state = instance.configuration.audioOutputEnabled ? .on : .off
        let warning = micPermissionPresentation(
            micPermission, audioInputEnabled: instance.configuration.audioInputEnabled)
        guard warning != renderedAudioWarning else { return }
        renderedAudioWarning = warning
        audioWarningContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }

        switch warning {
        case .none:
            break
        case .willPrompt:
            let caption = makeGroupedFormCaption(
                "macOS will ask for microphone permission the first time a VM uses it.")
            addFullWidth(caption, to: audioWarningContainer)
        case .denied:
            let info = NSButton(
                image: .systemSymbol("info.circle", accessibilityDescription: "Microphone permission help"),
                target: self, action: #selector(showMicPermissionInfo))
            info.isBordered = false
            info.imagePosition = .imageOnly
            info.contentTintColor = .secondaryLabelColor
            let banner = makeGroupedFormBanner(
                symbolName: "exclamationmark.triangle.fill",
                tint: .systemRed,
                message:
                    "Microphone permission is denied. Enable it in System Settings for Kernova to pass your microphone to VMs.",
                trailingButtons: [info])
            addFullWidth(banner, to: audioWarningContainer)
        }
    }

    private func refreshGuestAgent() {
        guard isGuestAgentSectionVisible(guestOS: instance.configuration.guestOS) else { return }
        logForwardingSwitch.state = instance.configuration.agentLogForwardingEnabled ? .on : .off
        installReminderSwitch.state = instance.configuration.agentInstallNudgeDismissed ? .off : .on
    }

    private func refreshClipboard() {
        clipboardSwitch.state = instance.configuration.clipboardSharingEnabled ? .on : .off
        clipboardCaption.isHidden = !(isReadOnly && instance.configuration.guestOS == .linux)
    }

    private func refreshSerialRelay() {
        serialRelaySwitch.state = instance.configuration.serialSocketRelayEnabled ? .on : .off
        // serial.log is created on first run and persists thereafter; disable
        // the reveal button until it exists.
        revealSerialLogButton.isEnabled = FileManager.default.fileExists(
            atPath: instance.serialLogURL.path(percentEncoded: false))
    }

    private func refreshStorageList() {
        let disks = currentStorageDisks
        editBootOrderButton.isHidden = disks.count <= 1
        let models = disks.map { disk -> RenderedRow in
            let isMissing = !disk.isInternal && !fileMonitor.exists(disk.path)
            return RenderedRow(
                id: disk.id,
                iconSystemName: diskIconSystemName(for: disk),
                title: disk.label,
                // Structural subtitle only — the live size is read off-main and
                // filled in by `populate`, so it isn't part of the rebuild diff.
                subtitle: disk.isInternal ? "In-bundle disk image" : disk.path,
                isMissing: isMissing,
                missingPath: isMissing ? disk.path : nil,
                readOnly: disk.readOnly,
                controlsEnabled: !isReadOnly)
        }
        refreshAttachmentList(
            models: models, listStack: storageListStack, kind: .storage,
            rowsByID: \.storageRowsByID, rendered: \.renderedStorageRows,
            activeRename: \.activeStorageRename,
            readOnlySelector: #selector(storageReadOnlyToggled), emptyMessage: nil
        ) { [weak self] field, model in
            guard let self,
                let disk = self.currentStorageDisks.first(where: { $0.id == model.id })
            else { return }
            populateDiskSubtitle(
                field, for: disk, bundleLayout: self.instance.bundleLayout,
                isMissing: model.isMissing)
        }
    }

    private func refreshRemovableList() {
        let items = currentRemovableMedia
        let models = items.map { item -> RenderedRow in
            let isMissing = !fileMonitor.exists(item.path)
            return RenderedRow(
                id: item.id,
                iconSystemName: "opticaldisc",
                title: item.label,
                // Structural subtitle only (see `refreshStorageList`). Removable
                // media is always external and hot-pluggable, so controls stay
                // enabled even while the VM runs.
                subtitle: item.path,
                isMissing: isMissing,
                missingPath: isMissing ? item.path : nil,
                readOnly: item.readOnly,
                controlsEnabled: true)
        }
        refreshAttachmentList(
            models: models, listStack: removableListStack, kind: .removable,
            rowsByID: \.removableRowsByID, rendered: \.renderedRemovableRows,
            activeRename: \.activeRemovableRename,
            readOnlySelector: #selector(removableReadOnlyToggled),
            emptyMessage: "No removable media attached"
        ) { [weak self] field, model in
            guard let self,
                let item = self.currentRemovableMedia.first(where: { $0.id == model.id })
            else { return }
            populateDiskSubtitle(
                field, for: item, bundleLayout: self.instance.bundleLayout,
                isMissing: model.isMissing)
        }
    }

    private func refresh(_ kind: AttachmentKind) {
        switch kind {
        case .storage: refreshStorageList()
        case .removable: refreshRemovableList()
        }
    }

    /// Shared rebuild/in-place-update engine for both attachment lists.
    ///
    /// A structural change (rows added, removed, or reordered) rebuilds the
    /// stack; anything else updates the affected rows in place so a rename or
    /// toggle doesn't recreate every subtitle field and re-fade its size in.
    ///
    /// - A structural rebuild is the only path that tears down an in-progress
    ///   editing field, so it (and only it) is skipped while a row is being
    ///   renamed; the in-place path runs freely — `AttachmentRowView.update`
    ///   leaves a live title alone and the subtitle is an independent field — so
    ///   a rename committed by clicking another row still repaints in place.
    /// - The live size is re-read on *every* in-place pass (not gated on the
    ///   structural subtitle changing), so an out-of-band resize is reflected;
    ///   `setDiskSubtitle` skips the repaint when the size is unchanged, so a
    ///   rename/toggle still doesn't flicker.
    private func refreshAttachmentList(
        models: [RenderedRow],
        listStack: NSStackView,
        kind: AttachmentKind,
        rowsByID rowsKP: ReferenceWritableKeyPath<VMSettingsViewController, [UUID: AttachmentRowView]>,
        rendered renderedKP: ReferenceWritableKeyPath<VMSettingsViewController, [RenderedRow]?>,
        activeRename activeKP: ReferenceWritableKeyPath<VMSettingsViewController, UUID?>,
        readOnlySelector: Selector,
        emptyMessage: String?,
        populate: @escaping (NSTextField, RenderedRow) -> Void
    ) {
        let previousRows = self[keyPath: renderedKP]
        let structural = previousRows?.map(\.id) != models.map(\.id)

        if structural {
            // A rebuild would destroy an in-progress editing field, so defer it
            // until the edit ends (the cancel/commit handler re-runs the refresh).
            if self[keyPath: activeKP] != nil { return }
            self[keyPath: renderedKP] = models
            clear(listStack)
            self[keyPath: rowsKP].removeAll(keepingCapacity: true)
            guard !models.isEmpty else {
                if let emptyMessage {
                    addFullWidth(makeSecondaryLabel(emptyMessage), to: listStack)
                }
                return
            }
            for model in models {
                let row = makeAttachmentRow(
                    model: model, kind: kind, readOnlySelector: readOnlySelector,
                    activeRename: activeKP)
                self[keyPath: rowsKP][model.id] = row
                addFullWidth(row, to: listStack)
                // Freshly built rows start with an empty subtitle — read once.
                populate(row.subtitleField, model)
            }
            return
        }

        self[keyPath: renderedKP] = models
        let previousByID = Dictionary(
            (previousRows ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for model in models {
            guard let row = self[keyPath: rowsKP][model.id] else { continue }
            if previousByID[model.id] != model {
                row.update(
                    title: model.title, iconSystemName: model.iconSystemName,
                    missingPath: model.missingPath, readOnly: model.readOnly,
                    controlsEnabled: model.controlsEnabled)
            }
            populate(row.subtitleField, model)
        }
    }

    /// Builds one attachment row, wiring its icon Get Info, rename closures, and
    /// context menu — shared by both lists (the per-list differences arrive via
    /// `kind`, `readOnlySelector`, and the active-rename key path).
    private func makeAttachmentRow(
        model: RenderedRow,
        kind: AttachmentKind,
        readOnlySelector: Selector,
        activeRename activeKP: ReferenceWritableKeyPath<VMSettingsViewController, UUID?>
    ) -> AttachmentRowView {
        let ref = AttachmentRef(kind: kind, id: model.id)
        let icon = AttachmentIconButton()
        icon.configure(systemName: model.iconSystemName, missingPath: model.missingPath)
        // Clicking the (present) icon opens Get Info anchored to the icon.
        icon.onActivate = { [weak self] anchor in
            guard let self, let info = self.attachmentInfo(ref) else { return }
            self.presentAttachmentInfoPopover(info, from: anchor)
        }
        // Removable media is hot-pluggable and swapped often, so it carries an
        // inline one-click Eject button (detach only, no confirmation); the
        // context menu still offers both Eject and the file-trashing Remove.
        // Storage disks have no inline button (`kind` is the documented carrier
        // for per-list differences).
        let ejectButton: NSButton? =
            kind == .removable
            ? makeEjectButton(
                id: model.id, enabled: model.controlsEnabled,
                action: #selector(removableEjectTapped))
            : nil
        let row = AttachmentRowView(
            itemID: model.id,
            title: model.title,
            controlsEnabled: model.controlsEnabled,
            icon: icon,
            subtitle: makeAttachmentSubtitleLabel(path: "", isMissing: false),
            readOnlyToggle: makeReadOnlySwitch(
                id: model.id, isOn: model.readOnly, enabled: model.controlsEnabled,
                action: readOnlySelector),
            readOnlyCaption: makeReadOnlyCaption(),
            ejectButton: ejectButton)
        row.onRenameBegan = { [weak self] id in self?[keyPath: activeKP] = id }
        row.onRenameCommitted = { [weak self] _, newLabel in
            self?.commitAttachmentRename(ref, newLabel: newLabel)
        }
        row.onRenameCancelled = { [weak self] _ in
            self?[keyPath: activeKP] = nil
            self?.refresh(kind)
        }
        row.contextMenu = { [weak self] in self?.buildAttachmentContextMenu(ref) }
        return row
    }

    /// Commits an inline rename for either list, deferred to the next runloop
    /// turn so the field editor's end-editing callback fully unwinds before the
    /// config-change rebuild tears down and recreates the editing row.
    private func commitAttachmentRename(_ ref: AttachmentRef, newLabel: String) {
        clearActiveRename(ref.kind)
        Task { [weak self] in
            guard let self else { return }
            switch ref.kind {
            case .storage:
                if let disk = self.currentStorageDisks.first(where: { $0.id == ref.id }) {
                    self.viewModel.renameStorageDisk(disk, newLabel: newLabel, on: self.instance)
                }
            case .removable:
                if let item = self.currentRemovableMedia.first(where: { $0.id == ref.id }) {
                    self.viewModel.renameRemovableMedia(item, newLabel: newLabel, on: self.instance)
                }
            }
            // A no-op rename (empty / unchanged) fires no observation, so force a
            // refresh to pick up any size update suppressed during the edit.
            self.refresh(ref.kind)
        }
    }

    private func clearActiveRename(_ kind: AttachmentKind) {
        switch kind {
        case .storage: activeStorageRename = nil
        case .removable: activeRemovableRename = nil
        }
    }

    private func refreshSharedList() {
        let models = currentSharedDirectories.map { directory in
            RenderedRow(
                id: directory.id,
                iconSystemName: "folder",
                title: directory.displayName,
                subtitle: directory.path,
                isMissing: false,
                missingPath: nil,
                readOnly: directory.readOnly,
                controlsEnabled: !isReadOnly)
        }
        guard models != renderedSharedRows else { return }
        renderedSharedRows = models
        clear(sharedListStack)
        if models.isEmpty {
            addFullWidth(makeSecondaryLabel("No shared directories"), to: sharedListStack)
            return
        }
        for model in models {
            let icon = NSImageView(image: .systemSymbol("folder", accessibilityDescription: ""))
            icon.contentTintColor = .secondaryLabelColor
            icon.setContentHuggingPriority(.required, for: .horizontal)
            let row = makeListRow(
                icon: icon,
                title: model.title,
                subtitle: makeAttachmentSubtitleLabel(path: model.subtitle, isMissing: false),
                id: model.id,
                readOnly: model.readOnly,
                controlsEnabled: model.controlsEnabled,
                readOnlySelector: #selector(sharedReadOnlyToggled),
                deleteSelector: #selector(sharedDeleteTapped))
            addFullWidth(row, to: sharedListStack)
        }
    }

    private func refreshMicPermission() {
        micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    private func makeSecondaryLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        return label
    }

    private func clear(_ stack: NSStackView) {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
    }

    private func addFullWidth(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
}

// MARK: - Actions

extension VMSettingsViewController {
    @objc private func startRename() {
        guard instance.status.canRename else { return }
        viewModel.renameVMInDetail(instance)
    }

    /// Disables the name field's right-click "Rename" while the VM can't be
    /// renamed (e.g. while running), mirroring the disabled name button.
    // periphery:ignore - AppKit's menu-validation machinery invokes this
    // informal-protocol method on the name button's menu target (`self`)
    // before showing the "Rename" item; that framework-driven call is
    // invisible to Periphery's symbol graph.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(startRename) {
            return instance.status.canRename
        }
        return true
    }

    @objc private func cpuStepperChanged() {
        cpuField.integerValue = cpuStepper.integerValue
        writeConfig { $0.cpuCount = cpuStepper.integerValue }
    }

    @objc private func memoryStepperChanged() {
        memoryField.integerValue = memoryStepper.integerValue
        writeConfig { $0.memorySizeInGB = memoryStepper.integerValue }
    }

    @objc private func networkToggled() {
        writeConfig { $0.networkEnabled = networkSwitch.state == .on }
    }

    @objc private func audioInputToggled() {
        refreshMicPermission()
        writeConfig { $0.audioInputEnabled = audioInputSwitch.state == .on }
    }

    @objc private func audioOutputToggled() {
        writeConfig { $0.audioOutputEnabled = audioOutputSwitch.state == .on }
    }

    @objc private func logForwardingToggled() {
        writeConfig { $0.agentLogForwardingEnabled = logForwardingSwitch.state == .on }
    }

    @objc private func installReminderToggled() {
        writeConfig { $0.agentInstallNudgeDismissed = installReminderSwitch.state != .on }
    }

    @objc private func serialRelayToggled() {
        writeConfig { $0.serialSocketRelayEnabled = serialRelaySwitch.state == .on }
    }

    @objc private func revealSerialLog() {
        NSWorkspace.shared.activateFileViewerSelecting([instance.serialLogURL])
    }

    @objc private func clipboardToggled() {
        writeConfig { $0.clipboardSharingEnabled = clipboardSwitch.state == .on }
    }

    @objc private func showMicPermissionInfo(_ sender: NSButton) {
        micPermissionPresenter.show(
            content: MicrophonePermissionPopoverContentViewController(), from: sender, preferredEdge: .minY)
    }

    @objc private func appDidBecomeActive() {
        refreshMicPermission()
        apply()
    }

    // MARK: Storage

    @objc private func attachStorageTapped() {
        let urls = NSOpenPanel.browseDiskImages(
            message: "Select disk images to attach to the VM", allowsMultipleSelection: true)
        guard !urls.isEmpty else { return }
        var current = currentStorageDisks
        let existing = Set(current.map(\.path))
        for url in urls {
            let path = url.path(percentEncoded: false)
            guard !existing.contains(path) else { continue }
            current.append(StorageDisk(path: path))
        }
        writeStorageDisks(current)
    }

    @objc private func createStorageTapped() {
        storageDiskCoordinator.show(from: createStorageButton)
    }

    @objc private func editBootOrderTapped() {
        guard let window = view.window else { return }
        let sheet = StorageDiskReorderSheetContentViewController(
            disks: currentStorageDisks, instance: instance, fileMonitor: fileMonitor)
        sheet.delegate = self
        reorderSheetPresenter.show(content: sheet, in: window)
    }

    @objc private func storageReadOnlyToggled(_ sender: NSSwitch) {
        guard let id = uuid(from: sender) else { return }
        setStorageReadOnly(sender.state == .on, forDiskID: id)
    }

    private func setStorageReadOnly(_ readOnly: Bool, forDiskID id: UUID) {
        var disks = currentStorageDisks
        guard let index = disks.firstIndex(where: { $0.id == id }) else { return }
        disks[index].readOnly = readOnly
        writeStorageDisks(disks)
    }

    private func presentStorageDeleteConfirmation(forDiskID id: UUID) {
        guard let window = view.window,
            let disk = currentStorageDisks.first(where: { $0.id == id })
        else { return }
        // Internal (bundle-relative) disks are per-VM, so they're never shared;
        // only resolve sharing for external disks.
        let shared = disk.isInternal ? [] : viewModel.sharingVMNames(forPath: disk.path, excluding: instance)
        let prompt = Self.attachmentDeletePrompt(
            label: disk.label,
            isInternal: disk.isInternal,
            isMainDisk: viewModel.isMainDisk(disk, of: instance),
            isGuestAgent: false,
            sharedVMNames: shared)
        presentSheetAlert(
            makeDeleteAlert(prompt: prompt) { [weak self] trashFile in
                guard let self else { return }
                _ = self.viewModel.removeStorageDisk(disk, from: self.instance, trashFile: trashFile)
            },
            in: window)
    }

    // MARK: Attachment context menu (shared by both lists)

    /// Identifies which list a context-menu item / row belongs to, so a single
    /// set of `@objc` handlers serves both the Storage Disks and Removable Media
    /// lists.
    enum AttachmentKind { case storage, removable }

    /// A context-menu item's backing identity (list + id), stored as its
    /// `representedObject`.
    ///
    /// A class so it's a valid `representedObject`.
    final class AttachmentRef: NSObject {
        let kind: AttachmentKind
        let id: UUID
        init(kind: AttachmentKind, id: UUID) {
            self.kind = kind
            self.id = id
        }
    }

    /// A normalized read of an attachment's current state, so the shared menu /
    /// Get Info / Finder actions don't branch on kind.
    private struct AttachmentInfo {
        let id: UUID
        let label: String
        let path: String
        let isInternal: Bool
        let readOnly: Bool
        let busText: String
        /// Rename / Read Only / Remove gating: storage follows the running-VM
        /// read-only lock; removable media is hot-pluggable, so always editable.
        let editable: Bool
    }

    private func attachmentInfo(_ ref: AttachmentRef) -> AttachmentInfo? {
        switch ref.kind {
        case .storage:
            guard let disk = currentStorageDisks.first(where: { $0.id == ref.id }) else { return nil }
            return AttachmentInfo(
                id: disk.id, label: disk.label, path: disk.path, isInternal: disk.isInternal,
                readOnly: disk.readOnly,
                busText: disk.kind == .usbMassStorage ? "USB mass storage" : "Virtio block",
                editable: !isReadOnly)
        case .removable:
            guard let item = currentRemovableMedia.first(where: { $0.id == ref.id }) else { return nil }
            return AttachmentInfo(
                id: item.id, label: item.label, path: item.path, isInternal: false,
                readOnly: item.readOnly, busText: "USB mass storage", editable: true)
        }
    }

    private func attachmentRow(_ ref: AttachmentRef) -> AttachmentRowView? {
        switch ref.kind {
        case .storage: return storageRowsByID[ref.id]
        case .removable: return removableRowsByID[ref.id]
        }
    }

    /// Absolute URL backing an attachment, via the single resolution rule in
    /// ``VMBundleLayout/diskURL(forRelativePath:isInternal:)``.
    private func attachmentURL(_ info: AttachmentInfo) -> URL {
        instance.bundleLayout.diskURL(forRelativePath: info.path, isInternal: info.isInternal)
    }

    /// Builds the right-click menu for an attachment row, lazily at click time so
    /// it reflects current state (the Read Only checkmark, missing-file disabling).
    private func buildAttachmentContextMenu(_ ref: AttachmentRef) -> NSMenu? {
        guard let info = attachmentInfo(ref) else { return nil }
        let menu = NSMenu()
        // We manage enablement explicitly (rename/remove gated by read-only lock,
        // Show in Finder by file presence), so opt out of auto-validation.
        menu.autoenablesItems = false

        let rename = attachmentMenuItem("Rename", #selector(menuAttachmentRename(_:)), ref)
        rename.isEnabled = info.editable
        menu.addItem(rename)
        menu.addItem(attachmentMenuItem("Get Info", #selector(menuAttachmentGetInfo(_:)), ref))

        menu.addItem(.separator())

        let showInFinder = attachmentMenuItem(
            "Show in Finder", #selector(menuAttachmentShowInFinder(_:)), ref)
        // Nothing to reveal when an external file is missing (in-bundle always exists).
        showInFinder.isEnabled = info.isInternal || fileMonitor.exists(info.path)
        menu.addItem(showInFinder)
        menu.addItem(attachmentMenuItem("Copy Path", #selector(menuAttachmentCopyPath(_:)), ref))
        menu.addItem(
            attachmentMenuItem("Copy File Name", #selector(menuAttachmentCopyFileName(_:)), ref))

        menu.addItem(.separator())

        let readOnly = attachmentMenuItem(
            "Read Only", #selector(menuAttachmentToggleReadOnly(_:)), ref)
        readOnly.state = info.readOnly ? .on : .off
        readOnly.isEnabled = info.editable
        menu.addItem(readOnly)
        // Removable media offers both: Eject detaches with no confirmation
        // (file untouched); Remove… is the file-trashing path with its prompt.
        // Storage disks get Remove… only.
        if ref.kind == .removable {
            let eject = attachmentMenuItem("Eject", #selector(menuAttachmentEject(_:)), ref)
            eject.isEnabled = info.editable
            menu.addItem(eject)
        }
        let remove = attachmentMenuItem("Remove…", #selector(menuAttachmentRemove(_:)), ref)
        remove.isEnabled = info.editable
        menu.addItem(remove)

        return menu
    }

    private func attachmentMenuItem(_ title: String, _ action: Selector, _ ref: AttachmentRef)
        -> NSMenuItem
    {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = ref
        return item
    }

    private func attachmentRef(from sender: NSMenuItem) -> AttachmentRef? {
        sender.representedObject as? AttachmentRef
    }

    private func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    @objc private func menuAttachmentRename(_ sender: NSMenuItem) {
        guard let ref = attachmentRef(from: sender) else { return }
        attachmentRow(ref)?.beginRename()
    }

    @objc private func menuAttachmentShowInFinder(_ sender: NSMenuItem) {
        guard let ref = attachmentRef(from: sender), let info = attachmentInfo(ref) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([attachmentURL(info)])
    }

    @objc private func menuAttachmentCopyPath(_ sender: NSMenuItem) {
        guard let ref = attachmentRef(from: sender), let info = attachmentInfo(ref) else { return }
        copyToPasteboard(attachmentURL(info).path(percentEncoded: false))
    }

    @objc private func menuAttachmentCopyFileName(_ sender: NSMenuItem) {
        guard let ref = attachmentRef(from: sender), let info = attachmentInfo(ref) else { return }
        copyToPasteboard(attachmentURL(info).lastPathComponent)
    }

    @objc private func menuAttachmentToggleReadOnly(_ sender: NSMenuItem) {
        guard let ref = attachmentRef(from: sender), let info = attachmentInfo(ref) else { return }
        switch ref.kind {
        case .storage: setStorageReadOnly(!info.readOnly, forDiskID: ref.id)
        case .removable: setRemovableReadOnly(!info.readOnly, forItemID: ref.id)
        }
    }

    /// Context-menu "Eject" (removable media only): detach with no confirmation,
    /// sharing the inline button's `ejectRemovableMedia` path.
    @objc private func menuAttachmentEject(_ sender: NSMenuItem) {
        guard let ref = attachmentRef(from: sender), ref.kind == .removable else { return }
        ejectRemovableMedia(forItemID: ref.id)
    }

    @objc private func menuAttachmentRemove(_ sender: NSMenuItem) {
        guard let ref = attachmentRef(from: sender) else { return }
        switch ref.kind {
        case .storage: presentStorageDeleteConfirmation(forDiskID: ref.id)
        case .removable: presentRemovableDeleteConfirmation(forItemID: ref.id)
        }
    }

    @objc private func menuAttachmentGetInfo(_ sender: NSMenuItem) {
        guard let ref = attachmentRef(from: sender), let info = attachmentInfo(ref),
            let row = attachmentRow(ref)
        else { return }
        presentAttachmentInfoPopover(info, from: row.infoAnchor)
    }

    /// Get Info popover for either list.
    ///
    /// Reads the on-disk/allocated figures and creation date **off the main
    /// thread** — the file may live on a slow or sleeping external volume — then
    /// presents when they land.
    private func presentAttachmentInfoPopover(_ info: AttachmentInfo, from anchor: NSView) {
        let url = attachmentURL(info)
        let layout = instance.bundleLayout
        let path = info.path
        let isInternal = info.isInternal
        Task { [weak self] in
            let snapshot = await Task.detached {
                () -> (VMBundleLayout.DiskSizes, Date?) in
                let sizes = layout.diskSizes(forRelativePath: path, isInternal: isInternal)
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                return (sizes, created)
            }.value
            // Don't present onto a settings pane the user has navigated away from
            // while the off-main read was in flight (the VC is reused across
            // route changes, so `[weak self]` alone isn't enough).
            guard let self, !self.hasDisappeared else { return }
            let (sizes, created) = snapshot
            let content = AttachmentInfoPopoverContentViewController(
                label: info.label,
                fileName: url.lastPathComponent,
                fullPath: url.path(percentEncoded: false),
                onDiskText: sizes.onDiskBytes.map { DataFormatters.formatBytes($0) } ?? "—",
                allocatedText: sizes.capacityBytes.map { DataFormatters.formatBytes($0) } ?? "Unknown",
                readOnly: info.readOnly,
                busText: info.busText,
                createdText: created.map { Self.diskInfoDateFormatter.string(from: $0) } ?? "Unknown")
            self.attachmentInfoPresenter.show(content: content, from: anchor, preferredEdge: .minY)
        }
    }

    private static let diskInfoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Builds the per-row delete confirmation that ``attachmentDeletePrompt`` decided,
    /// wiring each action to `perform(trashFile:)` and appending Cancel.
    private func makeDeleteAlert(
        prompt: AttachmentDeletePrompt,
        perform: @escaping (_ trashFile: Bool) -> Void
    ) -> AlertConfiguration {
        var buttons: [AlertButton] = prompt.actions.map { action in
            switch action {
            case .moveToTrash:
                return AlertButton("Move to Trash", role: .destructive) { perform(true) }
            case .removeFromVM:
                return AlertButton("Remove from VM", role: .default) { perform(false) }
            }
        }
        buttons.append(AlertButton("Cancel", role: .cancel))
        return AlertConfiguration(title: prompt.title, message: prompt.message, buttons: buttons)
    }

    /// Decides the per-row delete confirmation (title, message, offered actions)
    /// purely from the item's nature, so it is unit-testable without a window.
    ///
    /// Mirrors the VM-delete sheet's rules: the Guest Agent installer and files
    /// shared with another VM can only be detached (never trashed); in-bundle
    /// disks are trashed-or-cancelled; private external files may be trashed or
    /// merely detached.
    static func attachmentDeletePrompt(
        label: String,
        isInternal: Bool,
        isMainDisk: Bool,
        isGuestAgent: Bool,
        sharedVMNames: [String]
    ) -> AttachmentDeletePrompt {
        let title = "Remove \u{201C}\(label)\u{201D}?"

        if isGuestAgent {
            return AttachmentDeletePrompt(
                title: title,
                message:
                    "Detaches the Guest Agent installer from this VM. It's part of Kernova, so the file isn't deleted.",
                actions: [.removeFromVM])
        }

        if !sharedVMNames.isEmpty {
            return AttachmentDeletePrompt(
                title: title,
                message:
                    "Detaches it from this VM. Its file is kept — still used by \(DataFormatters.quotedList(sharedVMNames)).",
                actions: [.removeFromVM])
        }

        if isInternal {
            let base = "Moves the disk image to the Trash. You can restore it with Finder's Put Back."
            return AttachmentDeletePrompt(
                title: title,
                message: isMainDisk
                    ? "\(base) This is the VM's startup disk — it won't boot without it."
                    : base,
                actions: [.moveToTrash])
        }

        return AttachmentDeletePrompt(
            title: title,
            message:
                "Move to Trash sends the file to the Trash. Remove from VM detaches it but keeps the file.",
            actions: [.moveToTrash, .removeFromVM])
    }

    // MARK: Removable

    @objc private func attachRemovableTapped() {
        let urls = NSOpenPanel.browseDiskImages(
            message: "Select disk images to attach to the VM", allowsMultipleSelection: true)
        guard !urls.isEmpty else { return }
        var current = currentRemovableMedia
        let existing = Set(current.map(\.path))
        for url in urls {
            let path = url.path(percentEncoded: false)
            guard !existing.contains(path) else { continue }
            current.append(RemovableMediaItem(path: path, readOnly: true))
        }
        writeRemovableMedia(current)
    }

    @objc private func createRemovableTapped() {
        guard let createRemovableButton else { return }
        removableMediaCoordinator.show(from: createRemovableButton)
    }

    @objc private func removableReadOnlyToggled(_ sender: NSSwitch) {
        guard let id = uuid(from: sender) else { return }
        setRemovableReadOnly(sender.state == .on, forItemID: id)
    }

    private func setRemovableReadOnly(_ readOnly: Bool, forItemID id: UUID) {
        var items = currentRemovableMedia
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].readOnly = readOnly
        writeRemovableMedia(items)
    }

    /// Ejects a removable medium from its inline trailing button.
    ///
    /// Detach only — no confirmation, backing file untouched. The file-trashing
    /// path with its confirmation is the context menu's "Remove…"; see
    /// ``presentRemovableDeleteConfirmation(forItemID:)``.
    @objc private func removableEjectTapped(_ sender: NSButton) {
        guard let id = uuid(from: sender) else { return }
        ejectRemovableMedia(forItemID: id)
    }

    /// Detaches a removable medium (removes its config entry, keeping the file).
    ///
    /// `removeRemovableMedia(_:from:trashFile:)` with `trashFile: false` removes
    /// the `removableMedia` entry — which the live reconcile hot-detaches from a
    /// running VM — and never touches the file. No alert: ejecting is the safe,
    /// reversible action (re-attach via "Attach Disk…").
    private func ejectRemovableMedia(forItemID id: UUID) {
        guard let item = currentRemovableMedia.first(where: { $0.id == id }) else { return }
        _ = viewModel.removeRemovableMedia(item, from: instance, trashFile: false)
    }

    private func presentRemovableDeleteConfirmation(forItemID id: UUID) {
        guard let window = view.window,
            let item = currentRemovableMedia.first(where: { $0.id == id })
        else { return }
        let isAgent = viewModel.isGuestAgentInstaller(item)
        let shared = isAgent ? [] : viewModel.sharingVMNames(forPath: item.path, excluding: instance)
        let prompt = Self.attachmentDeletePrompt(
            label: item.label,
            isInternal: false,
            isMainDisk: false,
            isGuestAgent: isAgent,
            sharedVMNames: shared)
        presentSheetAlert(
            makeDeleteAlert(prompt: prompt) { [weak self] trashFile in
                guard let self else { return }
                _ = self.viewModel.removeRemovableMedia(item, from: self.instance, trashFile: trashFile)
            },
            in: window)
    }

    // MARK: Shared

    @objc private func addSharedTapped() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Select directories to share with the VM"
        panel.prompt = "Share"
        guard panel.runModal() == .OK else { return }

        var current = currentSharedDirectories
        let existing = Set(current.map(\.path))
        for url in panel.urls {
            let path = url.path(percentEncoded: false)
            guard !existing.contains(path) else { continue }
            current.append(SharedDirectory(path: path))
        }
        writeSharedDirectories(current)
    }

    @objc private func sharedReadOnlyToggled(_ sender: NSSwitch) {
        guard let id = uuid(from: sender) else { return }
        var directories = currentSharedDirectories
        guard let index = directories.firstIndex(where: { $0.id == id }) else { return }
        directories[index].readOnly = sender.state == .on
        writeSharedDirectories(directories)
    }

    @objc private func sharedDeleteTapped(_ sender: NSButton) {
        guard let id = uuid(from: sender) else { return }
        var directories = currentSharedDirectories
        directories.removeAll { $0.id == id }
        writeSharedDirectories(directories)
    }

    private func presentRemovableSavePanel(sizeInGB: Int) {
        let panel = NSSavePanel()
        panel.title = "Save Removable Disk"
        panel.message = "Choose where to save the new removable disk image."
        panel.prompt = "Create"
        panel.nameFieldStringValue = "\(instance.name) Removable Disk.asif"
        panel.allowedContentTypes = [.asif]
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.viewModel.createRemovableMedia(for: self.instance, sizeInGB: sizeInGB, destinationURL: url)
        }
    }
}

// MARK: - NSTextFieldDelegate

extension VMSettingsViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        // Grow/shrink the name box with the live text so it stays snug.
        guard (obj.object as? NSTextField) === nameField else { return }
        let live = nameField.currentEditor()?.string ?? nameField.stringValue
        nameEditMaxWidth.constant = InlineRenameSizing.boxWidth(for: live, font: Typography.body)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        switch field {
        case nameField:
            // Gate on the local session flag, not the model marker: when this
            // surface's rename is superseded mid-handoff the marker has
            // already moved to the other surface, but the in-flight text must
            // still commit (mirrors the sidebar cell's local `isRenaming`
            // gate; the surface-scoped `commitRename` makes this safe).
            if nameRowIsEditing, !suppressNameEndEditingCommit {
                viewModel.commitRename(
                    for: instance, newName: nameField.stringValue, from: .detail)
            }
        case cpuField:
            applyCPUFieldEdit()
        case memoryField:
            applyMemoryFieldEdit()
        default:
            break
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === nameField else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // Resign instead of committing directly: the end-editing path is
            // the single commit path (gated on the local session flag), so
            // Return, outside clicks, and superseded teardowns all commit the
            // same way.
            view.window?.makeFirstResponder(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Clear the rename first, then end the field editor with the
            // commit suppressed so the resign can't write the live buffer.
            viewModel.cancelRename(for: instance, from: .detail)
            suppressNameEndEditingCommit = true
            view.window?.makeFirstResponder(nil)
            suppressNameEndEditingCommit = false
            return true
        }
        return false
    }

    private func applyCPUFieldEdit() {
        let os = instance.configuration.guestOS
        let clamped = Swift.min(Swift.max(cpuField.integerValue, os.minCPUCount), os.maxCPUCount)
        cpuField.integerValue = clamped
        cpuStepper.integerValue = clamped
        writeConfig { $0.cpuCount = clamped }
    }

    private func applyMemoryFieldEdit() {
        let os = instance.configuration.guestOS
        let clamped = Swift.min(Swift.max(memoryField.integerValue, os.minMemoryInGB), os.maxMemoryInGB)
        memoryField.integerValue = clamped
        memoryStepper.integerValue = clamped
        writeConfig { $0.memorySizeInGB = clamped }
    }
}

// MARK: - AttachmentDeletePrompt

/// The confirmation a per-row storage/removable delete should present.
///
/// Decided purely from the item's nature, so it is unit-testable without a
/// window. The trailing Cancel button is added by the presenter, not modeled
/// here.
struct AttachmentDeletePrompt: Equatable {
    /// A non-cancel action and the file disposition it implies.
    enum Action: Equatable {
        /// Remove the entry AND move its file to the Trash.
        case moveToTrash
        /// Remove the entry; leave the file in place.
        case removeFromVM
    }

    let title: String
    let message: String
    /// Offered actions in display order; the first is the default button.
    let actions: [Action]
}

// MARK: - StorageDiskReorderSheetContentViewControllerDelegate

extension VMSettingsViewController: StorageDiskReorderSheetContentViewControllerDelegate {
    func storageDiskReorderSheet(
        _ vc: StorageDiskReorderSheetContentViewController, didReorderTo disks: [StorageDisk]
    ) {
        writeStorageDisks(disks)
    }

    func storageDiskReorderSheetDidDismiss(_ vc: StorageDiskReorderSheetContentViewController) {
        reorderSheetPresenter.close()
    }
}
