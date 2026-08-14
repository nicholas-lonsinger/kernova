import AVFoundation
import AppKit
import UniformTypeIdentifiers
import Virtualization
import os

/// Pure-AppKit settings pane for editing a stopped VM's configuration, or
/// viewing a running VM's configuration in read-only mode.
///
/// Structure that depends on the *instance* (guest-agent section visibility,
/// OS-specific help text) is fixed per instance and built in ``buildForm()``;
/// switching VMs rebuilds the form. ``apply()`` only updates
/// mutable state: control values, lock/enabled state, the dynamic attachment
/// lists, and the microphone permission warning.
@MainActor
final class VMSettingsViewController: NSViewController {
    private static let logger = Logger(
        subsystem: "app.kernova", category: "VMSettingsViewController")

    private(set) var instance: VMInstance
    private var viewModel: VMLibraryViewModel
    private var isReadOnly: Bool

    /// Host interfaces offered by the Network section's Mode picker.
    private let bridgedInterfaces: any BridgedInterfaceProviding
    /// Decides whether the picker offers Bridged at all.
    private let entitlements: EntitlementService

    private let vmnetNetworks: any VmnetNetworkProviding

    // MARK: - Observation & live state

    private let fileMonitor = AttachmentFileMonitor()
    /// Flashes the form's scroller once when its content overflows the viewport,
    /// signaling there's more below.
    private var scrollMoreIndicator: ScrollMoreIndicator?
    private var modelObservation: ObservationLoop?
    private var hasDisappeared = false
    /// Identifies the current file-monitor observation cycle.
    ///
    /// A new token is minted each `viewDidAppear`; a re-arming callback from an
    /// older cycle (which `hasDisappeared` alone can't cancel —
    /// `withObservationTracking` has no unregister) bails when its token no
    /// longer matches, so stale chains can't accumulate.
    private var fileMonitorObservationToken: UUID?
    private var micPermission: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    // MARK: - Presenters & coordinators

    private let reorderSheetPresenter = SheetPresenter()
    private let portForwardingSheetPresenter = SheetPresenter()
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
    /// The "Installed From" row and its value label, hidden while the VM
    /// carries no record of the image it was set up from.
    private var installedImageRow: GroupedFormCollapsibleRow?
    private var installedImageValueLabel: NSTextField?
    /// The OS Version row and its value label, hidden until an agent reports
    /// one; both `nil` for Linux guests, which have no agent to report one.
    private var guestOSVersionRow: GroupedFormCollapsibleRow?
    private var guestOSVersionValueLabel: NSTextField?
    private var nameDisplayRow = NSView()
    private var nameEditRow = NSView()
    private var nameRowIsEditing = false
    /// Suppresses the end-editing commit while a path that already settled the
    /// rename (Escape's cancel) resigns the field editor.
    private var suppressNameEndEditingCommit = false
    /// Caps the name edit box at its text width so it hugs the name and grows as
    /// you type (right-aligned, the leading spacer absorbs the slack).
    ///
    /// A `<=` bound, not `==`, so a name wider than the form scrolls instead of
    /// stretching the window. Created once for the lifetime of the reused
    /// `nameField`, *not* per `buildForm()`: the constraint lives on the field,
    /// so a copy minted on every instance swap outlives its build cycle — the
    /// caps accumulate and the smallest constant wins.
    private lazy var nameEditMaxWidth: NSLayoutConstraint = {
        let constraint = nameField.widthAnchor.constraint(lessThanOrEqualToConstant: 0)
        constraint.priority = .defaultHigh
        return constraint
    }()
    /// Active only while renaming: ends the edit on a click outside the name field.
    ///
    /// Resigns the field editor (committing the current text) — AppKit doesn't end
    /// field editing when a click lands on the settings card's non-focusable
    /// space, so without this the box would linger.
    private var nameOutsideClickMonitor: Any?

    // Resources
    private var cpuField = NSTextField()
    private var cpuStepper = NSStepper()
    private var memoryField = NSTextField()
    private var memoryStepper = NSStepper()

    // Display
    private var displayMatchWindowSwitch = NSSwitch()
    private var displayResolutionPopUp = NSPopUpButton()
    private var displayWidthField = NSTextField()
    private var displayHeightField = NSTextField()
    private var displayHiDPISwitch = NSSwitch()
    private var displayAutoResizeSwitch = NSSwitch()
    /// Caption naming the resolution the guest will boot at.
    private var displayResolutionCaption = NSTextField()
    /// Orange "takes effect on next start" caption, shown only while read-only.
    private var displayRestartCaption = NSTextField()
    /// Set while the user has explicitly chosen Custom, so the popup doesn't
    /// snap back to a preset the current size happens to match.
    private var displayResolutionIsCustom = false

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
    /// While set, `refreshStorageList` skips its rebuild so an async refresh
    /// landing mid-edit can't destroy the editing field.
    private var activeStorageRename: UUID?

    // Removable Media
    private var removableListStack = NSStackView()
    private var createRemovableButton: NSButton?
    /// Live removable-media row views keyed by item id.
    private var removableRowsByID: [UUID: AttachmentRowView] = [:]
    /// The removable medium being renamed inline, or `nil`; suppresses
    /// `refreshRemovableList` mid-edit.
    private var activeRemovableRename: UUID?

    // Shared Directories
    private var sharedListStack = NSStackView()

    // Network
    private var networkModePopUp = NSPopUpButton()
    /// The Network header's lock icon, hidden — unlike its `lockIcons` peers —
    /// while the picker is the live-switch surface.
    private var networkLockIcon: NSImageView?
    /// The MAC Address row, hidden while the VM has no network device or has
    /// yet to be given an address.
    private var macAddressRow: GroupedFormCollapsibleRow?
    private var macAddressField = NSTextField()
    private var ipAddressRow: GroupedFormCollapsibleRow?
    private var ipAddressValueLabel: NSTextField?
    private var ipAddressCopyButton: NSButton?
    /// What the copy button copies — the reserved address, `nil` while the
    /// row shows anything else.
    private var ipAddressCopyValue: String?
    private var ipAddressMaterializeTask: Task<Void, Never>?
    /// The Port Forwarding block — the rule rows and the Add Rule row — hidden
    /// wherever forwarding cannot apply.
    private var portForwardingRow: GroupedFormCollapsibleRow?
    /// Holds the rule rows and the trailing Add Rule row, rebuilt on change.
    private var portForwardingListStack = NSStackView()
    /// Stands in for the card's rows while the mode is None.
    private var networkNoDeviceCaption = NSTextField()
    /// Holds the banner naming the other VMs sharing this one's MAC address.
    private var networkWarningContainer = NSStackView()

    // Audio
    private var audioInputSwitch = NSSwitch()
    private var audioOutputSwitch = NSSwitch()
    private var audioWarningContainer = NSStackView()

    // Input devices (macOS guests only)
    private var inputDevicesPopUp = NSPopUpButton()

    // Guest Agent
    private var logForwardingSwitch = NSSwitch()
    private var installReminderSwitch = NSSwitch()
    /// The install-reminder row's title label, retained so `refreshGuestAgent`
    /// can gray it in step with the switch.
    private var installReminderLabel = NSTextField()
    /// Explains the disabled install-reminder row while the prompt is off
    /// app-wide; hidden otherwise.
    private var installReminderOverrideCaption = NSView()

    // Clipboard
    private var clipboardSwitch = NSSwitch()
    private var clipboardPassthroughSwitch = NSSwitch()
    /// The passthrough row's title label, retained so `refreshClipboard` can gray
    /// it in step with the switch.
    private var clipboardPassthroughLabel = NSTextField()
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
    /// Value snapshot of the Port Forwarding rows' rendered appearance.
    private struct RenderedPortForwardingRows: Equatable {
        let rules: [PortForwardingRule]
        let controlsEnabled: Bool
    }
    private var renderedStorageRows: [RenderedRow]?
    private var renderedRemovableRows: [RenderedRow]?
    private var renderedSharedRows: [RenderedRow]?
    private var renderedAudioWarning: MicWarningState?
    /// The duplicate-MAC banner's rendered message, `nil` when no banner is
    /// shown, so a pass that changed nothing about it skips the rebuild.
    private var renderedNetworkMACWarning: String?
    /// The Mode menu's rendered selection, so an `apply()` pass that changed
    /// nothing about networking skips a rebuild — which enumerates the host's
    /// bridgeable interfaces and queries the process signature.
    private var renderedNetworkChoice: NetworkModeChoice?
    /// The rules (and lock state) the Port Forwarding rows were last built for,
    /// so a rebuild happens exactly when one of them changed.
    private var renderedPortForwardingRows: RenderedPortForwardingRows?
    /// The live-switch state the Mode menu was last built for; a change rebuilds
    /// so the None entry's enablement tracks it.
    private var renderedNetworkLiveSwitchable = false

    // MARK: - Init

