import AppKit

/// Step 4: Review the VM configuration before creation.
@MainActor
final class ReviewStepViewController: CreationStepViewController {
    private let grid = NSGridView(numberOfColumns: 2, rows: 0)
    private let startToggle = NSButton(checkboxWithTitle: "Start this VM after creation", target: nil, action: nil)
    private var observation: ObservationLoop?

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let header = makeStepHeader(
            title: "Review Configuration",
            subtitle: "Review your virtual machine settings before creating it."
        )

        grid.columnSpacing = 16
        grid.rowSpacing = 6
        grid.translatesAutoresizingMaskIntoConstraints = false
        if let labelColumn = grid.column(at: 0) as NSGridColumn? {
            labelColumn.xPlacement = .trailing
        }

        startToggle.target = self
        startToggle.action = #selector(startToggleChanged(_:))
        startToggle.state = creationVM.startAfterCreate ? .on : .off

        let outer = NSStackView(views: [header, grid, startToggle])
        outer.orientation = .vertical
        outer.alignment = .centerX
        outer.spacing = 20
        outer.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: container.topAnchor),
            outer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        view = container
    }

    override func stepDidAppear() {
        observation?.cancel()
        observation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = self.creationVM.vmName
                _ = self.creationVM.selectedOS
                _ = self.creationVM.effectiveBootMode
                _ = self.creationVM.cpuCount
                _ = self.creationVM.memoryInGB
                _ = self.creationVM.diskSizeInGB
                _ = self.creationVM.networkEnabled
                _ = self.creationVM.ipswSource
                _ = self.creationVM.ipswPath
                _ = self.creationVM.ipswDownloadPath
                _ = self.creationVM.isoPath
                _ = self.creationVM.kernelPath
                _ = self.creationVM.startAfterCreate
            },
            apply: { [weak self] in self?.rebuildGrid() }
        )
        rebuildGrid()
    }

    private func rebuildGrid() {
        // Wipe all existing rows; NSGridView doesn't expose removeAllRows()
        // so iterate backwards.
        while grid.numberOfRows > 0 {
            grid.removeRow(at: grid.numberOfRows - 1)
        }

        addRow("Name", creationVM.vmName)
        addRow("Operating System", creationVM.selectedOS.displayName)
        addRow("Boot Mode", creationVM.effectiveBootMode.displayName)
        addRow("CPU Cores", "\(creationVM.cpuCount)")
        addRow("Memory", "\(creationVM.memoryInGB) GB")
        addRow("Disk Size", DataFormatters.formatDiskSize(creationVM.diskSizeInGB))
        addRow("Networking", creationVM.networkEnabled ? "Enabled" : "Disabled")

        if creationVM.selectedOS == .macOS {
            addRow("IPSW Source", creationVM.ipswSource == .downloadLatest ? "Download Latest" : "Local File")
            if creationVM.ipswSource == .localFile, let path = creationVM.ipswPath {
                addRow("File", URL(fileURLWithPath: path).lastPathComponent)
            }
            if creationVM.ipswSource == .downloadLatest, let path = creationVM.ipswDownloadPath {
                addRow("Save to", IPSWSelectionStepViewController.abbreviateWithTilde(path))
            }
        } else {
            if let path = creationVM.isoPath {
                addRow("ISO", URL(fileURLWithPath: path).lastPathComponent)
            }
            if let path = creationVM.kernelPath {
                addRow("Kernel", URL(fileURLWithPath: path).lastPathComponent)
            }
        }

        startToggle.state = creationVM.startAfterCreate ? .on : .off
    }

    private func addRow(_ label: String, _ value: String) {
        let labelView = NSTextField(labelWithString: label)
        labelView.textColor = .secondaryLabelColor
        let valueView = NSTextField(labelWithString: value)
        grid.addRow(with: [labelView, valueView])
    }

    @objc private func startToggleChanged(_ sender: NSButton) {
        creationVM.startAfterCreate = sender.state == .on
    }
}
