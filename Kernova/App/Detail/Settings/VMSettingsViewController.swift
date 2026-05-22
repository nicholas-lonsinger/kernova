import AVFoundation
import AppKit
import UniformTypeIdentifiers
import os

/// Settings form for editing a stopped VM's configuration, or viewing a
/// running VM's configuration in read-only mode.
///
/// Replaces the SwiftUI `VMSettingsView`. Composed of one ``SettingsSection``
/// per group (General, Resources, Storage Disks, Removable Media, Shared
/// Directories, Network, Audio, Guest Agent, Clipboard). Each section
/// registers its own ``ObservationLoop`` tracking only the configuration
/// slice it renders, matching the per-section observer strategy from the
/// migration plan.
@MainActor
final class VMSettingsViewController: NSViewController {
    private static let logger = Logger(subsystem: "com.kernova.app", category: "VMSettingsViewController")

    private let instance: VMInstance
    private let viewModel: VMLibraryViewModel
    private let isReadOnly: Bool
    private let showInitialBootBanner: Bool

    // MARK: - Section views

    private let readOnlyBanner = NSStackView()
    private let initialBootBanner = NSStackView()
    private let generalSection = SettingsSection(title: "General")
    private let resourcesSection = SettingsSection(title: "Resources", lockable: true)
    private let storageSection = SettingsSection(title: "Storage Disks", lockable: true)
    private let removableSection = SettingsSection(title: "Removable Media")
    private let sharedSection = SettingsSection(title: "Shared Directories", lockable: true)
    private let networkSection = SettingsSection(title: "Network", lockable: true)
    private let audioSection = SettingsSection(title: "Audio", lockable: true)
    private let guestAgentSection = SettingsSection(title: "Guest Agent")
    private let clipboardSection = SettingsSection(title: "Clipboard")

    // MARK: - General section controls

    private let nameDisplayButton = NSButton()
    private let nameEditField = NSTextField()
    private let nameContainer = NSStackView()
    private let typeRow = NSStackView()
    private let bootModeRow = NSStackView()
    private let createdRow = NSStackView()

    // MARK: - Resources section controls

    private let cpuStepper = NSStepper()
    private let cpuLabel = NSTextField(labelWithString: "")
    private let memoryStepper = NSStepper()
    private let memoryLabel = NSTextField(labelWithString: "")

    // MARK: - Storage section controls

    private let storageRowsContainer = NSStackView()
    private let attachDiskButton = NSButton(title: "Attach Disc…", target: nil, action: nil)
    private let createDiskButton = NSButton(title: "Create New Disk…", target: nil, action: nil)
    private let editBootOrderButton = NSButton(title: "Edit Boot Order…", target: nil, action: nil)
    private let createDiskPopover = PopoverPresenter()
    private var newStorageDiskSize: Int = VMGuestOS.defaultDiskSizeInGB

    // MARK: - Removable media section controls

    private let removableRowsContainer = NSStackView()
    private let attachRemovableButton = NSButton(title: "Attach Disc…", target: nil, action: nil)
    private let createRemovableButton = NSButton(title: "Create New Disk…", target: nil, action: nil)
    private let createRemovablePopover = PopoverPresenter()
    private var newRemovableDiskSize: Int = VMGuestOS.defaultDiskSizeInGB

    // MARK: - Shared directories section controls

    private let sharedRowsContainer = NSStackView()
    private let addSharedButton = NSButton(title: "Add Shared Directory…", target: nil, action: nil)

    // MARK: - Network section controls

    private let networkToggle = NSSwitch()
    private let macAddressRow = NSStackView()
    private let macAddressLabel = NSTextField(labelWithString: "")

    // MARK: - Audio section controls

    private let micToggle = NSSwitch()
    private let micNotDeterminedLabel = NSTextField(labelWithString: "")
    private let micDeniedBanner = NSStackView()
    private var micPermission: AVAuthorizationStatus = .notDetermined

    // MARK: - Guest agent + clipboard

    private let agentLogToggle = NSSwitch()
    private let agentNudgeToggle = NSSwitch()
    private let clipboardToggle = NSSwitch()
    private let clipboardLinuxHint = NSTextField(labelWithString: "")

    // MARK: - State

    private let fileMonitor = AttachmentFileMonitor()
    private var configObservation: ObservationLoop?
    private var renameObservation: ObservationLoop?
    private var fileMonitorObservation: ObservationLoop?
    private var didApplyInitial = false

    // MARK: - Init

    init(
        instance: VMInstance,
        viewModel: VMLibraryViewModel,
        isReadOnly: Bool,
        showInitialBootBanner: Bool = false
    ) {
        self.instance = instance
        self.viewModel = viewModel
        self.isReadOnly = isReadOnly
        self.showInitialBootBanner = showInitialBootBanner
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("VMSettingsViewController does not support NSCoder")
    }

    // MARK: - Lifecycle