    init(
        instance: VMInstance,
        viewModel: VMLibraryViewModel,
        isReadOnly: Bool,
        bridgedInterfaces: any BridgedInterfaceProviding = HostBridgedInterfaceProvider(),
        entitlements: EntitlementService = .shared,
        vmnetNetworks: any VmnetNetworkProviding = VmnetNetworkService.shared
    ) {
        self.instance = instance
        self.viewModel = viewModel
        self.isReadOnly = isReadOnly
        self.bridgedInterfaces = bridgedInterfaces
        self.entitlements = entitlements
        self.vmnetNetworks = vmnetNetworks
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
            // Re-arm the model observation on the new instance: it is one-shot and
            // re-registers only after it fires, so otherwise the loop stays bound
            // to the previous instance. Only restart when already observing;
            // creating it here early would skip the notification observer.
            if modelObservation != nil {
                restartModelObservation()
            }
        }
        apply()

        if instanceChanged {
            // The indicator is reused across VM switches, so without this re-arm
            // only the first overflowing pane in a session would flash. Force
            // layout so overflow is measured on the new form's real height.
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

        // Flash-only (no chevron/fade overlays): the root is an `NSStackView`,
        // which shouldn't host unmanaged overlay subviews.
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
                _ = self.viewModel.agentInstallPromptDisabled
                // Registers every instance's configuration, so the
                // duplicate-MAC banner follows a change made on the *other*
                // holder, and library membership changing under it.
                _ = self.viewModel.vmNamesSharingMACAddress(with: self.instance)
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
        if portForwardingSheetPresenter.isShown { portForwardingSheetPresenter.close() }
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
        // `viewDidDisappear` without `viewWillDisappear`.
        removeNameOutsideClickMonitor()
    }

    /// Seeds the file monitor with the current instance's attachment paths.
    private func startInstanceSideEffects() {
        let refs = externalAttachmentRefs(for: instance.configuration)
        Task { await fileMonitor.setPaths(refs) }
    }

    /// Re-arming `withObservationTracking` on `fileMonitor.existsByPath`, so the
    /// missing-file affordance on attachment rows updates live.
    ///
    /// The `hasDisappeared` guard breaks the chain on dismissal, and the `token`
    /// makes a callback from a prior appear cycle bail.
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

    // MARK: - Read accessors (materialize defaults)

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

    /// - Returns: Whether the mutation was applied, so a caller whose control
    ///   already moved can put it back when the view model refused.
    @discardableResult
    private func writeConfig(_ mutate: (inout VMConfiguration) -> Void) -> Bool {
        viewModel.updateConfiguration(of: instance, mutate: mutate)
    }
}

// MARK: - Form construction (per-instance structure)

