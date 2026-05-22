import AppKit

/// Storage Disks section: lists bundle-owned + attached disk images, with
/// "Attach Disc", "Create New Disk", and "Edit Boot Order" affordances.
@MainActor
final class StorageSettingsSection: NSObject {
    let section = SettingsSection(title: "Storage Disks", lockable: true)

    private let instance: VMInstance
    private let viewModel: VMLibraryViewModel
    private let isReadOnly: Bool
    private let fileMonitor: AttachmentFileMonitor

    private let rowsContainer = NSStackView()
    private let attachButton = NSButton(title: "Attach Disc…", target: nil, action: nil)
    private let createButton = NSButton(title: "Create New Disk…", target: nil, action: nil)
    private let editBootOrderButton = NSButton(title: "Edit Boot Order…", target: nil, action: nil)
    private let createPopover = PopoverPresenter()
    private var newStorageDiskSize: Int = VMGuestOS.defaultDiskSizeInGB

    private var observation: ObservationLoop?

    init(
        instance: VMInstance,
        viewModel: VMLibraryViewModel,
        isReadOnly: Bool,
        fileMonitor: AttachmentFileMonitor
    ) {
        self.instance = instance
        self.viewModel = viewModel
        self.isReadOnly = isReadOnly
        self.fileMonitor = fileMonitor
        super.init()
        configure()
    }

    func startObserving() {
        observation = observeRecurring(
            track: { [weak self] in _ = self?.instance.configuration.storageDisks },
            apply: { [weak self] in self?.apply() }
        )
        apply()
    }

    func stopObserving() {
        observation?.cancel()
        observation = nil
    }

    /// Paths the parent uses to drive the file monitor.
    var externalPaths: [String] {
        currentStorageDisks.filter { !$0.isInternal }.map(\.path)
    }

    // MARK: - Internals

    private func configure() {
        rowsContainer.orientation = .vertical
        rowsContainer.alignment = .leading
        rowsContainer.spacing = 6

        attachButton.target = self
        attachButton.action = #selector(attachTapped(_:))
        attachButton.isEnabled = !isReadOnly

        createButton.target = self
        createButton.action = #selector(showCreatePopover(_:))
        createButton.isEnabled = !isReadOnly

        editBootOrderButton.target = self
        editBootOrderButton.action = #selector(editBootOrderTapped(_:))
        editBootOrderButton.isEnabled = !isReadOnly

        let buttonRow = settingsHorizontalStack(
            [attachButton, createButton, editBootOrderButton], spacing: 8)
        section.setBody(settingsStackRows([rowsContainer, buttonRow]))
        section.setLocked(isReadOnly)
    }

    private func apply() {
        let disks = currentStorageDisks
        for view in rowsContainer.arrangedSubviews {
            view.removeFromSuperview()
        }
        if disks.isEmpty {
            let empty = NSTextField(labelWithString: "No storage disks")
            empty.textColor = .secondaryLabelColor
            rowsContainer.addArrangedSubview(empty)
        } else {
            for disk in disks {
                rowsContainer.addArrangedSubview(makeRow(disk: disk))
            }
        }
        editBootOrderButton.isHidden = disks.count <= 1
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

    private func makeRow(disk: StorageDisk) -> NSView {
        let isMissing = !disk.isInternal && !fileMonitor.exists(disk.path)
        let icon = AttachmentIconButton()
        icon.configure(
            systemName: diskIconSystemName(for: disk),
            missingPath: isMissing ? disk.path : nil
        )
        let subtitle = makeAttachmentSubtitleLabel(
            path: diskSubtitle(for: disk, in: instance),
            isMissing: isMissing
        )
        let diskID = disk.id
        let diskLabel = disk.label
        return AttachmentRowView(
            icon: icon,
            title: diskLabel,
            subtitle: subtitle,
            readOnly: disk.readOnly,
            isReadOnlyEnabled: !isReadOnly,
            isRemoveEnabled: !isReadOnly,
            onToggleReadOnly: { [weak self] newState in
                self?.setReadOnly(id: diskID, readOnly: newState)
            },
            onRemove: { [weak self] in
                self?.promptRemove(id: diskID, label: diskLabel)
            }
        )
    }

    private func setReadOnly(id: UUID, readOnly newValue: Bool) {
        var current = currentStorageDisks
        guard let index = current.firstIndex(where: { $0.id == id }) else { return }
        current[index].readOnly = newValue
        writeStorageDisks(current)
    }

    private func promptRemove(id: UUID, label: String) {
        guard let window = section.window,
            let disk = currentStorageDisks.first(where: { $0.id == id })
        else { return }
        let message: String =
            disk.isInternal
            ? "Move to Trash will send the bundle-owned disk image to the Trash. Remove from VM will delist the entry while keeping the file."
            : "Move to Trash will send \(disk.path) to the Trash. Remove from VM will delist the disk and leave the file alone."

        AlertPresenter.present(
            in: window,
            title: "Remove \(label)?",
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

    // MARK: - Actions

    @objc private func attachTapped(_ sender: Any?) {
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

    @objc private func showCreatePopover(_ sender: NSButton) {
        let content = CreateDiskPopoverController(
            isRemovable: false,
            initialSize: newStorageDiskSize,
            onCancel: { [weak self] in self?.createPopover.close() },
            onCreate: { [weak self] size in
                guard let self else { return }
                self.newStorageDiskSize = size
                self.createPopover.close()
                self.viewModel.createStorageDisk(for: self.instance, sizeInGB: size)
            }
        )
        createPopover.show(content: content, from: sender, preferredEdge: .maxY)
    }

    @objc private func editBootOrderTapped(_ sender: Any?) {
        guard let window = section.window else { return }
        let sheet = StorageDiskReorderWindowController(
            instance: instance,
            fileMonitor: fileMonitor,
            readDisks: { [weak self] in self?.currentStorageDisks ?? [] },
            writeDisks: { [weak self] disks in self?.writeStorageDisks(disks) }
        )
        Task { await sheet.runSheet(on: window) }
    }
}
