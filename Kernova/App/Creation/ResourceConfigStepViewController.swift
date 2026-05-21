import AppKit

/// Step 3: Configure VM name and resource allocation (CPU, RAM, disk).
@MainActor
final class ResourceConfigStepViewController: CreationStepViewController {
    private let nameField = NSTextField()
    private let cpuStepper = NSStepper()
    private let cpuLabel = NSTextField(labelWithString: "")
    private let memoryStepper = NSStepper()
    private let memoryLabel = NSTextField(labelWithString: "")
    private let diskPopup = NSPopUpButton()
    private let networkSwitch = NSSwitch()
    private var observation: ObservationLoop?

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let header = makeStepHeader(
            title: "Configure Resources",
            subtitle: "Set the name and resource allocation for your virtual machine."
        )

        let os = creationVM.selectedOS

        nameField.stringValue = creationVM.vmName
        nameField.placeholderString = "Name"
        nameField.target = self
        nameField.action = #selector(nameChanged(_:))
        nameField.translatesAutoresizingMaskIntoConstraints = false

        cpuStepper.minValue = Double(os.minCPUCount)
        cpuStepper.maxValue = Double(os.maxCPUCount)
        cpuStepper.integerValue = creationVM.cpuCount
        cpuStepper.target = self
        cpuStepper.action = #selector(cpuChanged(_:))

        memoryStepper.minValue = Double(os.minMemoryInGB)
        memoryStepper.maxValue = Double(os.maxMemoryInGB)
        memoryStepper.integerValue = creationVM.memoryInGB
        memoryStepper.target = self
        memoryStepper.action = #selector(memoryChanged(_:))

        diskPopup.removeAllItems()
        for size in os.availableDiskSizes {
            let item = NSMenuItem(title: DataFormatters.formatDiskSize(size), action: nil, keyEquivalent: "")
            item.representedObject = size
            diskPopup.menu?.addItem(item)
        }
        diskPopup.target = self
        diskPopup.action = #selector(diskChanged(_:))
        if let index = os.availableDiskSizes.firstIndex(of: creationVM.diskSizeInGB) {
            diskPopup.selectItem(at: index)
        }

        let diskCaption = NSTextField(
            labelWithString: "Physical disk usage grows only as data is written (ASIF sparse format).")
        diskCaption.font = .preferredFont(forTextStyle: .caption1)
        diskCaption.textColor = .secondaryLabelColor

        networkSwitch.state = creationVM.networkEnabled ? .on : .off
        networkSwitch.target = self
        networkSwitch.action = #selector(networkChanged(_:))

        // Layout via NSGridView for label/control alignment
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.columnSpacing = 12
        grid.rowSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false

        grid.addRow(with: [makeFieldLabel("Name"), nameField])

        let cpuRow = NSStackView(views: [cpuLabel, cpuStepper])
        cpuRow.orientation = .horizontal
        cpuRow.spacing = 8
        grid.addRow(with: [makeFieldLabel("CPU Cores"), cpuRow])

        let memRow = NSStackView(views: [memoryLabel, memoryStepper])
        memRow.orientation = .horizontal
        memRow.spacing = 8
        grid.addRow(with: [makeFieldLabel("Memory"), memRow])

        grid.addRow(with: [makeFieldLabel("Disk Size"), diskPopup])
        grid.addRow(with: [NSGridCell.emptyContentView, diskCaption])
        grid.addRow(with: [makeFieldLabel("Networking"), networkSwitch])

        // Force left column to right-align
        if let labelColumn = grid.column(at: 0) as NSGridColumn? {
            labelColumn.xPlacement = .trailing
        }

        let outer = NSStackView(views: [header, grid])
        outer.orientation = .vertical
        outer.alignment = .centerX
        outer.spacing = 18
        outer.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: container.topAnchor),
            outer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            nameField.widthAnchor.constraint(equalToConstant: 280),
        ])

        view = container

        observation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = self.creationVM.cpuCount
                _ = self.creationVM.memoryInGB
                _ = self.creationVM.diskSizeInGB
                _ = self.creationVM.networkEnabled
                _ = self.creationVM.vmName
            },
            apply: { [weak self] in self?.refresh() }
        )
        refresh()
    }

    private func makeFieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    private func refresh() {
        if nameField.currentEditor() == nil, nameField.stringValue != creationVM.vmName {
            nameField.stringValue = creationVM.vmName
        }
        cpuStepper.integerValue = creationVM.cpuCount
        cpuLabel.stringValue = "\(creationVM.cpuCount)"
        memoryStepper.integerValue = creationVM.memoryInGB
        memoryLabel.stringValue = "\(creationVM.memoryInGB) GB"
        if let index = creationVM.selectedOS.availableDiskSizes.firstIndex(of: creationVM.diskSizeInGB) {
            diskPopup.selectItem(at: index)
        }
        networkSwitch.state = creationVM.networkEnabled ? .on : .off
    }

    @objc private func nameChanged(_ sender: NSTextField) {
        creationVM.vmName = sender.stringValue
    }

    @objc private func cpuChanged(_ sender: NSStepper) {
        creationVM.cpuCount = sender.integerValue
    }

    @objc private func memoryChanged(_ sender: NSStepper) {
        creationVM.memoryInGB = sender.integerValue
    }

    @objc private func diskChanged(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem,
            let size = item.representedObject as? Int
        else { return }
        creationVM.diskSizeInGB = size
    }

    @objc private func networkChanged(_ sender: NSSwitch) {
        creationVM.networkEnabled = sender.state == .on
    }
}
