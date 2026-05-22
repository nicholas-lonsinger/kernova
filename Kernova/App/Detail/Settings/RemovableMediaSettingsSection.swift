import AppKit

/// Removable Media section: hot-pluggable disc images.
@MainActor
final class RemovableMediaSettingsSection: NSObject {
    let section = SettingsSection(title: "Removable Media")

    private let instance: VMInstance
    private let viewModel: VMLibraryViewModel
    private let fileMonitor: AttachmentFileMonitor

    private let rowsContainer = NSStackView()
    private let attachButton = NSButton(title: "Attach Disc…", target: nil, action: nil)
    private let createButton = NSButton(title: "Create New Disk…", target: nil, action: nil)
    private let createPopover = PopoverPresenter()
    private var newRemovableDiskSize: Int = VMGuestOS.defaultDiskSizeInGB

    private var observation: ObservationLoop?

    init(
        instance: VMInstance,
        viewModel: VMLibraryViewModel,
        fileMonitor: AttachmentFileMonitor
    ) {
        self.instance = instance
        self.viewModel = viewModel
        self.fileMonitor = fileMonitor
        super.init()
        configure()
    }

    func startObserving() {
        observation = observeRecurring(
            track: { [weak self] in _ = self?.instance.configuration.removableMedia },
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
        (instance.configuration.removableMedia ?? []).map(\.path)
    }

    // MARK: - Internals

    private func configure() {
        rowsContainer.orientation = .vertical
        rowsContainer.alignment = .leading
        rowsContainer.spacing = 6

        attachButton.target = self
        attachButton.action = #selector(attachTapped(_:))

        createButton.target = self
        createButton.action = #selector(showCreatePopover(_:))

        let buttonRow = settingsHorizontalStack([attachButton, createButton], spacing: 8)
        section.setBody(settingsStackRows([rowsContainer, buttonRow]))
    }

    private func apply() {
        let items = instance.configuration.removableMedia ?? []
        for view in rowsContainer.arrangedSubviews {
            view.removeFromSuperview()
        }
        if items.isEmpty {
            let empty = NSTextField(labelWithString: "No removable media attached")
            empty.textColor = .secondaryLabelColor
            rowsContainer.addArrangedSubview(empty)
        } else {
            for item in items {
                rowsContainer.addArrangedSubview(makeRow(item: item))
            }
        }
    }

    private func writeRemovableMedia(_ items: [RemovableMediaItem]) {
        viewModel.updateConfiguration(of: instance) { config in
            config.removableMedia = items.isEmpty ? nil : items
        }
    }

    private func makeRow(item: RemovableMediaItem) -> NSView {
        let isMissing = !fileMonitor.exists(item.path)
        let icon = AttachmentIconButton()
        icon.configure(
            systemName: "opticaldisc",
            missingPath: isMissing ? item.path : nil
        )
        let subtitle = makeAttachmentSubtitleLabel(path: item.path, isMissing: isMissing)
        let itemID = item.id
        let itemLabel = item.label
        return AttachmentRowView(
            icon: icon,
            title: itemLabel,
            subtitle: subtitle,
            readOnly: item.readOnly,
            onToggleReadOnly: { [weak self] newState in
                self?.setReadOnly(id: itemID, readOnly: newState)
            },
            onRemove: { [weak self] in
                self?.promptRemove(id: itemID, label: itemLabel)
            }
        )
    }

    private func setReadOnly(id: UUID, readOnly newValue: Bool) {
        var current = instance.configuration.removableMedia ?? []
        guard let index = current.firstIndex(where: { $0.id == id }) else { return }
        current[index].readOnly = newValue
        writeRemovableMedia(current)
    }

    private func promptRemove(id: UUID, label: String) {
        guard let window = section.window,
            let item = (instance.configuration.removableMedia ?? []).first(where: { $0.id == id })
        else { return }
        AlertPresenter.present(
            in: window,
            title: "Remove \(label)?",
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

    // MARK: - Actions

    @objc private func attachTapped(_ sender: Any?) {
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

    @objc private func showCreatePopover(_ sender: NSButton) {
        let content = CreateDiskPopoverController(
            isRemovable: true,
            initialSize: newRemovableDiskSize,
            onCancel: { [weak self] in self?.createPopover.close() },
            onCreate: { [weak self] size in
                guard let self else { return }
                self.newRemovableDiskSize = size
                self.createPopover.close()
                self.presentSavePanel(sizeInGB: size)
            }
        )
        createPopover.show(content: content, from: sender, preferredEdge: .maxY)
    }

    private func presentSavePanel(sizeInGB: Int) {
        let panel = NSSavePanel()
        panel.title = "Save Removable Disk"
        panel.message = "Choose where to save the new removable disk image."
        panel.prompt = "Create"
        panel.nameFieldStringValue = "\(instance.name) Removable Disk.asif"
        panel.allowedContentTypes = [.asif]
        panel.canCreateDirectories = true
        guard let window = section.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = panel.url else { return }
                self.viewModel.createRemovableMedia(
                    for: self.instance, sizeInGB: sizeInGB, destinationURL: url)
            }
        }
    }
}