    override func loadView() {
        configureGeneralSection()
        configureResourcesSection()
        configureStorageSection()
        configureRemovableSection()
        configureSharedSection()
        configureNetworkSection()
        configureAudioSection()
        configureGuestAgentSection()
        configureClipboardSection()

        let sectionStack = NSStackView()
        sectionStack.orientation = .vertical
        sectionStack.alignment = .leading
        sectionStack.spacing = 16
        sectionStack.translatesAutoresizingMaskIntoConstraints = false

        configureReadOnlyBanner()
        configureInitialBootBanner()

        if isReadOnly {
            sectionStack.addArrangedSubview(readOnlyBanner)
        }
        if showInitialBootBanner {
            sectionStack.addArrangedSubview(initialBootBanner)
        }

        sectionStack.addArrangedSubview(generalSection)
        sectionStack.addArrangedSubview(resourcesSection)
        sectionStack.addArrangedSubview(storageSection)
        sectionStack.addArrangedSubview(removableSection)
        sectionStack.addArrangedSubview(sharedSection)
        sectionStack.addArrangedSubview(networkSection)
        sectionStack.addArrangedSubview(audioSection)
        if instance.configuration.guestOS == .macOS {
            sectionStack.addArrangedSubview(guestAgentSection)
        }
        sectionStack.addArrangedSubview(clipboardSection)

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(sectionStack)
        NSLayoutConstraint.activate([
            sectionStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 16),
            sectionStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 16),
            sectionStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -16),
            sectionStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -16),
        ])

        let scroll = NSScrollView()
        scroll.documentView = documentView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addFullSizeSubview(scroll)
        view = container

        // Pin each section's width to the document so sections take full available width.
        for section in [
            generalSection, resourcesSection, storageSection, removableSection, sharedSection,
            networkSection, audioSection, guestAgentSection, clipboardSection,
        ] {
            section.widthAnchor.constraint(equalTo: documentView.widthAnchor, constant: -32).isActive = true
        }
        if isReadOnly {
            readOnlyBanner.widthAnchor.constraint(equalTo: documentView.widthAnchor, constant: -32).isActive = true
        }
        if showInitialBootBanner {
            initialBootBanner.widthAnchor.constraint(equalTo: documentView.widthAnchor, constant: -32)
                .isActive = true
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startObserving()
        applyAll()
        Task { @MainActor in
            await instance.refreshDiskUsage()
            await fileMonitor.setPaths(externalAttachmentPaths)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        configObservation?.cancel(); configObservation = nil
        renameObservation?.cancel(); renameObservation = nil
        fileMonitorObservation?.cancel(); fileMonitorObservation = nil
        NotificationCenter.default.removeObserver(
            self, name: NSApplication.didBecomeActiveNotification, object: nil
        )
    }

    // MARK: - Banners

    private func configureReadOnlyBanner() {
        let lockIcon = NSImageView(image: .systemSymbol("lock.fill", accessibilityDescription: ""))
        lockIcon.contentTintColor = .systemOrange

        let label = NSTextField(
            wrappingLabelWithString:
                "Sections marked with a lock icon are locked while the VM is running. "
                + "Stop the VM to change them. Other sections can be edited live."
        )
        label.font = .preferredFont(forTextStyle: .callout)
        label.maximumNumberOfLines = 0
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        readOnlyBanner.setViews([lockIcon, label], in: .leading)
        readOnlyBanner.orientation = .horizontal
        readOnlyBanner.alignment = .top
        readOnlyBanner.spacing = 10
        readOnlyBanner.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        readOnlyBanner.wantsLayer = true
        readOnlyBanner.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.1).cgColor
        readOnlyBanner.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.3).cgColor
        readOnlyBanner.layer?.borderWidth = 1
        readOnlyBanner.layer?.cornerRadius = 8
    }

    private func configureInitialBootBanner() {
        let icon = NSImageView(image: .systemSymbol("sparkles", accessibilityDescription: ""))
        icon.contentTintColor = .systemOrange

        let title = NSTextField(labelWithString: "Initial Boot")
        title.font = .preferredFont(forTextStyle: .headline)

        let subtitle = NSTextField(wrappingLabelWithString: initialBootSubtitle)
        subtitle.font = .preferredFont(forTextStyle: .caption1)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 0

        let textStack = NSStackView(views: [title, subtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        initialBootBanner.setViews([icon, textStack], in: .leading)
        initialBootBanner.orientation = .horizontal
        initialBootBanner.alignment = .top
        initialBootBanner.spacing = 12
        initialBootBanner.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        initialBootBanner.wantsLayer = true
        initialBootBanner.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.1).cgColor
        initialBootBanner.layer?.cornerRadius = 8
    }

    private var initialBootSubtitle: String {
        #if arch(arm64)
        guard let context = instance.configuration.installContext else {
            return "Click Start to install macOS."
        }
        switch context.source {
        case .downloadLatest:
            if instance.hasResumableInstallDownload {
                return "An interrupted download will resume when you click Start."
            }
            return "Click Start to download the latest macOS and install."
        case .localFile:
            let name = context.localIPSWURL?.lastPathComponent ?? "the selected IPSW"
            return "Click Start to install from \(name)."
        }
        #else
        return "Click Start to install macOS."
        #endif
    }

    // MARK: - General section

    private func configureGeneralSection() {
        nameDisplayButton.title = ""
        nameDisplayButton.bezelStyle = .accessoryBarAction
        nameDisplayButton.isBordered = false
        nameDisplayButton.alignment = .right
        nameDisplayButton.target = self
        nameDisplayButton.action = #selector(beginRename(_:))

        nameEditField.placeholderString = "Name"
        nameEditField.target = self
        nameEditField.action = #selector(nameSubmitted(_:))
        nameEditField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            nameEditField.widthAnchor.constraint(equalToConstant: 240)
        ])
        nameEditField.delegate = self

        nameContainer.orientation = .horizontal
        nameContainer.alignment = .centerY
        nameContainer.spacing = 8
        let nameLabel = NSTextField(labelWithString: "Name")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameContainer.setViews([nameLabel, spacer, nameDisplayButton, nameEditField], in: .leading)
        nameContainer.translatesAutoresizingMaskIntoConstraints = false

        let typeValue = NSTextField(labelWithString: instance.configuration.guestOS.displayName)
        typeRow.setViews(
            [
                NSTextField(labelWithString: "Type"),
                spacerView(), typeValue,
            ], in: .leading)
        typeRow.orientation = .horizontal
        typeRow.spacing = 8

        let bootValue = NSTextField(labelWithString: instance.configuration.bootMode.displayName)
        bootModeRow.setViews(
            [
                NSTextField(labelWithString: "Boot Mode"),
                spacerView(), bootValue,
            ], in: .leading)
        bootModeRow.orientation = .horizontal
        bootModeRow.spacing = 8

        let createdValue = NSTextField(
            labelWithString:
                instance.configuration.createdAt.formatted(date: .abbreviated, time: .shortened))
        createdRow.setViews(
            [
                NSTextField(labelWithString: "Created"),
                spacerView(), createdValue,
            ], in: .leading)
        createdRow.orientation = .horizontal
        createdRow.spacing = 8

        generalSection.setBody(stackRows([nameContainer, typeRow, bootModeRow, createdRow]))
    }

    private func spacerView() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return v
    }

    @objc private func beginRename(_ sender: Any?) {
        guard instance.status.canRename else { return }
        viewModel.renameVM(instance)
    }

    @objc private func nameSubmitted(_ sender: Any?) {
        viewModel.commitRename(for: instance, newName: nameEditField.stringValue)
    }

    // MARK: - Resources section

    private func configureResourcesSection() {
        let os = instance.configuration.guestOS

        cpuStepper.minValue = Double(os.minCPUCount)
        cpuStepper.maxValue = Double(os.maxCPUCount)
        cpuStepper.target = self
        cpuStepper.action = #selector(cpuChanged(_:))

        memoryStepper.minValue = Double(os.minMemoryInGB)
        memoryStepper.maxValue = Double(os.maxMemoryInGB)
        memoryStepper.target = self
        memoryStepper.action = #selector(memoryChanged(_:))

        cpuLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        memoryLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        let cpuRow = makeLabeledRow(
            "CPU Cores",
            control: horizontalStack([cpuLabel, cpuStepper], spacing: 6)
        )
        let memRow = makeLabeledRow(
            "Memory",
            control: horizontalStack([memoryLabel, memoryStepper], spacing: 6)
        )
        resourcesSection.setBody(stackRows([cpuRow, memRow]))
    }

    @objc private func cpuChanged(_ sender: NSStepper) {
        viewModel.updateConfiguration(of: instance) { $0.cpuCount = sender.integerValue }
    }

    @objc private func memoryChanged(_ sender: NSStepper) {
        viewModel.updateConfiguration(of: instance) { $0.memorySizeInGB = sender.integerValue }
    }

    // MARK: - Storage section

    private func configureStorageSection() {
        storageRowsContainer.orientation = .vertical
        storageRowsContainer.alignment = .leading
        storageRowsContainer.spacing = 6

        attachDiskButton.target = self
        attachDiskButton.action = #selector(attachStorageDisk(_:))

        createDiskButton.target = self
        createDiskButton.action = #selector(showCreateDiskPopover(_:))

        editBootOrderButton.target = self
        editBootOrderButton.action = #selector(editBootOrder(_:))

        let buttonRow = horizontalStack(
            [attachDiskButton, createDiskButton, editBootOrderButton],
            spacing: 8)

        storageSection.setBody(stackRows([storageRowsContainer, buttonRow]))
    }

    @objc private func attachStorageDisk(_ sender: Any?) {
        let urls = NSOpenPanel.browseDiskImages(
            message: "Select disk images to attach to the VM",
            allowsMultipleSelection: true
        )
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

    @objc private func showCreateDiskPopover(_ sender: NSButton) {
        let content = makeCreateDiskPopover(isRemovable: false)
        createDiskPopover.show(content: content, from: sender, preferredEdge: .maxY)
    }

    @objc private func editBootOrder(_ sender: Any?) {
        guard let window = view.window else { return }
        let sheet = StorageDiskReorderWindowController(
            instance: instance,
            fileMonitor: fileMonitor,
            readDisks: { [weak self] in self?.currentStorageDisks ?? [] },
            writeDisks: { [weak self] disks in self?.writeStorageDisks(disks) }
        )
        Task { await sheet.runSheet(on: window) }
    }

    private var currentStorageDisks: [StorageDisk] {
        if let disks = instance.configuration.storageDisks, !disks.isEmpty {
            return disks
        }
        return VMLibraryViewModel.defaultStorageDisks(for: instance)
    }

    private func writeStorageDisks(_ disks: [StorageDisk]) {
        viewModel.updateConfiguration(of: instance) { config in
            config.storageDisks = disks.isEmpty ? nil : disks
        }
    }

    // MARK: - Removable section

    private func configureRemovableSection() {
        removableRowsContainer.orientation = .vertical
        removableRowsContainer.alignment = .leading
        removableRowsContainer.spacing = 6

        attachRemovableButton.target = self
        attachRemovableButton.action = #selector(attachRemovableMedia(_:))
        createRemovableButton.target = self
        createRemovableButton.action = #selector(showCreateRemovablePopover(_:))

        let buttonRow = horizontalStack(
            [attachRemovableButton, createRemovableButton], spacing: 8)
        removableSection.setBody(stackRows([removableRowsContainer, buttonRow]))
    }

    @objc private func attachRemovableMedia(_ sender: Any?) {
        let urls = NSOpenPanel.browseDiskImages(
            message: "Select disk images to attach to the VM",
            allowsMultipleSelection: true
        )
        guard !urls.isEmpty else { return }
        var current = instance.configuration.removableMedia ?? []
        let existing = Set(current.map(\.path))
        for url in urls {
            let path = url.path(percentEncoded: false)
            guard !existing.contains(path) else { continue }
            current.append(RemovableMediaItem(path: path, readOnly: true))
        }
        writeRemovableMedia(current)
    }

    @objc private func showCreateRemovablePopover(_ sender: NSButton) {
        let content = makeCreateDiskPopover(isRemovable: true)
        createRemovablePopover.show(content: content, from: sender, preferredEdge: .maxY)
    }

    private func writeRemovableMedia(_ items: [RemovableMediaItem]) {
        viewModel.updateConfiguration(of: instance) { config in
            config.removableMedia = items.isEmpty ? nil : items
        }
    }

    // MARK: - Create-disk popover (shared between storage and removable)

    private func makeCreateDiskPopover(isRemovable: Bool) -> NSViewController {
        let vc = NSViewController()
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(
            labelWithString:
                isRemovable ? "Create New Removable Disk" : "Create New Disk")
        title.font = .preferredFont(forTextStyle: .headline)

        let sizePopup = NSPopUpButton()
        for size in VMGuestOS.allDiskSizes {
            let item = NSMenuItem(
                title: DataFormatters.formatDiskSize(size), action: nil, keyEquivalent: ""
            )
            item.representedObject = size
            sizePopup.menu?.addItem(item)
        }
        let initialSize = isRemovable ? newRemovableDiskSize : newStorageDiskSize
        if let idx = VMGuestOS.allDiskSizes.firstIndex(of: initialSize) {
            sizePopup.selectItem(at: idx)
        }
        sizePopup.target = self
        sizePopup.action =
            isRemovable ? #selector(removableSizeChanged(_:)) : #selector(storageSizeChanged(_:))

        let body = NSTextField(
            wrappingLabelWithString:
                isRemovable
                ? "Creates a writable ASIF sparse disk image at a location you choose, attached as a hot-pluggable USB drive. The file lives outside the VM bundle."
                : "Creates an ASIF sparse disk image inside the VM bundle. Physical size grows as data is written."
        )
        body.font = .preferredFont(forTextStyle: .caption1)
        body.textColor = .secondaryLabelColor
        body.maximumNumberOfLines = 0
        body.preferredMaxLayoutWidth = 240

        let cancel = NSButton(
            title: "Cancel", target: self,
            action:
                isRemovable
                ? #selector(cancelRemovableCreate(_:))
                : #selector(cancelStorageCreate(_:)))
        cancel.keyEquivalent = "\u{1B}"
        let confirm = NSButton(
            title: "Create", target: self,
            action:
                isRemovable
                ? #selector(confirmCreateRemovable(_:))
                : #selector(confirmCreateStorage(_:)))
        confirm.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [cancel, spacer, confirm])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY

        let stack = NSStackView(views: [title, sizePopup, body, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            root.widthAnchor.constraint(equalToConstant: 280),
        ])
        vc.view = root
        vc.preferredContentSize = NSSize(width: 280, height: root.fittingSize.height)
        return vc
    }

    @objc private func storageSizeChanged(_ sender: NSPopUpButton) {
        if let size = sender.selectedItem?.representedObject as? Int {
            newStorageDiskSize = size
        }
    }
    @objc private func removableSizeChanged(_ sender: NSPopUpButton) {
        if let size = sender.selectedItem?.representedObject as? Int {
            newRemovableDiskSize = size
        }
    }
    @objc private func cancelStorageCreate(_ sender: Any?) { createDiskPopover.close() }
    @objc private func cancelRemovableCreate(_ sender: Any?) { createRemovablePopover.close() }
    @objc private func confirmCreateStorage(_ sender: Any?) {
        createDiskPopover.close()
        viewModel.createStorageDisk(for: instance, sizeInGB: newStorageDiskSize)
    }
    @objc private func confirmCreateRemovable(_ sender: Any?) {
        createRemovablePopover.close()
        presentSaveRemovableMedia(sizeInGB: newRemovableDiskSize)
    }

    private func presentSaveRemovableMedia(sizeInGB: Int) {
        let panel = NSSavePanel()
        panel.title = "Save Removable Disk"
        panel.message = "Choose where to save the new removable disk image."
        panel.prompt = "Create"
        panel.nameFieldStringValue = "\(instance.name) Removable Disk.asif"
        panel.allowedContentTypes = [.asif]
        panel.canCreateDirectories = true
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = panel.url else { return }
                self.viewModel.createRemovableMedia(
                    for: self.instance, sizeInGB: sizeInGB, destinationURL: url)
            }
        }
    }

    // MARK: - Shared directories section

    private func configureSharedSection() {
        sharedRowsContainer.orientation = .vertical
        sharedRowsContainer.alignment = .leading
        sharedRowsContainer.spacing = 6
        addSharedButton.target = self
        addSharedButton.action = #selector(addSharedDirectory(_:))
        sharedSection.setBody(stackRows([sharedRowsContainer, addSharedButton]))
    }

    @objc private func addSharedDirectory(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Select directories to share with the VM"
        panel.prompt = "Share"
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK else { return }
                var current = self.instance.configuration.sharedDirectories ?? []
                let existing = Set(current.map(\.path))
                for url in panel.urls {
                    let path = url.path(percentEncoded: false)
                    guard !existing.contains(path) else { continue }
                    current.append(SharedDirectory(path: path))
                }
                self.viewModel.updateConfiguration(of: self.instance) { config in
                    config.sharedDirectories = current.isEmpty ? nil : current
                }
            }
        }
    }

    // MARK: - Network section

    private func configureNetworkSection() {
        networkToggle.target = self
        networkToggle.action = #selector(networkToggleChanged(_:))
        let toggleRow = makeLabeledRow("Networking Enabled", control: networkToggle)

        macAddressLabel.font = .monospacedSystemFont(
            ofSize: NSFont.systemFontSize, weight: .regular)
        macAddressLabel.isSelectable = true
        macAddressRow.setViews(
            [
                NSTextField(labelWithString: "MAC Address"),
                spacerView(), macAddressLabel,
            ], in: .leading)
        macAddressRow.orientation = .horizontal
        macAddressRow.spacing = 8

        networkSection.setBody(stackRows([toggleRow, macAddressRow]))
    }

    @objc private func networkToggleChanged(_ sender: NSSwitch) {
        viewModel.updateConfiguration(of: instance) { $0.networkEnabled = sender.state == .on }
    }

    // MARK: - Audio section

    private func configureAudioSection() {
        micToggle.target = self
        micToggle.action = #selector(micToggleChanged(_:))
        let toggleRow = makeLabeledRow("Microphone", control: micToggle)

        micNotDeterminedLabel.stringValue =
            "macOS will ask for microphone permission the first time a VM uses it."
        micNotDeterminedLabel.font = .preferredFont(forTextStyle: .caption1)
        micNotDeterminedLabel.textColor = .secondaryLabelColor
        micNotDeterminedLabel.isHidden = true
        micNotDeterminedLabel.maximumNumberOfLines = 0
        micNotDeterminedLabel.lineBreakMode = .byWordWrapping
        micNotDeterminedLabel.preferredMaxLayoutWidth = 400

        let denyIcon = NSImageView(
            image: .systemSymbol("exclamationmark.triangle.fill", accessibilityDescription: ""))
        denyIcon.contentTintColor = .systemRed
        let denyLabel = NSTextField(
            wrappingLabelWithString:
                "Microphone permission is denied. Enable it in System Settings for Kernova to pass your microphone to VMs."
        )
        denyLabel.font = .preferredFont(forTextStyle: .caption1)
        denyLabel.maximumNumberOfLines = 0
        denyLabel.preferredMaxLayoutWidth = 380
        denyLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        denyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let openSettings = NSButton(
            title: "Open Privacy Settings", target: self,
            action: #selector(openMicSettings(_:)))
        openSettings.controlSize = .small
        micDeniedBanner.setViews([denyIcon, denyLabel, openSettings], in: .leading)
        micDeniedBanner.orientation = .horizontal
        micDeniedBanner.alignment = .centerY
        micDeniedBanner.spacing = 8
        micDeniedBanner.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        micDeniedBanner.wantsLayer = true
        micDeniedBanner.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.1).cgColor
        micDeniedBanner.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.3).cgColor
        micDeniedBanner.layer?.borderWidth = 1
        micDeniedBanner.layer?.cornerRadius = 8
        micDeniedBanner.isHidden = true

        audioSection.setBody(stackRows([toggleRow, micNotDeterminedLabel, micDeniedBanner]))
    }

    @objc private func micToggleChanged(_ sender: NSSwitch) {
        viewModel.updateConfiguration(of: instance) { $0.microphoneEnabled = sender.state == .on }
        refreshMicPermission()
    }

    @objc private func openMicSettings(_ sender: Any?) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func applicationDidBecomeActive(_ note: Notification) {
        refreshMicPermission()
    }

    private func refreshMicPermission() {
        micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
        applyMicPermission()
    }

    private func applyMicPermission() {
        let enabled = instance.configuration.microphoneEnabled
        micNotDeterminedLabel.isHidden = !(enabled && micPermission == .notDetermined)
        micDeniedBanner.isHidden = !(enabled && (micPermission == .denied || micPermission == .restricted))
    }

    // MARK: - Guest agent + clipboard

    private func configureGuestAgentSection() {
        agentLogToggle.target = self
        agentLogToggle.action = #selector(agentLogChanged(_:))
        agentNudgeToggle.target = self
        agentNudgeToggle.action = #selector(agentNudgeChanged(_:))

        let row1 = makeLabeledRow("Forward guest logs", control: agentLogToggle)
        let row2 = makeLabeledRow("Show install reminder", control: agentNudgeToggle)
        guestAgentSection.setBody(stackRows([row1, row2]))
    }

    @objc private func agentLogChanged(_ sender: NSSwitch) {
        viewModel.updateConfiguration(of: instance) { $0.agentLogForwardingEnabled = sender.state == .on }
    }
    @objc private func agentNudgeChanged(_ sender: NSSwitch) {
        viewModel.updateConfiguration(of: instance) {
            $0.agentInstallNudgeDismissed = !(sender.state == .on)
        }
    }

    private func configureClipboardSection() {
        clipboardToggle.target = self
        clipboardToggle.action = #selector(clipboardChanged(_:))
        clipboardLinuxHint.font = .preferredFont(forTextStyle: .caption1)
        clipboardLinuxHint.textColor = .systemOrange
        clipboardLinuxHint.stringValue =
            "Takes effect on next start — Linux guests configure SPICE at VM start time."
        clipboardLinuxHint.isHidden = true
        clipboardLinuxHint.maximumNumberOfLines = 0
        clipboardLinuxHint.lineBreakMode = .byWordWrapping
        clipboardLinuxHint.preferredMaxLayoutWidth = 400

        let row = makeLabeledRow("Clipboard Sharing", control: clipboardToggle)
        clipboardSection.setBody(stackRows([row, clipboardLinuxHint]))
    }

    @objc private func clipboardChanged(_ sender: NSSwitch) {
        viewModel.updateConfiguration(of: instance) {
            $0.clipboardSharingEnabled = sender.state == .on
        }
    }

    // MARK: - Observation

    private func startObserving() {
        configObservation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = self.instance.name
                _ = self.instance.status
                _ = self.instance.configuration
                _ = self.instance.cachedDiskUsageBytes
            },
            apply: { [weak self] in self?.applyAll() }
        )
        renameObservation = observeRecurring(
            track: { [weak self] in _ = self?.viewModel.activeRename },
            apply: { [weak self] in self?.applyRenameState() }
        )
        fileMonitorObservation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = self.instance.configuration.storageDisks
                _ = self.instance.configuration.removableMedia
            },
            apply: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    await self.fileMonitor.setPaths(self.externalAttachmentPaths)
                }
                self.refreshStorageRows()
                self.refreshRemovableRows()
            }
        )
    }

    private func applyAll() {
        applyGeneral()
        applyResources()
        refreshStorageRows()
        refreshRemovableRows()
        refreshSharedRows()
        applyNetwork()
        applyAudio()
        applyGuestAgent()
        applyClipboard()
        applyLockStates()
        applyRenameState()
        didApplyInitial = true
    }

    private func applyLockStates() {
        // Lockable sections: Resources, Storage, Shared, Network, Audio.
        // Hot-toggleable sections (Removable, Guest Agent, Clipboard) carry no lock.
        for section in [resourcesSection, storageSection, sharedSection, networkSection, audioSection] {
            section.setLocked(isReadOnly)
        }
        // Disable controls inside lockable sections when read-only.
        let lockedDisabled = isReadOnly
        cpuStepper.isEnabled = !lockedDisabled
        memoryStepper.isEnabled = !lockedDisabled
        attachDiskButton.isEnabled = !lockedDisabled
        createDiskButton.isEnabled = !lockedDisabled
        editBootOrderButton.isEnabled = !lockedDisabled
        addSharedButton.isEnabled = !lockedDisabled
        networkToggle.isEnabled = !lockedDisabled
        micToggle.isEnabled = !lockedDisabled
        // Storage / shared row remove buttons are wired with isEnabled in the
        // row constructors below; they read isReadOnly directly.
    }

    private func applyGeneral() {
        nameDisplayButton.title = instance.name
        nameDisplayButton.isEnabled = instance.status.canRename
        applyRenameState()
    }

    private func applyRenameState() {
        let isRenaming = viewModel.activeRename == .detail(instance.id)
        nameDisplayButton.isHidden = isRenaming
        nameEditField.isHidden = !isRenaming
        if isRenaming, didApplyInitial {
            if nameEditField.stringValue != instance.name {
                nameEditField.stringValue = instance.name
            }
            view.window?.makeFirstResponder(nameEditField)
        }
    }

    private func applyResources() {
        cpuStepper.integerValue = instance.configuration.cpuCount
        cpuLabel.stringValue = "\(instance.configuration.cpuCount) cores"
        memoryStepper.integerValue = instance.configuration.memorySizeInGB
        memoryLabel.stringValue = "\(instance.configuration.memorySizeInGB) GB"
    }

    private func applyNetwork() {
        networkToggle.state = instance.configuration.networkEnabled ? .on : .off
        if let mac = instance.configuration.macAddress {
            macAddressLabel.stringValue = mac
            macAddressRow.isHidden = false
        } else {
            macAddressRow.isHidden = true
        }
    }

    private func applyAudio() {
        micToggle.state = instance.configuration.microphoneEnabled ? .on : .off
        refreshMicPermission()
    }

    private func applyGuestAgent() {
        agentLogToggle.state = instance.configuration.agentLogForwardingEnabled ? .on : .off
        agentNudgeToggle.state = instance.configuration.agentInstallNudgeDismissed ? .off : .on
    }

    private func applyClipboard() {
        clipboardToggle.state = instance.configuration.clipboardSharingEnabled ? .on : .off
        clipboardLinuxHint.isHidden = !(isReadOnly && instance.configuration.guestOS == .linux)
    }

    // MARK: - Row builders for lists

    private func refreshStorageRows() {
        let disks = currentStorageDisks
        for view in storageRowsContainer.arrangedSubviews {
            view.removeFromSuperview()
        }
        if disks.isEmpty {
            let empty = NSTextField(labelWithString: "No storage disks")
            empty.textColor = .secondaryLabelColor
            storageRowsContainer.addArrangedSubview(empty)
        } else {
            for disk in disks {
                storageRowsContainer.addArrangedSubview(makeStorageDiskRow(disk: disk))
            }
        }
        editBootOrderButton.isHidden = disks.count <= 1
    }

    private func makeStorageDiskRow(disk: StorageDisk) -> NSView {
        let isMissing = !disk.isInternal && !fileMonitor.exists(disk.path)
        let icon = AttachmentIconButton()
        icon.configure(
            systemName: diskIconSystemName(for: disk),
            missingPath: isMissing ? disk.path : nil
        )

        let label = NSTextField(labelWithString: disk.label)
        label.font = .preferredFont(forTextStyle: .body)

        let subtitle = makeAttachmentSubtitleLabel(
            path: diskSubtitle(for: disk, in: instance),
            isMissing: isMissing
        )

        let textStack = NSStackView(views: [label, subtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let toggle = NSSwitch()
        toggle.state = disk.readOnly ? .on : .off
        toggle.isEnabled = !isReadOnly
        toggle.target = self
        toggle.action = #selector(storageReadOnlyToggled(_:))
        toggle.identifier = NSUserInterfaceItemIdentifier(disk.id.uuidString)

        let toggleLabel = NSTextField(labelWithString: "Read Only")
        toggleLabel.font = .preferredFont(forTextStyle: .caption1)
        toggleLabel.textColor = .secondaryLabelColor

        let removeButton = NSButton(
            image: .systemSymbol("minus.circle.fill", accessibilityDescription: "Remove"),
            target: self,
            action: #selector(removeStorageDiskTapped(_:))
        )
        removeButton.isBordered = false
        removeButton.contentTintColor = .systemRed
        removeButton.isEnabled = !isReadOnly
        removeButton.identifier = NSUserInterfaceItemIdentifier(disk.id.uuidString)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [icon, textStack, spacer, toggle, toggleLabel, removeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    @objc private func storageReadOnlyToggled(_ sender: NSSwitch) {
        guard let idString = sender.identifier?.rawValue,
            let id = UUID(uuidString: idString)
        else { return }
        var current = currentStorageDisks
        guard let index = current.firstIndex(where: { $0.id == id }) else { return }
        current[index].readOnly = sender.state == .on
        writeStorageDisks(current)
    }

    @objc private func removeStorageDiskTapped(_ sender: NSButton) {
        guard let window = view.window,
            let idString = sender.identifier?.rawValue,
            let id = UUID(uuidString: idString),
            let disk = currentStorageDisks.first(where: { $0.id == id })
        else { return }

        let message: String =
            disk.isInternal
            ? "Move to Trash will send the bundle-owned disk image to the Trash. Remove from VM will delist the entry while keeping the file."
            : "Move to Trash will send \(disk.path) to the Trash. Remove from VM will delist the disk and leave the file alone."

        AlertPresenter.present(
            in: window,
            title: "Remove \(disk.label)?",
            message: message,
            style: .warning,
            buttons: [
                .destructive("Move to Trash"),
                .plain("Remove from VM"),
                .cancel(),
            ]
        ) { [weak self] index in
            guard let self else { return }
            switch index {
            case 0: self.viewModel.removeStorageDisk(disk, from: self.instance, trashFile: true)
            case 1: self.viewModel.removeStorageDisk(disk, from: self.instance, trashFile: false)
            default: break
            }
        }
    }

    private func refreshRemovableRows() {
        let items = instance.configuration.removableMedia ?? []
        for view in removableRowsContainer.arrangedSubviews {
            view.removeFromSuperview()
        }
        if items.isEmpty {
            let empty = NSTextField(labelWithString: "No removable media attached")
            empty.textColor = .secondaryLabelColor
            removableRowsContainer.addArrangedSubview(empty)
        } else {
            for item in items {
                removableRowsContainer.addArrangedSubview(makeRemovableRow(item: item))
            }
        }
    }

    private func makeRemovableRow(item: RemovableMediaItem) -> NSView {
        let isMissing = !fileMonitor.exists(item.path)
        let icon = AttachmentIconButton()
        icon.configure(
            systemName: "opticaldisc",
            missingPath: isMissing ? item.path : nil
        )

        let label = NSTextField(labelWithString: item.label)
        label.font = .preferredFont(forTextStyle: .body)
        let subtitle = makeAttachmentSubtitleLabel(path: item.path, isMissing: isMissing)
        let textStack = NSStackView(views: [label, subtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let toggle = NSSwitch()
        toggle.state = item.readOnly ? .on : .off
        toggle.target = self
        toggle.action = #selector(removableReadOnlyToggled(_:))
        toggle.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)

        let toggleLabel = NSTextField(labelWithString: "Read Only")
        toggleLabel.font = .preferredFont(forTextStyle: .caption1)
        toggleLabel.textColor = .secondaryLabelColor

        let removeButton = NSButton(
            image: .systemSymbol("minus.circle.fill", accessibilityDescription: "Remove"),
            target: self,
            action: #selector(removeRemovableMediaTapped(_:))
        )
        removeButton.isBordered = false
        removeButton.contentTintColor = .systemRed
        removeButton.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [icon, textStack, spacer, toggle, toggleLabel, removeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    @objc private func removableReadOnlyToggled(_ sender: NSSwitch) {
        guard let idString = sender.identifier?.rawValue,
            let id = UUID(uuidString: idString)
        else { return }
        var current = instance.configuration.removableMedia ?? []
        guard let index = current.firstIndex(where: { $0.id == id }) else { return }
        current[index].readOnly = sender.state == .on
        writeRemovableMedia(current)
    }

    @objc private func removeRemovableMediaTapped(_ sender: NSButton) {
        guard let window = view.window,
            let idString = sender.identifier?.rawValue,
            let id = UUID(uuidString: idString),
            let item = (instance.configuration.removableMedia ?? []).first(where: { $0.id == id })
        else { return }

        AlertPresenter.present(
            in: window,
            title: "Remove \(item.label)?",
            message:
                "Move to Trash will send \(item.path) to the Trash. Remove from VM will detach the disc and leave the file alone.",
            style: .warning,
            buttons: [
                .destructive("Move to Trash"),
                .plain("Remove from VM"),
                .cancel(),
            ]
        ) { [weak self] index in
            guard let self else { return }
            switch index {
            case 0: self.viewModel.removeRemovableMedia(item, from: self.instance, trashFile: true)
            case 1: self.viewModel.removeRemovableMedia(item, from: self.instance, trashFile: false)
            default: break
            }
        }
    }

    private func refreshSharedRows() {
        let dirs = instance.configuration.sharedDirectories ?? []
        for view in sharedRowsContainer.arrangedSubviews {
            view.removeFromSuperview()
        }
        if dirs.isEmpty {
            let empty = NSTextField(labelWithString: "No shared directories")
            empty.textColor = .secondaryLabelColor
            sharedRowsContainer.addArrangedSubview(empty)
        } else {
            for dir in dirs {
                sharedRowsContainer.addArrangedSubview(makeSharedRow(dir: dir))
            }
        }
    }

    private func makeSharedRow(dir: SharedDirectory) -> NSView {
        let icon = NSImageView(
            image: .systemSymbol("folder", accessibilityDescription: ""))
        icon.contentTintColor = .secondaryLabelColor

        let label = NSTextField(labelWithString: dir.displayName)
        label.font = .preferredFont(forTextStyle: .body)
        let pathLabel = NSTextField(labelWithString: dir.path)
        pathLabel.font = .preferredFont(forTextStyle: .caption1)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1

        let textStack = NSStackView(views: [label, pathLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let toggle = NSSwitch()
        toggle.state = dir.readOnly ? .on : .off
        toggle.isEnabled = !isReadOnly
        toggle.target = self
        toggle.action = #selector(sharedReadOnlyToggled(_:))
        toggle.identifier = NSUserInterfaceItemIdentifier(dir.id.uuidString)

        let toggleLabel = NSTextField(labelWithString: "Read Only")
        toggleLabel.font = .preferredFont(forTextStyle: .caption1)
        toggleLabel.textColor = .secondaryLabelColor

        let removeButton = NSButton(
            image: .systemSymbol("minus.circle.fill", accessibilityDescription: "Remove"),
            target: self,
            action: #selector(removeSharedDirTapped(_:))
        )
        removeButton.isBordered = false
        removeButton.contentTintColor = .systemRed
        removeButton.isEnabled = !isReadOnly
        removeButton.identifier = NSUserInterfaceItemIdentifier(dir.id.uuidString)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [icon, textStack, spacer, toggle, toggleLabel, removeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    @objc private func sharedReadOnlyToggled(_ sender: NSSwitch) {
        guard let idString = sender.identifier?.rawValue,
            let id = UUID(uuidString: idString)
        else { return }
        var current = instance.configuration.sharedDirectories ?? []
        guard let index = current.firstIndex(where: { $0.id == id }) else { return }
        current[index].readOnly = sender.state == .on
        viewModel.updateConfiguration(of: instance) { config in
            config.sharedDirectories = current.isEmpty ? nil : current
        }
    }

    @objc private func removeSharedDirTapped(_ sender: NSButton) {
        guard let idString = sender.identifier?.rawValue,
            let id = UUID(uuidString: idString)
        else { return }
        var current = instance.configuration.sharedDirectories ?? []
        current.removeAll { $0.id == id }
        viewModel.updateConfiguration(of: instance) { config in
            config.sharedDirectories = current.isEmpty ? nil : current
        }
    }

    // MARK: - Helpers

    private var externalAttachmentPaths: Set<String> {
        var paths: Set<String> = []
        if let disks = instance.configuration.storageDisks {
            for disk in disks where !disk.isInternal {
                paths.insert(disk.path)
            }
        }
        if let media = instance.configuration.removableMedia {
            for item in media {
                paths.insert(item.path)
            }
        }
        return paths
    }

    private func stackRows(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    private func horizontalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }
}

// MARK: - NSTextFieldDelegate (rename flow)

extension VMSettingsViewController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard obj.object as? NSTextField === nameEditField else { return }
        // Treat Esc as cancel: NSTextField sets `NSTextMovementUserInfoKey` to
        // `NSTextMovement.cancel.rawValue` in the userInfo when the field
        // editor exited via the Escape key.
        if let movementInt = obj.userInfo?["NSTextMovement"] as? Int,
            let movement = NSTextMovement(rawValue: movementInt),
            movement == .cancel
        {
            viewModel.cancelRename()
            return
        }
        viewModel.commitRename(for: instance, newName: nameEditField.stringValue)
    }
}
