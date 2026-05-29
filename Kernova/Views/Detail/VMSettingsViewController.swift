import AVFoundation
import AppKit
import UniformTypeIdentifiers

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
/// warning.
@MainActor
final class VMSettingsViewController: NSViewController {
    private(set) var instance: VMInstance
    private var viewModel: VMLibraryViewModel
    private var isReadOnly: Bool

    // MARK: - Observation & live state

    private let fileMonitor = AttachmentFileMonitor()
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

    // Removable Media
    private var removableListStack = NSStackView()
    private var createRemovableButton: NSButton?

    // Shared Directories
    private var sharedListStack = NSStackView()

    // Network
    private var networkSwitch = NSSwitch()

    // Audio
    private var micSwitch = NSSwitch()
    private var audioWarningContainer = NSStackView()

    // Guest Agent
    private var logForwardingSwitch = NSSwitch()
    private var installReminderSwitch = NSSwitch()

    // Clipboard
    private var clipboardSwitch = NSSwitch()
    private var clipboardCaption = NSView()

    // Serial Console
    private var serialRelaySwitch = NSSwitch()

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
                _ = self.instance.cachedDiskUsageBytes
                _ = self.viewModel.activeRename
            },
            apply: { [weak self] in self?.apply() }
        )
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        hasDisappeared = true
        modelObservation?.cancel()
        modelObservation = nil
        NotificationCenter.default.removeObserver(
            self, name: NSApplication.didBecomeActiveNotification, object: nil)
        if reorderSheetPresenter.isShown { reorderSheetPresenter.close() }
        if micPermissionPresenter.isShown { micPermissionPresenter.close() }
    }

    /// Starts the per-instance side effects: seeding the file monitor with the
    /// current attachment paths and refreshing the main disk's usage stats.
    private func startInstanceSideEffects() {
        let paths = externalAttachmentPaths(for: instance.configuration)
        Task { await fileMonitor.setPaths(paths) }
        Task { await instance.refreshDiskUsage() }
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
            addSection(buildGuestAgentSection())
        }
        addSection(buildClipboardSection())
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
        nameDisplayRow = makeGroupedFormCardRow("Name", control: nameButton)

        nameField.placeholderString = "Name"
        nameField.alignment = .right
        nameField.delegate = self
        nameEditRow = makeGroupedFormCardRow("Name", control: nameField, fillsControl: true)
        nameEditRow.isHidden = true

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
        attachStorageButton = makePushButton("Attach Disc...", action: #selector(attachStorageTapped))
        createStorageButton = makePushButton("Create New Disk...", action: #selector(createStorageTapped))
        editBootOrderButton = makePushButton("Edit Boot Order...", action: #selector(editBootOrderTapped))
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
        let attach = makePushButton("Attach Disc...", action: #selector(attachRemovableTapped))
        let create = makePushButton("Create New Disk...", action: #selector(createRemovableTapped))
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
        let add = makePushButton("Add Shared Directory...", action: #selector(addSharedTapped))
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
        micSwitch = makeSwitch(action: #selector(micToggled))
        persistentLockableControls.append(micSwitch)

        audioWarningContainer = NSStackView()
        audioWarningContainer.orientation = .vertical
        audioWarningContainer.alignment = .leading
        audioWarningContainer.spacing = Spacing.small
        audioWarningContainer.translatesAutoresizingMaskIntoConstraints = false

        var paragraphs: [InfoPopoverParagraph] = [
            .body(
                "Exposes a VirtioSound device. Speaker output is always enabled; toggle the microphone to grant the guest access to your host mic."
            )
        ]
        if instance.configuration.guestOS == .linux {
            paragraphs.append(.body("Requires Linux kernel 5.14 or newer to detect the VirtioSound device."))
        }
        return makeSection([
            makeHeader("Audio", lockable: true, paragraphs: paragraphs),
            makeGroupedFormCard(rows: [makeGroupedFormCardRow("Microphone", control: micSwitch)]),
            audioWarningContainer,
        ])
    }

    // MARK: Guest Agent

    private func buildGuestAgentSection() -> NSView {
        logForwardingSwitch = makeSwitch(action: #selector(logForwardingToggled))
        installReminderSwitch = makeSwitch(action: #selector(installReminderToggled))
        // Not lockable — both toggles take effect live.
        let card = makeGroupedFormCard(rows: [
            makeToggleRowWithInfo(
                "Forward guest logs", control: logForwardingSwitch,
                paragraphs: [
                    .body(
                        "Streams `os.Logger` records from the macOS guest agent to the host so they appear in Console.app under `com.kernova.guest`. Off by default; can be toggled while the VM is running."
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
        return makeSection([makeHeader("Guest Agent"), card])
    }

    // MARK: Clipboard

    private func buildClipboardSection() -> NSView {
        clipboardSwitch = makeSwitch(action: #selector(clipboardToggled))
        let caption = makeGroupedFormCaption(
            "Takes effect on next start — Linux guests configure SPICE at VM start time.")
        caption.textColor = .systemOrange
        caption.isHidden = true
        clipboardCaption = caption

        let body: InfoPopoverParagraph =
            instance.configuration.guestOS == .linux
            ? .body(
                "Exchanges clipboard text between host and guest. Requires `spice-vdagent` installed in the guest via its package manager."
            )
            : .body(
                "Exchanges clipboard text between host and guest. Uses the bundled Kernova guest agent — Kernova will offer to install or update it from the clipboard window."
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
        let body: InfoPopoverParagraph = .body(
            "Exposes the running VM's serial port over a local UNIX socket so an external terminal can attach. Connect with `socat -,raw,echo=0 UNIX-CONNECT:<path>` (best for full-screen apps; `brew install socat`) or `nc -U <path>` (built in). The socket path appears in the Serial Console window. Output is always captured to `serial.log` regardless of this setting."
        )
        return makeSection([
            makeHeader("Serial Console", paragraphs: [body]),
            makeGroupedFormCard(rows: [makeGroupedFormCardRow("Expose Serial Socket", control: serialRelaySwitch)]),
        ])
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

    private func makeMinusButton(id: UUID, enabled: Bool, action: Selector) -> NSButton {
        let button = NSButton()
        button.image = .systemSymbol("minus.circle.fill", accessibilityDescription: "Remove")
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = .systemRed
        button.isEnabled = enabled
        button.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        button.target = self
        button.action = action
        return button
    }

    /// Builds an attachment list row: leading icon, title + subtitle, a
    /// read-only switch with its caption, and a destructive remove button.
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
        let readOnlyCaption = NSTextField(labelWithString: "Read Only")
        readOnlyCaption.font = .preferredFont(forTextStyle: .caption1)
        readOnlyCaption.textColor = .secondaryLabelColor
        readOnlyCaption.isSelectable = false
        readOnlyCaption.setContentHuggingPriority(.required, for: .horizontal)

        let delete = makeMinusButton(id: id, enabled: controlsEnabled, action: deleteSelector)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [icon, textStack, spacer, readOnlyToggle, readOnlyCaption, delete])
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
            nameRowIsEditing = renaming
            nameDisplayRow.isHidden = renaming
            nameEditRow.isHidden = !renaming
            if renaming {
                nameField.stringValue = instance.name
                view.window?.makeFirstResponder(nameField)
            }
        }
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
        micSwitch.state = instance.configuration.microphoneEnabled ? .on : .off
        let warning = micPermissionPresentation(
            micPermission, micEnabled: instance.configuration.microphoneEnabled)
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
                subtitle: diskSubtitle(for: disk, in: instance),
                isMissing: isMissing,
                missingPath: isMissing ? disk.path : nil,
                readOnly: disk.readOnly,
                controlsEnabled: !isReadOnly)
        }
        guard models != renderedStorageRows else { return }
        renderedStorageRows = models
        clear(storageListStack)
        for model in models {
            let icon = AttachmentIconButton()
            icon.configure(systemName: model.iconSystemName, missingPath: model.missingPath)
            let row = makeListRow(
                icon: icon,
                title: model.title,
                subtitle: makeAttachmentSubtitleLabel(path: model.subtitle, isMissing: model.isMissing),
                id: model.id,
                readOnly: model.readOnly,
                controlsEnabled: model.controlsEnabled,
                readOnlySelector: #selector(storageReadOnlyToggled),
                deleteSelector: #selector(storageDeleteTapped))
            addFullWidth(row, to: storageListStack)
        }
    }

    private func refreshRemovableList() {
        let models = currentRemovableMedia.map { item -> RenderedRow in
            let isMissing = !fileMonitor.exists(item.path)
            return RenderedRow(
                id: item.id,
                iconSystemName: "opticaldisc",
                title: item.label,
                subtitle: item.path,
                isMissing: isMissing,
                missingPath: isMissing ? item.path : nil,
                readOnly: item.readOnly,
                controlsEnabled: true)
        }
        guard models != renderedRemovableRows else { return }
        renderedRemovableRows = models
        clear(removableListStack)
        if models.isEmpty {
            addFullWidth(makeSecondaryLabel("No removable media attached"), to: removableListStack)
            return
        }
        for model in models {
            let icon = AttachmentIconButton()
            icon.configure(systemName: model.iconSystemName, missingPath: model.missingPath)
            let row = makeListRow(
                icon: icon,
                title: model.title,
                subtitle: makeAttachmentSubtitleLabel(path: model.subtitle, isMissing: model.isMissing),
                id: model.id,
                readOnly: model.readOnly,
                controlsEnabled: model.controlsEnabled,
                readOnlySelector: #selector(removableReadOnlyToggled),
                deleteSelector: #selector(removableDeleteTapped))
            addFullWidth(row, to: removableListStack)
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
        viewModel.renameVM(instance)
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

    @objc private func micToggled() {
        refreshMicPermission()
        writeConfig { $0.microphoneEnabled = micSwitch.state == .on }
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
        var disks = currentStorageDisks
        guard let index = disks.firstIndex(where: { $0.id == id }) else { return }
        disks[index].readOnly = sender.state == .on
        writeStorageDisks(disks)
    }

    @objc private func storageDeleteTapped(_ sender: NSButton) {
        guard let id = uuid(from: sender), let window = view.window,
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
        var items = currentRemovableMedia
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].readOnly = sender.state == .on
        writeRemovableMedia(items)
    }

    @objc private func removableDeleteTapped(_ sender: NSButton) {
        guard let id = uuid(from: sender), let window = view.window,
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
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        switch field {
        case nameField:
            if isRenaming {
                viewModel.commitRename(for: instance, newName: nameField.stringValue)
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
            viewModel.commitRename(for: instance, newName: nameField.stringValue)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            viewModel.cancelRename()
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
