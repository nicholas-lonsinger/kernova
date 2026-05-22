import AppKit

/// Shared Directories section: bind a host folder into the guest via virtiofs.
@MainActor
final class SharedDirectoriesSettingsSection: NSObject {
    let section = SettingsSection(title: "Shared Directories", lockable: true)

    private let instance: VMInstance
    private let viewModel: VMLibraryViewModel
    private let isReadOnly: Bool

    private let rowsContainer = NSStackView()
    private let addButton = NSButton(title: "Add Shared Directory…", target: nil, action: nil)

    private var observation: ObservationLoop?

    init(instance: VMInstance, viewModel: VMLibraryViewModel, isReadOnly: Bool) {
        self.instance = instance
        self.viewModel = viewModel
        self.isReadOnly = isReadOnly
        super.init()
        configure()
    }

    func startObserving() {
        observation = observeRecurring(
            track: { [weak self] in _ = self?.instance.configuration.sharedDirectories },
            apply: { [weak self] in self?.apply() }
        )
        apply()
    }

    func stopObserving() {
        observation?.cancel()
        observation = nil
    }

    // MARK: - Internals

    private func configure() {
        rowsContainer.orientation = .vertical
        rowsContainer.alignment = .leading
        rowsContainer.spacing = 6
        addButton.target = self
        addButton.action = #selector(addTapped(_:))
        addButton.isEnabled = !isReadOnly
        section.setBody(settingsStackRows([rowsContainer, addButton]))
        section.setLocked(isReadOnly)
    }

    private func apply() {
        let dirs = instance.configuration.sharedDirectories ?? []
        for view in rowsContainer.arrangedSubviews {
            view.removeFromSuperview()
        }
        if dirs.isEmpty {
            let empty = NSTextField(labelWithString: "No shared directories")
            empty.textColor = .secondaryLabelColor
            rowsContainer.addArrangedSubview(empty)
        } else {
            for dir in dirs {
                rowsContainer.addArrangedSubview(makeRow(dir: dir))
            }
        }
    }

    private func makeRow(dir: SharedDirectory) -> NSView {
        let icon = NSImageView(
            image: .systemSymbol("folder", accessibilityDescription: ""))
        icon.contentTintColor = .secondaryLabelColor

        let pathLabel = NSTextField(labelWithString: dir.path)
        pathLabel.font = .preferredFont(forTextStyle: .caption1)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1

        let dirID = dir.id
        return AttachmentRowView(
            icon: icon,
            title: dir.displayName,
            subtitle: pathLabel,
            readOnly: dir.readOnly,
            isReadOnlyEnabled: !isReadOnly,
            isRemoveEnabled: !isReadOnly,
            onToggleReadOnly: { [weak self] newState in
                self?.setReadOnly(id: dirID, readOnly: newState)
            },
            onRemove: { [weak self] in
                self?.remove(id: dirID)
            }
        )
    }

    private func setReadOnly(id: UUID, readOnly newValue: Bool) {
        var current = instance.configuration.sharedDirectories ?? []
        guard let index = current.firstIndex(where: { $0.id == id }) else { return }
        current[index].readOnly = newValue
        viewModel.updateConfiguration(of: instance) { config in
            config.sharedDirectories = current.isEmpty ? nil : current
        }
    }

    private func remove(id: UUID) {
        var current = instance.configuration.sharedDirectories ?? []
        current.removeAll { $0.id == id }
        viewModel.updateConfiguration(of: instance) { config in
            config.sharedDirectories = current.isEmpty ? nil : current
        }
    }

    @objc private func addTapped(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Select directories to share with the VM"
        panel.prompt = "Share"
        guard let window = section.window else { return }
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
}