extension VMSettingsViewController {
    /// Rebuilds the whole form for the current instance.
    ///
    /// Called on first load and whenever the bound instance changes.
    private func buildForm() {
        formStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        lockIcons.removeAll()
        persistentLockableControls.removeAll()
        nameRowIsEditing = false
        activeStorageRename = nil
        activeRemovableRename = nil
        storageRowsByID.removeAll()
        removableRowsByID.removeAll()
        // The list stacks, audio-warning container, and Mode popup are recreated
        // below, so invalidate the render snapshots that guard their refreshes.
        renderedStorageRows = nil
        renderedRemovableRows = nil
        renderedSharedRows = nil
        renderedAudioWarning = nil
        renderedNetworkMACWarning = nil
        renderedNetworkChoice = nil
        renderedPortForwardingRows = nil

        displayResolutionIsCustom = false

        addSection(buildGeneralSection())
        addSection(buildResourcesSection())
        addSection(buildDisplaySection())
        addSection(buildStorageSection())
        addSection(buildRemovableMediaSection())
        addSection(buildSharedDirectoriesSection())
        addSection(buildNetworkSection())
        addSection(buildAudioSection())
        if instance.configuration.guestOS == .macOS {
            addSection(buildInputDevicesSection())
        }
        if isGuestAgentSectionVisible(guestOS: instance.configuration.guestOS) {
            // macOS: clipboard rides the agent's vsock channel, so it nests in
            // the agent group rather than forming a sibling section.
            addSection(buildGuestAgentSection())
        } else {
            // Linux: clipboard is SPICE-based, so it stands alone.
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

    /// Section header; any lock icon it creates is registered in ``lockIcons``
    /// and toggled by ``apply()``. A section whose lock is conditional passes
    /// `lockIconSink` to keep its own reference — by handoff, not by position
    /// in ``lockIcons``.
    private func makeHeader(
        _ title: String, lockable: Bool = false, paragraphs: [InfoPopoverParagraph] = [],
        lockIconSink: ((NSImageView) -> Void)? = nil
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
            lockIconSink?(lock)
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
            // Buffer below the banner so it doesn't crowd the first section title.
            banner.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Spacing.section),
            banner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            banner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
        ])
        return container
    }

    // MARK: General

    /// What the install-record row is called for `guestOS`.
    ///
    /// A macOS install ran to completion under Kernova, so its row names the
    /// version the VM started life at, sitting beside the "OS Version" row that
    /// names what the guest reports today. A Linux ISO is only attached for the
    /// distribution's own installer to use — which can install something else,
    /// or nothing — so that row names the media and claims nothing about the
    /// outcome.
    static func installedImageRowLabel(guestOS: VMGuestOS) -> String {
        guestOS == .macOS ? "Installed Version" : "Installer Image"
    }

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
        // `nameEditMaxWidth` caps it at the text width. Hug is one step below the
        // spacer's so the field claims the slack first; compression is low so it
        // yields (scrolls) rather than pushes.
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

        var rows: [NSView] = [
            nameRow,
            makeGroupedFormCardRow(
                "Type", control: makeGroupedFormValueLabel(instance.configuration.guestOS.displayName)),
        ]
        // Both OS rows are built whatever the VM knows today, then hidden until
        // it knows: an install completing or a first agent Hello fills one in
        // while this pane is on screen, and only `apply()` runs then.
        let installedImage = instance.configuration.installedImage?.displayName
        let installedLabel = makeGroupedFormValueLabel(installedImage ?? "")
        installedImageValueLabel = installedLabel
        let installedRow = GroupedFormCollapsibleRow(
            row: makeGroupedFormCardRow(
                Self.installedImageRowLabel(guestOS: instance.configuration.guestOS),
                control: installedLabel))
        installedRow.isHidden = installedImage == nil
        installedImageRow = installedRow
        rows.append(installedRow)

        if instance.configuration.guestOS == .macOS {
            let reported = instance.guestOSVersionDisplay
            let versionLabel = makeGroupedFormValueLabel(reported ?? "")
            guestOSVersionValueLabel = versionLabel
            let versionRow = GroupedFormCollapsibleRow(
                row: makeGroupedFormCardRow("OS Version", control: versionLabel))
            versionRow.isHidden = reported == nil
            guestOSVersionRow = versionRow
            rows.append(versionRow)
        } else {
            guestOSVersionValueLabel = nil
            guestOSVersionRow = nil
        }
        rows += [
            makeGroupedFormCardRow(
                "Boot Mode", control: makeGroupedFormValueLabel(instance.configuration.bootMode.displayName)),
            makeGroupedFormCardRow(
                "Created",
                control: makeGroupedFormValueLabel(
                    instance.configuration.createdAt.formatted(date: .abbreviated, time: .shortened))),
        ]
        return makeSection([makeHeader("General"), makeGroupedFormCard(rows: rows)])
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

    // MARK: Display

    /// A base ("looks like") size offered by the Resolution popup, carried by its
    /// menu item as the item's `representedObject`.
    private struct DisplayResolutionPreset: Equatable {
        let width: Int
        let height: Int
    }

    private static let displayResolutionPresets: [DisplayResolutionPreset] = [
        .init(width: 1280, height: 800), .init(width: 1440, height: 900),
        .init(width: 1680, height: 1050), .init(width: 1920, height: 1080),
        .init(width: 1920, height: 1200), .init(width: 2560, height: 1440),
        .init(width: 2560, height: 1600),
    ]

    /// The one item carrying no preset, selected for any size off the list.
    private static let displayCustomTitle = "Custom"

    private func buildDisplaySection() -> NSView {
        let isMacOS = instance.configuration.guestOS == .macOS
        let supportsDensity = instance.configuration.guestOS.supportsDisplayDensity
        displayMatchWindowSwitch = makeSwitch(action: #selector(displayMatchWindowToggled))
        displayResolutionPopUp = makeDisplayResolutionPopUp()
        displayWidthField = makeDisplaySizeField()
        displayHeightField = makeDisplaySizeField()
        displayHiDPISwitch = makeSwitch(action: #selector(displayHiDPIToggled))
        displayAutoResizeSwitch = makeSwitch(action: #selector(displayAutoResizeToggled))
        persistentLockableControls += [
            displayMatchWindowSwitch, displayResolutionPopUp, displayWidthField, displayHeightField,
        ]

        var rows: [NSView] = [
            // Deliberately outside `persistentLockableControls`: the flag lives on
            // the display view, so it is legal to flip while the VM runs.
            makeToggleRowWithInfo(
                "Automatically resize with window", control: displayAutoResizeSwitch,
                paragraphs: Self.displayAutoResizeInfo(isMacOS: isMacOS)),
            makeToggleRowWithInfo(
                "Size display to fit window at startup", control: displayMatchWindowSwitch,
                paragraphs: [
                    .body(
                        "Each cold start sizes the guest display to the window or screen it opens in, so the picture fills it without scaling."
                    ),
                    .body(
                        "A VM resumed from saved state keeps the resolution it was saved with — VZ restores only into the configuration it was suspended from."
                    ),
                ]),
            makeGroupedFormCardRow("Resolution", control: displayResolutionPopUp),
            makeGroupedFormCardRow("Width", control: displayWidthField),
            makeGroupedFormCardRow("Height", control: displayHeightField),
        ]
        if supportsDensity {
            persistentLockableControls.append(displayHiDPISwitch)
            rows.append(
                makeToggleRowWithInfo(
                    "HiDPI (Retina)", control: displayHiDPISwitch,
                    paragraphs: [
                        .body(
                            "Doubles the pixel count and raises the reported pixel density, so the guest renders Retina-sharp at the size above."
                        ),
                        .body(
                            "While the display is sized to fit the window, it fills the window at your screen's Retina scale instead of 1×."
                        ),
                    ]))
        }
        displayResolutionCaption = makeGroupedFormCaption("")
        let restart = makeGroupedFormCaption("Takes effect on next start.")
        restart.textColor = .systemOrange
        restart.isHidden = true
        displayRestartCaption = restart

        return makeSection([
            makeHeader("Display", lockable: true),
            makeGroupedFormCard(rows: rows),
            displayResolutionCaption,
            displayRestartCaption,
        ])
    }

    /// Info copy for the auto-resize row, whose consequences differ by guest OS.
    private static func displayAutoResizeInfo(isMacOS: Bool) -> [InfoPopoverParagraph] {
        if isMacOS {
            return [
                .body(
                    "Lets the guest change its own resolution to match the window as you resize it, instead of scaling the boot resolution. Requires macOS 14 or later in the guest — earlier guests keep the resolution set at startup and scale it to fit."
                ),
                .body("Takes effect immediately, including while the VM is running."),
            ]
        }
        return [
            .body(
                "Lets the guest change its own resolution to match the window as you resize it. Some guests may reset certain display settings (such as the scaling factor) whenever the resolution changes."
            ),
            .body("Takes effect immediately, including while the VM is running."),
        ]
    }

    private func makeDisplayResolutionPopUp() -> NSPopUpButton {
        let popUp = NSPopUpButton()
        popUp.controlSize = .small
        for preset in Self.displayResolutionPresets {
            popUp.addItem(withTitle: "\(preset.width) × \(preset.height)")
            popUp.lastItem?.representedObject = preset
        }
        popUp.menu?.addItem(.separator())
        popUp.addItem(withTitle: Self.displayCustomTitle)
        popUp.target = self
        popUp.action = #selector(displayResolutionChanged)
        return popUp
    }

    private func makeDisplaySizeField() -> NSTextField {
        let field = NSTextField()
        field.alignment = .right
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: 64).isActive = true
        return field
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

    /// What a Mode menu item selects, carried as the item's `representedObject`.
    ///
    /// `bridged`'s payload is the host interface identifier, `nil` for Automatic.
    private enum NetworkModeChoice: Equatable {
        case shared
        case hostOnly
        case none
        case bridged(String?)
    }

    private func buildNetworkSection() -> NSView {
        // Deliberately outside `persistentLockableControls`: the picker is the
        // live-switch surface while the VM runs, so `refreshNetwork()` owns its
        // enablement (and the section lock icon it makes moot).
        networkModePopUp = makeNetworkModePopUp()

        var rows: [NSView] = [makeGroupedFormCardRow("Mode", control: networkModePopUp)]
        rows.append(makeIPAddressRow())
        rows.append(makeMACAddressRow())
        rows.append(makePortForwardingRow())
        networkNoDeviceCaption = makeGroupedFormCaption("This virtual machine has no network device.")
        networkWarningContainer = NSStackView()
        networkWarningContainer.orientation = .vertical
        networkWarningContainer.alignment = .leading
        networkWarningContainer.spacing = Spacing.small
        networkWarningContainer.translatesAutoresizingMaskIntoConstraints = false

        // With the entitlement, Shared and Host Only assign each guest a
        // deterministic address the IP Address row shows, and Shared can forward
        // host ports to it; without it there is neither, so the copy concedes
        // the gap instead.
        let sharedReachClause =
            entitlements.hasVMNetworking
            ? "other machines on your network reach it only on the ports you forward, and this Mac reaches it at the address in the IP Address row"
            : "there is no port forwarding from host to guest — incoming connections require knowing the guest's IP"
        var paragraphs: [InfoPopoverParagraph] = [
            .body(
                "The mode sets how the guest reaches the network. Shared Network gives it outbound access through the host: the guest gets a DHCP address on a private subnet, other machines on your network cannot reach it, and \(sharedReachClause). Host Only puts the guest on a private network reachable only from this Mac: it can talk to the host and to other Host Only guests, with no access to your network or the internet. Bridged puts the guest on your network through the chosen host interface, where it requests its own address like a separate machine."
            ),
            .body(
                "Bridged traffic bypasses a VPN running on the host. Bridging over Wi-Fi is best-effort — the Wi-Fi standard does not bridge additional stations and there is no client-side fix, so prefer a wired interface."
            ),
        ]
        if entitlements.hasVMNetworking {
            paragraphs.append(
                .body(
                    "A forwarded port is reachable from other devices on your network. Rule changes take effect the next time a Shared Network virtual machine starts."
                ))
            if #unavailable(macOS 27) {
                paragraphs.append(
                    .body(
                        "On this version of macOS a forwarded port is not reachable from this Mac itself through localhost. Apple documents this as a known limitation of vmnet."
                    ))
            }
        }
        if instance.configuration.guestOS == .linux {
            paragraphs.append(
                .body(
                    "The interface usually appears as `enp0s1`. If networking doesn't come up, make sure your distro's DHCP client or NetworkManager is running."
                ))
        }
        let header = makeHeader("Network", lockable: true, paragraphs: paragraphs) {
            self.networkLockIcon = $0
        }
        return makeSection([
            header,
            makeGroupedFormCard(rows: rows),
            networkWarningContainer,
            networkNoDeviceCaption,
        ])
    }

    /// The IP Address row: the reserved address with a copy affordance for
    /// the modes the app assigns addressing in, "Assigned by your network"
    /// for Bridged (external DHCP — nothing deterministic to show).
    /// `refreshIPAddressRow()` owns its content and visibility.
    private func makeIPAddressRow() -> GroupedFormCollapsibleRow {
        let value = makeGroupedFormValueLabel("")
        ipAddressValueLabel = value

        let copy = NSButton()
        copy.image = .systemSymbol("doc.on.doc", accessibilityDescription: "Copy IP Address")
        copy.imagePosition = .imageOnly
        copy.isBordered = false
        copy.contentTintColor = .secondaryLabelColor
        copy.toolTip = "Copy IP Address"
        copy.target = self
        copy.action = #selector(copyIPAddressTapped)
        ipAddressCopyButton = copy

        let control = NSStackView(views: [value, copy])
        control.orientation = .horizontal
        control.spacing = Spacing.tight
        let row = GroupedFormCollapsibleRow(
            row: makeGroupedFormCardRow("IP Address", control: control))
        ipAddressRow = row
        return row
    }

    /// Renders the IP Address row for the current mode, kicking a
    /// materialization when the address is not yet derivable — the network's
    /// addressing is only known once it has materialized, and the reservation
    /// is meant to be shown even while the VM is stopped.
    private func refreshIPAddressRow() {
        let config = instance.configuration
        guard config.networkEnabled else {
            ipAddressRow?.isHidden = true
            return
        }

        let mode = config.networkMode
        ipAddressCopyValue = nil
        switch mode {
        case .bridged:
            ipAddressRow?.isHidden = false
            ipAddressCopyButton?.isHidden = true
            ipAddressValueLabel?.stringValue = "Assigned by your network"
        case .shared, .hostOnly:
            guard entitlements.hasVMNetworking, let mac = config.macAddress,
                let kind = VmnetNetworkKind(mode: mode)
            else {
                // Without the entitlement (or a MAC to key on) there is no
                // reservation machinery behind the row — absence over a
                // visible-but-empty control.
                ipAddressRow?.isHidden = true
                return
            }
            ipAddressRow?.isHidden = false
            vmnetNetworks.reserveAddressIfNeeded(for: mac, kind: kind)
            if let address = vmnetNetworks.reservedAddress(for: mac, kind: kind) {
                ipAddressCopyValue = address
                ipAddressCopyButton?.isHidden = false
                ipAddressValueLabel?.stringValue = address
            } else {
                ipAddressCopyButton?.isHidden = true
                ipAddressValueLabel?.stringValue = "—"
                materializeForIPAddressDisplay(kind)
            }
        }
    }

    /// Materializes `kind`'s network off-main so the pending IP Address row
    /// can fill in; re-renders on success. Single-flight — every refresh of a
    /// still-pending row lands here, and one materialization serves them all.
    private func materializeForIPAddressDisplay(_ kind: VmnetNetworkKind) {
        guard ipAddressMaterializeTask == nil else { return }
        let networks = vmnetNetworks
        ipAddressMaterializeTask = Task { [weak self] in
            let materialized = await networks.materializeNetwork(for: kind)
            // Re-render before clearing the single-flight token: a slot the
            // materialized network can't serve (subnet capacity, pending
            // reservation) leaves the address underivable, and re-arming from
            // that refresh would spin materialize→refresh forever.
            if materialized { self?.refreshIPAddressRow() }
            self?.ipAddressMaterializeTask = nil
        }
    }

    #if DEBUG
    /// The in-flight IP-row materialization, for event-driven test waits.
    var ipAddressMaterializeTaskForTesting: Task<Void, Never>? { ipAddressMaterializeTask }
    #endif

    @objc private func copyIPAddressTapped() {
        guard let value = ipAddressCopyValue else { return }
        copyToPasteboard(value)
    }

    // MARK: MAC Address

    /// The MAC Address row: an editable, VZ-validated field and a Generate
    /// button. `refreshMACAddressRow()` owns its content and visibility.
    private func makeMACAddressRow() -> GroupedFormCollapsibleRow {
        macAddressField = NSTextField()
        macAddressField.alignment = .right
        macAddressField.delegate = self
        macAddressField.toolTip =
            "Six pairs of hexadecimal digits separated by colons, for example 3a:5f:20:11:88:c4."
        macAddressField.widthAnchor.constraint(equalToConstant: 140).isActive = true

        let generate = makePushButton("Generate", action: #selector(generateMACAddressTapped))
        generate.controlSize = .small
        // Unlike the Mode picker above it, the address is read once at start and
        // fixed for the session, so both controls lock with the section.
        persistentLockableControls += [macAddressField, generate]

        let control = NSStackView(views: [macAddressField, generate])
        control.orientation = .horizontal
        control.alignment = .centerY
        control.spacing = Spacing.tight
        let row = GroupedFormCollapsibleRow(
            row: makeGroupedFormCardRow("MAC Address", control: control))
        macAddressRow = row
        return row
    }

    private func refreshMACAddressRow() {
        let config = instance.configuration
        let hidden = !config.networkEnabled || config.macAddress == nil
        // End an open editor before the row goes: AppKit doesn't resign a
        // hidden field, so the mode picker — which takes no first responder of
        // its own — would leave it focused and invisible, swallowing keystrokes.
        if hidden, macAddressField.currentEditor() != nil {
            view.window?.makeFirstResponder(nil)
        }
        macAddressRow?.isHidden = hidden
        // A field with an open editor is mid-edit: any refresh — a status change
        // started from the toolbar, say — would otherwise discard the keystrokes
        // typed so far.
        if macAddressField.currentEditor() == nil {
            macAddressField.stringValue = instance.configuration.macAddress ?? ""
        }
    }

    // MARK: Port Forwarding

    /// The Port Forwarding block: a title, one row per rule, and the trailing
    /// Add Rule row. `refreshPortForwardingRows()` owns its contents;
    /// `refreshNetwork()` owns its visibility.
    private func makePortForwardingRow() -> GroupedFormCollapsibleRow {
        let title = NSTextField(labelWithString: "Port Forwarding")
        title.font = Typography.body
        title.isSelectable = false

        portForwardingListStack = makeListStack()
        portForwardingListStack.spacing = Spacing.small

        let content = NSStackView(views: [title, portForwardingListStack])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = Spacing.small
        content.translatesAutoresizingMaskIntoConstraints = false
        portForwardingListStack.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        let row = GroupedFormCollapsibleRow(row: content)
        portForwardingRow = row
        return row
    }

    /// Rebuilds the rule rows when the rules — or the lock state their controls
    /// carry — changed.
    private func refreshPortForwardingRows() {
        let rendered = RenderedPortForwardingRows(
            rules: instance.configuration.portForwardingRules, controlsEnabled: !isReadOnly)
        guard rendered != renderedPortForwardingRows else { return }
        renderedPortForwardingRows = rendered
        clear(portForwardingListStack)
        for (index, rule) in rendered.rules.enumerated() {
            addFullWidth(
                makePortForwardingRuleRow(rule, index: index, enabled: rendered.controlsEnabled),
                to: portForwardingListStack)
        }
        addFullWidth(
            makeAddPortForwardingRuleRow(enabled: rendered.controlsEnabled),
            to: portForwardingListStack)
    }

    /// How one rule's ports read in the card — the guest side of the arrow is
    /// where traffic lands.
    private static func portForwardingRuleText(_ rule: PortForwardingRule) -> String {
        "Host \(rule.hostPort) → Guest \(rule.guestPort)"
    }

    private func makePortForwardingRuleRow(
        _ rule: PortForwardingRule, index: Int, enabled: Bool
    ) -> NSView {
        let transport = NSTextField(labelWithString: rule.transport.displayName)
        transport.font = Typography.body
        transport.textColor = .secondaryLabelColor
        transport.isSelectable = false
        transport.setContentHuggingPriority(.required, for: .horizontal)
        transport.widthAnchor.constraint(equalToConstant: 38).isActive = true

        let ports = NSTextField(labelWithString: Self.portForwardingRuleText(rule))
        ports.font = Typography.body
        ports.isSelectable = false
        ports.lineBreakMode = .byTruncatingTail

        let remove = NSButton()
        remove.image = .systemSymbol("minus.circle", accessibilityDescription: "Remove Rule")
        remove.imagePosition = .imageOnly
        remove.isBordered = false
        remove.contentTintColor = .secondaryLabelColor
        remove.toolTip = "Remove Rule"
        remove.isEnabled = enabled
        remove.tag = index
        remove.target = self
        remove.action = #selector(removePortForwardingRuleTapped)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [transport, ports, spacer, remove])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Spacing.standard
        return row
    }

    private func makeAddPortForwardingRuleRow(enabled: Bool) -> NSView {
        let add = NSButton(
            title: "Add Rule…", target: self, action: #selector(addPortForwardingRuleTapped))
        add.image = .systemSymbol("plus.circle", accessibilityDescription: "")
        add.imagePosition = .imageLeading
        add.isBordered = false
        add.bezelStyle = .badge
        add.contentTintColor = .controlAccentColor
        add.isEnabled = enabled
        add.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [add, spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Spacing.standard
        return row
    }

    /// Every (transport, host port) pair any VM in the library claims.
    ///
    /// The claim is held by the persisted configuration, not by the mode: a rule
    /// survives a switch away from Shared Network and takes its host port back
    /// on the way in, so a VM in another mode counts too — otherwise two VMs end
    /// up holding the same port and one of them silently stops forwarding.
    private func takenHostPortClaims() -> Set<PortForwardingHostClaim> {
        var claims = Set(instance.configuration.portForwardingRules.map(\.hostClaim))
        for other in viewModel.instances where other.id != instance.id {
            claims.formUnion(other.configuration.portForwardingRules.map(\.hostClaim))
        }
        return claims
    }

    #if DEBUG
    /// The claim set the Add Rule sheet is built with, for tests.
    var takenHostPortClaimsForTesting: Set<PortForwardingHostClaim> { takenHostPortClaims() }
    #endif

    private func writePortForwardingRules(_ rules: [PortForwardingRule]) {
        viewModel.updateConfiguration(of: instance) { $0.portForwardingRules = rules }
        // The rows are built from the configuration, so re-render with the
        // write rather than waiting for the model-observation pass.
        refreshPortForwardingRows()
    }

    /// While the pane is read-only, whether the Mode picker stays live as the
    /// hot-swap surface: swapping the attachment needs a running or live-paused
    /// session and a network device to swap on — None-mode VMs have no device,
    /// and devices cannot be added or removed at runtime.
    private var networkModeIsLiveSwitchable: Bool {
        guard isReadOnly else { return false }
        return instance.configuration.networkEnabled
            && (instance.status == .running || instance.isLivePaused)
    }

    private func makeNetworkModePopUp() -> NSPopUpButton {
        let popUp = NSPopUpButton()
        popUp.controlSize = .small
        // Otherwise AppKit re-derives each item's enabled state on every event,
        // undoing the deliberately-disabled entries below.
        popUp.autoenablesItems = false
        popUp.target = self
        popUp.action = #selector(networkModeChanged)
        popUp.menu?.delegate = self
        return popUp
    }

    /// Rebuilds the Mode menu and selects the entry matching the configuration.
    ///
    /// The bridgeable-interface list is live host state, so the menu is rebuilt
    /// from scratch each time it opens rather than cached at build time.
    private func rebuildNetworkModeMenu() {
        guard let menu = networkModePopUp.menu else { return }
        menu.removeAllItems()
        let liveSwitchable = networkModeIsLiveSwitchable
        let current = currentNetworkChoice
        addNetworkModeItem("Shared Network", choice: .shared, to: menu)
        if entitlements.hasVMNetworking {
            addNetworkModeItem("Host Only", choice: .hostOnly, to: menu)
        } else if current == .hostOnly {
            // A host-only VM in a build the entitlement doesn't cover: the
            // picker offers no Host Only entry, so this one shows the mode
            // without offering it — carrying the current choice so it still
            // selects.
            addNetworkModeItem("Host Only (unavailable)", choice: .hostOnly, to: menu, enabled: false)
        }
        // While the session runs, every attachable mode can hot-swap; None
        // cannot — network devices cannot be added or removed at runtime.
        addNetworkModeItem("None", choice: .none, to: menu, enabled: !liveSwitchable)

        renderedNetworkChoice = current
        renderedNetworkLiveSwitchable = liveSwitchable
        if entitlements.hasVMNetworking {
            menu.addItem(.sectionHeader(title: "Bridged"))
            addNetworkModeItem("Automatic", choice: .bridged(nil), to: menu)
            let interfaces = bridgedInterfaces.interfaces()
            if interfaces.isEmpty {
                addNetworkModePlaceholder("No Bridgeable Interfaces", to: menu)
            }
            for interface in interfaces {
                addNetworkModeItem(
                    Self.networkInterfaceTitle(interface),
                    choice: .bridged(interface.identifier), to: menu)
            }
            // Keep an interface the host isn't offering right now on the list, so
            // the picker shows what the VM is actually set to — only while it IS
            // what the VM is set to; an identifier merely remembered from an
            // earlier bridged choice adds no entry.
            if case .bridged(.some(let persisted)) = current,
                !interfaces.contains(where: { $0.identifier == persisted })
            {
                addNetworkModeItem(
                    "\(persisted) (unavailable)", choice: .bridged(persisted),
                    to: menu, enabled: false)
            }
        } else if case .bridged = current {
            // A bridged VM in a build the entitlement doesn't cover: the picker
            // offers no Bridged entry, so this one shows the mode without
            // offering it — carrying the current choice so it still selects.
            addNetworkModeItem("Bridged (unavailable)", choice: current, to: menu, enabled: false)
        }

        selectNetworkModeItem()
    }

    /// Appends one Mode entry.
    ///
    /// `choice` is deliberately non-optional: in an optional context Swift reads
    /// the `.none` case as `nil`, which would strip the None entry's identity.
    private func addNetworkModeItem(
        _ title: String, choice: NetworkModeChoice, to menu: NSMenu, enabled: Bool = true
    ) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = choice
        item.isEnabled = enabled
        menu.addItem(item)
    }

    /// Appends an entry that stands for no mode at all — readable, never chosen.
    private func addNetworkModePlaceholder(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    /// How one bridgeable interface reads in the picker — `Wi-Fi (en0)`, or the
    /// bare identifier when the host names it nothing else.
    private static func networkInterfaceTitle(_ interface: BridgedInterface) -> String {
        guard interface.localizedDisplayName != interface.identifier else { return interface.identifier }
        return "\(interface.localizedDisplayName) (\(interface.identifier))"
    }

    /// The entry standing for the current configuration.
    private var currentNetworkChoice: NetworkModeChoice {
        let config = instance.configuration
        guard config.networkEnabled else { return .none }
        switch config.networkMode {
        case .shared:
            return .shared
        case .hostOnly:
            return .hostOnly
        case .bridged:
            return .bridged(config.bridgedInterfaceIdentifier)
        }
    }

    private func selectNetworkModeItem() {
        let choice = currentNetworkChoice
        guard
            let item = networkModePopUp.menu?.items.first(where: {
                $0.representedObject as? NetworkModeChoice == choice
            })
        else { return }
        networkModePopUp.select(item)
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

    // MARK: Input Devices

    /// Titles and modes for the input devices popup, in menu order.
    private static let inputDeviceChoices: [(title: String, mode: VMInputDeviceMode)] = [
        ("Automatic", .automatic),
        ("Mac Keyboard and Trackpad", .mac),
        ("USB Keyboard and Mouse", .usb),
    ]

    /// Info copy for the macOS-only input devices picker.
    private static let inputDevicesInfoParagraphs: [InfoPopoverParagraph] = [
        .body(
            "Chooses the virtual keyboard and pointing device the guest sees. Automatic picks by the guest's macOS version: the Mac devices for macOS 13 and later, the USB devices for earlier guests, which don't recognize the Mac ones. When the guest's version isn't known, Automatic picks the Mac devices — choose USB here if such a guest has no working input."
        ),
        .body(
            "The USB pointer reads as a mouse inside the guest, so macOS shows permanently visible scroll bars instead of trackpad-style overlay scroll bars."
        ),
    ]

    private func buildInputDevicesSection() -> NSView {
        inputDevicesPopUp = makeInputDevicesPopUp()
        persistentLockableControls.append(inputDevicesPopUp)
        return makeSection([
            makeHeader("Input", lockable: true, paragraphs: Self.inputDevicesInfoParagraphs),
            makeGroupedFormCard(rows: [
                makeGroupedFormCardRow("Devices", control: inputDevicesPopUp)
            ]),
        ])
    }

    private func makeInputDevicesPopUp() -> NSPopUpButton {
        let popUp = NSPopUpButton()
        popUp.controlSize = .small
        for choice in Self.inputDeviceChoices {
            popUp.addItem(withTitle: choice.title)
            popUp.lastItem?.representedObject = choice.mode
        }
        popUp.target = self
        popUp.action = #selector(inputDevicesChanged)
        return popUp
    }

    // MARK: Guest Agent

    /// Caption shown beneath the macOS Guest Agent card.
    static let agentDependencyCaption =
        "Clipboard sharing and log forwarding require the Kernova guest agent. Kernova offers to install or update it from the clipboard window."

    /// Shown under the Guest Agent card while the app-wide preference turns the
    /// install prompt off, so the greyed row reads as controlled elsewhere.
    static let installPromptDisabledCaption =
        "The install reminder is turned off for all virtual machines in Settings → Reminders."

    /// Info-popover copy for the "Automatic Clipboard Passthrough" toggle, shared
    /// by the macOS and Linux clipboard sections.
    static let passthroughInfoParagraphs: [InfoPopoverParagraph] = [
        .body(
            "Forwards this Mac's clipboard to the guest automatically and writes the guest's clipboard here — no clipboard window step in either direction. Requires clipboard sharing and can be toggled while the VM runs."
        ),
        .body(
            "Because the guest then continuously reads whatever you copy (including passwords), turning it on asks for confirmation."
        ),
    ]

    /// Guest Agent group for **macOS** guests, holding the agent-management
    /// toggles plus Clipboard Sharing, which rides the agent's vsock channel.
    private func buildGuestAgentSection() -> NSView {
        logForwardingSwitch = makeSwitch(action: #selector(logForwardingToggled))
        installReminderSwitch = makeSwitch(action: #selector(installReminderToggled))
        clipboardSwitch = makeSwitch(action: #selector(clipboardToggled))
        clipboardPassthroughSwitch = makeSwitch(action: #selector(clipboardPassthroughToggled))
        // Not lockable — every toggle here takes effect live.
        let card = makeGroupedFormCard(rows: [
            makeToggleRowWithInfo(
                "Forward guest logs", control: logForwardingSwitch,
                paragraphs: [
                    .body(
                        "Streams `os.Logger` records from the macOS guest agent to the host so they appear in Console.app under `app.kernova.guest`. Off by default; can be toggled while the VM is running."
                    )
                ]),
            // Passthrough rides on sharing — it goes inert when sharing is off —
            // so it nests as a sub-option rather than an equal sibling toggle.
            makeGroupedFormSubOptionGroup(
                primary: makeToggleRowWithInfo(
                    "Clipboard Sharing", control: clipboardSwitch,
                    paragraphs: [
                        .body("Exchanges clipboard text between host and guest.")
                    ]),
                subOption: makeToggleRowWithInfo(
                    "Automatic Clipboard Passthrough", control: clipboardPassthroughSwitch,
                    paragraphs: Self.passthroughInfoParagraphs,
                    titleLabel: { [weak self] in self?.clipboardPassthroughLabel = $0 })),
            makeToggleRowWithInfo(
                "Show install reminder", control: installReminderSwitch,
                paragraphs: [
                    .body(
                        "Surfaces the install icon in the sidebar when the guest agent has not yet connected. Turn off to suppress the nudge for this VM. The more urgent indicators (update available, didn't reconnect, unresponsive) are not affected."
                    )
                ],
                titleLabel: { [weak self] in self?.installReminderLabel = $0 }),
        ])
        let overrideCaption = makeGroupedFormCaption(Self.installPromptDisabledCaption)
        overrideCaption.isHidden = true
        installReminderOverrideCaption = overrideCaption
        return makeSection([
            makeHeader("Guest Agent"), card, makeGroupedFormCaption(Self.agentDependencyCaption),
            overrideCaption,
        ])
    }

    // MARK: Clipboard

    /// Standalone Clipboard section for **Linux** guests, whose clipboard rides
    /// SPICE (`spice-vdagent`) and is independent of the Kernova guest agent.
    private func buildClipboardSection() -> NSView {
        clipboardSwitch = makeSwitch(action: #selector(clipboardToggled))
        clipboardPassthroughSwitch = makeSwitch(action: #selector(clipboardPassthroughToggled))
        let caption = makeGroupedFormCaption(
            "Takes effect on next start — Linux guests configure SPICE at VM start time.")
        caption.textColor = .systemOrange
        caption.isHidden = true
        clipboardCaption = caption

        let body: InfoPopoverParagraph = .body(
            "Exchanges clipboard text between host and guest. Requires `spice-vdagent` installed in the guest via its package manager."
        )
        // Passthrough is host-side (it polls/writes the host pasteboard), so unlike
        // sharing it takes effect live for Linux guests too.
        return makeSection([
            makeHeader("Clipboard", paragraphs: [body]),
            makeGroupedFormCard(rows: [
                makeGroupedFormSubOptionGroup(
                    primary: makeGroupedFormCardRow("Clipboard Sharing", control: clipboardSwitch),
                    subOption: makeToggleRowWithInfo(
                        "Automatic Clipboard Passthrough", control: clipboardPassthroughSwitch,
                        paragraphs: Self.passthroughInfoParagraphs,
                        titleLabel: { [weak self] in self?.clipboardPassthroughLabel = $0 }))
            ]),
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
                        "Exposes the running VM's serial port over a local UNIX socket so an external terminal can attach. Output is always captured to `serial.log` regardless of this setting; when it grows large it rolls to `serial.log.1` alongside."
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
        button.bezelStyle = .push
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

    /// Builds a toggle row: title, info button, and a trailing control.
    ///
    /// `titleLabel` hands the freshly-built label back to the caller, for rows
    /// whose text has to be restyled later.
    private func makeToggleRowWithInfo(
        _ title: String, control: NSControl, paragraphs: [InfoPopoverParagraph],
        titleLabel: ((NSTextField) -> Void)? = nil
    ) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = Typography.body
        label.isSelectable = false
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        titleLabel?(label)

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
    /// Detaches only — the backing file is untouched — so it is neutral-tinted
    /// rather than destructive red.
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
    private func apply() {
        guard isViewLoaded else { return }
        bannerContainer.isHidden = !isReadOnly
        lockIcons.forEach { $0.isHidden = !isReadOnly }
        persistentLockableControls.forEach { $0.isEnabled = !isReadOnly }

        refreshGeneral()
        refreshResources()
        refreshDisplay()
        refreshNetwork()
        refreshAudio()
        refreshInputDevices()
        refreshGuestAgent()
        refreshClipboard()
        refreshSerialRelay()
        refreshStorageList()
        refreshRemovableList()
        refreshSharedList()

        let refs = externalAttachmentRefs(for: instance.configuration)
        Task { await fileMonitor.setPaths(refs) }
    }

    private func refreshGeneral() {
        nameButton.title = instance.name
        nameButton.isEnabled = instance.status.canRename
        let installedImage = instance.configuration.installedImage?.displayName
        installedImageValueLabel?.stringValue = installedImage ?? ""
        installedImageRow?.isHidden = installedImage == nil
        let reportedOSVersion = instance.guestOSVersionDisplay
        guestOSVersionValueLabel?.stringValue = reportedOSVersion ?? ""
        guestOSVersionRow?.isHidden = reportedOSVersion == nil
        let renaming = isRenaming
        if renaming != nameRowIsEditing {
            if renaming {
                nameRowIsEditing = true
                nameDisplayRow.isHidden = true
                nameEditRow.isHidden = false
                nameField.stringValue = instance.name
                view.window?.makeFirstResponder(nameField)
                // Re-seed after taking focus: the makeFirstResponder above can
                // synchronously commit the *other* surface's pending rename,
                // changing `instance.name` after the seed — and the mutation
                // lands inside this very apply() pass, so no later pass repairs
                // an already-open box.
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
                // End a still-active editor session BEFORE flipping the session
                // flag or hiding the row: the resign flows through
                // `controlTextDidEndEditing`, whose commit gate reads
                // `nameRowIsEditing`, so a superseded rename's in-flight text
                // still commits and no focused-but-invisible editor survives to
                // swallow keystrokes.
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
    /// Resigns the field editor so `controlTextDidEndEditing` commits when the
    /// user clicks anywhere outside the name field — AppKit doesn't end field
    /// editing on clicks that land on non-focusable space in the settings card.
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
    /// stranding the typed text, the marker, and the outside-click monitor.
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

    /// The density the user asked for, which a match-window boot applies to the
    /// size it computes.
    private var displayHiDPIIntent: Bool {
        instance.configuration.guestOS.supportsDisplayDensity
            && instance.configuration.displayHiDPI
    }

    /// Whether the stored resolution — what the VM boots at — reads as HiDPI.
    ///
    /// The materialized counterpart to `displayHiDPIIntent`; the two diverge
    /// only in match mode, where the trio is the previous boot's artifact.
    private var displayResolutionIsHiDPI: Bool {
        instance.configuration.guestOS.supportsDisplayDensity
            && DisplayBootSizing.isHiDPI(ppi: instance.configuration.displayPPI)
    }

    /// The "looks like" size shown in the Width/Height fields — half the stored
    /// pixel count while the stored resolution is HiDPI.
    private var displayBaseSize: (width: Int, height: Int) {
        let config = instance.configuration
        guard displayResolutionIsHiDPI else { return (config.displayWidth, config.displayHeight) }
        return (config.displayWidth / 2, config.displayHeight / 2)
    }

    private func refreshDisplay() {
        let config = instance.configuration
        let base = displayBaseSize
        displayMatchWindowSwitch.state = config.displaySizesToWindow ? .on : .off
        // Intent, not the stored density: in match mode the two legitimately
        // differ until the next boot materializes the trio.
        displayHiDPISwitch.state = displayHiDPIIntent ? .on : .off
        displayAutoResizeSwitch.state = config.displayAutoResizes ? .on : .off
        // A field with an open editor is mid-edit: any refresh — a status change
        // started from the toolbar, say — would otherwise discard the keystrokes
        // typed so far.
        if displayWidthField.currentEditor() == nil {
            displayWidthField.integerValue = base.width
        }
        if displayHeightField.currentEditor() == nil {
            displayHeightField.integerValue = base.height
        }

        let stored = DisplayResolutionPreset(width: base.width, height: base.height)
        let presetItem =
            displayResolutionIsCustom
            ? nil
            : displayResolutionPopUp.menu?.items.first {
                $0.representedObject as? DisplayResolutionPreset == stored
            }
        if let presetItem {
            displayResolutionPopUp.select(presetItem)
        } else {
            displayResolutionPopUp.selectItem(withTitle: Self.displayCustomTitle)
        }

        // Match mode computes the size at start, so the size controls are inert
        // (disabled, not hidden). HiDPI stays live — it picks the scale that
        // computation runs at.
        let manualEnabled = !isReadOnly && !config.displaySizesToWindow
        displayResolutionPopUp.isEnabled = manualEnabled
        displayWidthField.isEnabled = manualEnabled
        displayHeightField.isEnabled = manualEnabled

        displayResolutionCaption.stringValue = displayResolutionCaptionText()
        displayRestartCaption.isHidden = !isReadOnly
    }

    private func displayResolutionCaptionText() -> String {
        let config = instance.configuration
        var text = "Boots at \(config.displayWidth) × \(config.displayHeight) pixels"
        if displayResolutionIsHiDPI {
            let base = displayBaseSize
            text += " (looks like \(base.width) × \(base.height))"
        }
        if config.displaySizesToWindow {
            return "\(text), until the next start resizes it to the window."
        }
        return "\(text)."
    }

    private func refreshNetwork() {
        let liveSwitchable = networkModeIsLiveSwitchable
        networkModePopUp.isEnabled = !isReadOnly || liveSwitchable
        // `apply()` just showed every lock icon for the read-only pane; a live
        // picker makes this section's lock a false claim, so re-hide it.
        networkLockIcon?.isHidden = !isReadOnly || liveSwitchable
        if currentNetworkChoice != renderedNetworkChoice
            || liveSwitchable != renderedNetworkLiveSwitchable
        {
            rebuildNetworkModeMenu()
        }
        // None leaves no device to describe, so the card's remaining rows give way
        // to a caption saying so.
        let hasDevice = instance.configuration.networkEnabled
        refreshMACAddressRow()
        refreshMACAddressWarning(hasDevice: hasDevice)
        networkNoDeviceCaption.isHidden = hasDevice
        refreshIPAddressRow()
        // Rules ride the app-managed shared network, and reach the guest at the
        // address its MAC reserves: an unentitled build attaches system NAT,
        // which forwards nothing, the other modes carry no forwarding at all,
        // and without a MAC there is no reservation to forward to.
        let forwards =
            hasDevice && instance.configuration.networkMode == .shared
            && entitlements.hasVMNetworking && instance.configuration.macAddress != nil
        portForwardingRow?.isHidden = !forwards
        if forwards { refreshPortForwardingRows() }
    }

    /// Discloses that another VM in the library carries this one's MAC address.
    ///
    /// Import, load and reconcile admit a bundle whatever address it arrives
    /// with, so the pair is visible here rather than refused at the door — the
    /// address stays editable, and Generate above the banner moves this VM off
    /// it. Shown wherever the MAC row is: an address is held while networking
    /// is off, but nothing shows it there to contradict.
    private func refreshMACAddressWarning(hasDevice: Bool) {
        let message: String?
        if hasDevice, instance.configuration.macAddress != nil {
            let names = viewModel.vmNamesSharingMACAddress(with: instance)
            message =
                names.isEmpty
                ? nil
                : "This MAC address is also used by \(names.map { "“\($0)”" }.joined(separator: ", ")). "
                    + "Each virtual machine needs its own."
        } else {
            message = nil
        }
        guard message != renderedNetworkMACWarning else { return }
        renderedNetworkMACWarning = message
        networkWarningContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let message else { return }
        let banner = makeGroupedFormBanner(
            symbolName: "exclamationmark.triangle.fill", tint: .systemYellow, message: message)
        addFullWidth(banner, to: networkWarningContainer)
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

    private func refreshInputDevices() {
        guard instance.configuration.guestOS == .macOS else { return }
        let mode = instance.configuration.inputDeviceMode
        let index = inputDevicesPopUp.itemArray.firstIndex {
            ($0.representedObject as? VMInputDeviceMode) == mode
        }
        guard let index else {
            Self.logger.fault("No popup item for input device mode '\(mode.rawValue, privacy: .public)'")
            assertionFailure("No popup item for input device mode: \(mode.rawValue)")
            return
        }
        inputDevicesPopUp.selectItem(at: index)
    }

    private func refreshGuestAgent() {
        guard isGuestAgentSectionVisible(guestOS: instance.configuration.guestOS) else { return }
        logForwardingSwitch.state = instance.configuration.agentLogForwardingEnabled ? .on : .off
        // The per-VM flag keeps its value while the app-wide preference overrides
        // it, so the switch still shows what this VM reverts to when the
        // preference is turned back on — it just can't be changed from here.
        installReminderSwitch.state = instance.configuration.agentInstallNudgeDismissed ? .off : .on
        let overridden = viewModel.agentInstallPromptDisabled
        installReminderSwitch.isEnabled = !overridden
        // AppKit fades the disabled switch but not its label, which leaves the
        // row half-lit; gray the text in step so the row reads as inert.
        installReminderLabel.textColor = overridden ? .disabledControlTextColor : .labelColor
        installReminderOverrideCaption.isHidden = !overridden
    }

    private func refreshClipboard() {
        clipboardSwitch.state = instance.configuration.clipboardSharingEnabled ? .on : .off
        // Passthrough is hot-toggleable, so it isn't in
        // `persistentLockableControls`; its enablement is gated here instead.
        clipboardPassthroughSwitch.state = instance.configuration.clipboardPassthroughEnabled ? .on : .off
        clipboardPassthroughSwitch.isEnabled = instance.configuration.clipboardSharingEnabled
        // AppKit fades the disabled switch but not its label, which leaves the
        // row half-lit; gray the text in step so the sub-option reads as inert.
        clipboardPassthroughLabel.textColor =
            instance.configuration.clipboardSharingEnabled ? .labelColor : .disabledControlTextColor
        // The "takes effect on next start" caption is built only by the Linux
        // standalone section, so gate it here.
        guard instance.configuration.guestOS == .linux else { return }
        clipboardCaption.isHidden = !isReadOnly
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
                // Removable media is always external and hot-pluggable, so
                // controls stay enabled even while the VM runs.
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
    /// stack; anything else updates the affected rows in place. Only the
    /// structural path tears down an in-progress editing field, so only it is
    /// skipped while a row is being renamed. The live size is re-read on *every*
    /// in-place pass, so an out-of-band resize is reflected.
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
    /// context menu; the per-list differences arrive via `kind`,
    /// `readOnlySelector`, and the active-rename key path.
    private func makeAttachmentRow(
        model: RenderedRow,
        kind: AttachmentKind,
        readOnlySelector: Selector,
        activeRename activeKP: ReferenceWritableKeyPath<VMSettingsViewController, UUID?>
    ) -> AttachmentRowView {
        let ref = AttachmentRef(kind: kind, id: model.id)
        let icon = AttachmentIconButton()
        icon.configure(systemName: model.iconSystemName, missingPath: model.missingPath)
        icon.onActivate = { [weak self] anchor in
            guard let self, let info = self.attachmentInfo(ref) else { return }
            self.presentAttachmentInfoPopover(info, from: anchor)
        }
        // Removable media is hot-pluggable and swapped often, so it carries an
        // inline one-click Eject button (detach only, no confirmation); storage
        // disks detach through the context menu alone.
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

extension VMSettingsViewController: NSMenuItemValidation {
    @objc private func startRename() {
        guard instance.status.canRename else { return }
        viewModel.renameVMInDetail(instance)
    }

    /// Disables the name field's right-click "Rename" while the VM can't be
    /// renamed (e.g. while running), mirroring the disabled name button.
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

    /// Gives a VM turning networking on its first MAC address.
    ///
    /// A VM created with networking off carries none, and VZ then generates a
    /// fresh random one at every start — so the address the LAN sees, and any
    /// DHCP reservation keyed on it, would change from one boot to the next.
    private static func mintMACAddressIfNeeded(_ config: inout VMConfiguration) {
        guard config.macAddress == nil else { return }
        config.macAddress = VZMACAddress.randomLocallyAdministered().string
    }

    /// The canonical form of the MAC address `text` names — lowercase,
    /// colon-separated — or `nil` when it names none a guest can use.
    ///
    /// `VZMACAddress(string:)` takes six colon-separated hex pairs in either
    /// case and rejects every other spelling, so case is the only thing left to
    /// normalize. It also accepts the all-zero address and multicast/broadcast
    /// addresses, none of which a station can send from: a guest configured
    /// with one gets no link, and the app would key its reservation and
    /// forwarding rules on an address no frame can source
    /// (docs/NETWORKING.md principle 3 — refuse at entry what cannot take
    /// effect).
    static func normalizedMACAddress(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let address = VZMACAddress(string: trimmed), address.isUnicastAddress,
            address.string != Self.unspecifiedMACAddress
        else { return nil }
        return address.string
    }

    /// The all-zero address, which parses and reads as unicast but addresses
    /// nothing.
    private static let unspecifiedMACAddress = "00:00:00:00:00:00"

    @objc private func generateMACAddressTapped() {
        // Clicking a push button takes no first responder, so an edit open in
        // the field would outlive the write and commit over it on the way out.
        // Discard it rather than settling it: the generated address supersedes
        // whatever was typed, so committing first would only refuse a typed
        // duplicate with an alert about an address no longer in play.
        macAddressField.abortEditing()
        writeConfig { $0.macAddress = VZMACAddress.randomLocallyAdministered().string }
        refreshMACAddressRow()
    }

    @objc private func networkModeChanged() {
        guard let choice = networkModePopUp.selectedItem?.representedObject as? NetworkModeChoice
        else { return }
        let accepted: Bool
        switch choice {
        case .shared:
            // `bridgedInterfaceIdentifier` is left alone so switching back to
            // Bridged remembers the interface.
            accepted = writeConfig {
                $0.networkEnabled = true
                $0.networkMode = .shared
                Self.mintMACAddressIfNeeded(&$0)
            }
        case .hostOnly:
            accepted = writeConfig {
                $0.networkEnabled = true
                $0.networkMode = .hostOnly
                Self.mintMACAddressIfNeeded(&$0)
            }
        case .none:
            accepted = writeConfig { $0.networkEnabled = false }
        case .bridged(let identifier):
            accepted = writeConfig {
                $0.networkEnabled = true
                $0.networkMode = .bridged
                $0.bridgedInterfaceIdentifier = identifier
                Self.mintMACAddressIfNeeded(&$0)
            }
        }
        // A refused switch leaves the configuration untouched, so nothing marks
        // the menu stale and the picker would go on showing a mode the VM is not
        // on. Rebuilding re-selects the configured one.
        if !accepted { rebuildNetworkModeMenu() }
        // The write flips the card's row visibility; refresh in case the value was
        // already what the model held.
        refreshNetwork()
    }

    // MARK: Display

    @objc private func displayMatchWindowToggled() {
        let sizesToWindow = displayMatchWindowSwitch.state == .on
        let hiDPI = displayHiDPIIntent
        writeConfig { config in
            config.displaySizesToWindow = sizesToWindow
            // Leaving match mode promotes the trio from the last boot's artifact
            // to the resolution the VM boots at, so it has to carry the intent
            // set while nothing was reconciling it.
            guard !sizesToWindow, hiDPI != DisplayBootSizing.isHiDPI(ppi: config.displayPPI) else {
                return
            }
            config.displayResolution = DisplayBootSizing.rescaled(
                config.displayResolution, toHiDPI: hiDPI)
        }
        // The write flips the manual controls' enablement; refresh in case the
        // value was already what the model held.
        refreshDisplay()
    }

    @objc private func displayResolutionChanged() {
        guard
            let preset = displayResolutionPopUp.selectedItem?.representedObject
                as? DisplayResolutionPreset
        else {
            displayResolutionIsCustom = true
            return
        }
        displayResolutionIsCustom = false
        // Route through the field-edit path so preset and typed sizes share one
        // clamp-and-write.
        displayWidthField.integerValue = preset.width
        displayHeightField.integerValue = preset.height
        applyDisplaySizeFieldEdit()
    }

    @objc private func displayHiDPIToggled() {
        let hiDPI = displayHiDPISwitch.state == .on
        let sizesToWindow = instance.configuration.displaySizesToWindow
        writeConfig { config in
            config.displayHiDPI = hiDPI
            // In match mode the trio is the last boot's artifact; the next boot
            // recomputes it at the scale this flag picks.
            guard !sizesToWindow else { return }
            config.displayResolution = DisplayBootSizing.rescaled(
                config.displayResolution, toHiDPI: hiDPI)
        }
        // The size fields are derived from the trio this may have rewritten;
        // reconcile them now rather than on the configuration observation.
        refreshDisplay()
    }

    @objc private func displayAutoResizeToggled() {
        writeConfig { $0.displayAutoResizes = displayAutoResizeSwitch.state == .on }
    }

    /// Clamps the typed base size, scales it for the current HiDPI state, and
    /// persists it.
    private func applyDisplaySizeFieldEdit() {
        // The fields are only editable in manual mode, where intent and stored
        // density agree; pairing with the stored one keeps the write the exact
        // inverse of the `displayBaseSize` that filled them.
        let hiDPI = displayResolutionIsHiDPI
        // A HiDPI base is doubled before it reaches VZ, so it clamps to half
        // the pixel ceiling.
        let base = DisplayBootSizing.clamped(
            width: displayWidthField.integerValue, height: displayHeightField.integerValue,
            ppi: DisplayBootSizing.standardPixelsPerInch,
            maximum: hiDPI ? DisplayBootSizing.maximumDimension / 2 : DisplayBootSizing.maximumDimension)
        writeDisplayResolution(hiDPI ? DisplayBootSizing.doubled(base) : base)
    }

    private func writeDisplayResolution(_ resolution: DisplayBootSizing.Resolution) {
        writeConfig { $0.displayResolution = resolution }
        // A clamped-back-to-current edit writes nothing, so the fields and popup
        // are reconciled here rather than by the configuration observation.
        refreshDisplay()
    }

    @objc private func audioInputToggled() {
        refreshMicPermission()
        writeConfig { $0.audioInputEnabled = audioInputSwitch.state == .on }
    }

    @objc private func audioOutputToggled() {
        writeConfig { $0.audioOutputEnabled = audioOutputSwitch.state == .on }
    }

    @objc private func inputDevicesChanged() {
        guard
            let mode = inputDevicesPopUp.selectedItem?.representedObject as? VMInputDeviceMode
        else {
            Self.logger.fault("Input devices popup selection carries no mode")
            assertionFailure("Input devices popup selection carries no mode")
            return
        }
        writeConfig { $0.inputDeviceMode = mode }
    }

    @objc private func logForwardingToggled() {
        writeConfig { $0.agentLogForwardingEnabled = logForwardingSwitch.state == .on }
    }

    @objc private func installReminderToggled() {
        // Routed through the view model's named accessor rather than the generic
        // `writeConfig` so every write of this flag shares one logged path.
        viewModel.setAgentInstallNudgeDismissed(installReminderSwitch.state != .on, for: instance)
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

    @objc private func clipboardPassthroughToggled() {
        // Turning off is immediate; turning on grants the guest continuous read of
        // the host clipboard, so confirm first and revert the switch on cancel.
        guard clipboardPassthroughSwitch.state == .on else {
            writeConfig { $0.clipboardPassthroughEnabled = false }
            return
        }
        guard let window = view.window else {
            // No window to host a sheet — don't silently enable; revert.
            clipboardPassthroughSwitch.state = .off
            return
        }
        presentSheetAlert(
            ClipboardPassthroughConfirmation.alert(
                onConfirm: { [weak self] in self?.enablePassthroughConfirmed() },
                onCancel: { [weak self] in self?.revertPassthroughToggle() }),
            in: window)
    }

    private func enablePassthroughConfirmed() {
        writeConfig { $0.clipboardPassthroughEnabled = true }
    }

    private func revertPassthroughToggle() {
        clipboardPassthroughSwitch.state = .off
    }

    #if DEBUG
    /// Drives the confirmation outcomes without a window/sheet, so tests exercise
    /// the real enable-commit and cancel-revert paths.
    func confirmPassthroughEnableForTesting() { enablePassthroughConfirmed() }
    func cancelPassthroughEnableForTesting() { revertPassthroughToggle() }
    #endif

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
            let (path, bookmark) = SecurityScopedBookmark.capture(url)
            guard !existing.contains(path) else { continue }
            current.append(StorageDisk(path: path, bookmark: bookmark))
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

    @objc private func addPortForwardingRuleTapped() {
        guard !isReadOnly, let window = view.window, !portForwardingSheetPresenter.isShown else {
            return
        }
        let sheet = PortForwardingRuleSheetContentViewController(
            takenHostClaims: takenHostPortClaims())
        sheet.delegate = self
        portForwardingSheetPresenter.show(content: sheet, in: window)
    }

    @objc private func removePortForwardingRuleTapped(_ sender: NSButton) {
        guard !isReadOnly else { return }
        var rules = instance.configuration.portForwardingRules
        guard rules.indices.contains(sender.tag) else { return }
        rules.remove(at: sender.tag)
        writePortForwardingRules(rules)
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
    /// set of `@objc` handlers serves both lists.
    enum AttachmentKind { case storage, removable }

    /// A context-menu item's backing identity (list + id), stored as its
    /// `representedObject`.
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
        // Removable media offers Eject (detach, no confirmation) alongside the
        // file-trashing Remove…; storage disks get Remove… only.
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

    /// Builds the alert for a decided ``AttachmentDeletePrompt``, appending Cancel.
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
    /// purely from the item's nature.
    ///
    /// The Guest Agent installer and files shared with another VM can only be
    /// detached, never trashed.
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
            let (path, bookmark) = SecurityScopedBookmark.capture(url)
            guard !existing.contains(path) else { continue }
            current.append(RemovableMediaItem(path: path, readOnly: true, bookmark: bookmark))
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
    /// Detach only — no confirmation, backing file untouched.
    @objc private func removableEjectTapped(_ sender: NSButton) {
        guard let id = uuid(from: sender) else { return }
        ejectRemovableMedia(forItemID: id)
    }

    /// Detaches a removable medium (removes its config entry, keeping the file).
    ///
    /// Dropping the `removableMedia` entry is what the live reconcile
    /// hot-detaches from a running VM. No alert: ejecting is reversible.
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
            let (path, bookmark) = SecurityScopedBookmark.capture(url)
            guard !existing.contains(path) else { continue }
            current.append(SharedDirectory(path: path, bookmark: bookmark))
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

// MARK: - NSMenuDelegate

extension VMSettingsViewController: NSMenuDelegate {
    /// Re-reads the host's bridgeable interfaces each time the Mode picker opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === networkModePopUp.menu else { return }
        rebuildNetworkModeMenu()
    }
}

// MARK: - NSTextFieldDelegate

extension VMSettingsViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === nameField else { return }
        let live = nameField.currentEditor()?.string ?? nameField.stringValue
        nameEditMaxWidth.constant = InlineRenameSizing.boxWidth(for: live, font: Typography.body)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        switch field {
        case nameField:
            // Gate on the local session flag, not the model marker: when this
            // surface's rename is superseded mid-handoff the marker has already
            // moved to the other surface, but the in-flight text must still
            // commit.
            if nameRowIsEditing, !suppressNameEndEditingCommit {
                viewModel.commitRename(
                    for: instance, newName: nameField.stringValue, from: .detail)
            }
        case cpuField:
            applyCPUFieldEdit()
        case memoryField:
            applyMemoryFieldEdit()
        case displayWidthField, displayHeightField:
            applyDisplaySizeFieldEdit()
        case macAddressField:
            applyMACAddressFieldEdit()
        default:
            break
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === nameField else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // Resign instead of committing directly: the end-editing path is the
            // single commit path, so Return, outside clicks, and superseded
            // teardowns all commit the same way.
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

    /// Persists the typed MAC in canonical form, then shows the address the VM
    /// ended up with — so text naming no address a guest can use, and an address
    /// the library refused because another VM holds it, both snap the field back.
    /// The tooltip names the accepted spelling; the refusal carries its own alert.
    ///
    /// The field is written directly rather than through
    /// `refreshMACAddressRow()`: editing is still ending here, so the editor the
    /// refresh defers to is the very one being reconciled away.
    private func applyMACAddressFieldEdit() {
        if let normalized = Self.normalizedMACAddress(macAddressField.stringValue) {
            writeConfig { $0.macAddress = normalized }
        }
        macAddressField.stringValue = instance.configuration.macAddress ?? ""
    }
}

// MARK: - AttachmentDeletePrompt

/// The confirmation a per-row storage/removable delete should present.
///
/// The trailing Cancel button is added by the presenter, not modeled here.
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

// MARK: - PortForwardingRuleSheetContentViewControllerDelegate

extension VMSettingsViewController: PortForwardingRuleSheetContentViewControllerDelegate {
    func portForwardingRuleSheet(
        _ vc: PortForwardingRuleSheetContentViewController, didAdd rule: PortForwardingRule
    ) {
        portForwardingSheetPresenter.close()
        writePortForwardingRules(instance.configuration.portForwardingRules + [rule])
    }

    func portForwardingRuleSheetDidCancel(_ vc: PortForwardingRuleSheetContentViewController) {
        portForwardingSheetPresenter.close()
    }
}
