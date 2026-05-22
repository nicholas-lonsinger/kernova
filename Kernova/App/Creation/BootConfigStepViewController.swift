import AppKit
import UniformTypeIdentifiers

/// Step 2 (Linux): Configure boot method — EFI with ISO or direct kernel boot.
@MainActor
final class BootConfigStepViewController: CreationStepViewController {
    private let modePicker = NSSegmentedControl(
        labels: ["EFI (ISO Image)", "Linux Kernel"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let efiContainer = NSStackView()
    private let kernelContainer = NSStackView()
    private let isoPathLabel = NSTextField(labelWithString: "No file selected")
    private let kernelPathLabel = NSTextField(labelWithString: "No file selected")
    private let initrdPathLabel = NSTextField(labelWithString: "No file selected")
    private let cmdLineField = NSTextField()
    private var observation: ObservationLoop?

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let header = makeStepHeader(
            title: "Boot Configuration",
            subtitle: "Choose how to boot your Linux virtual machine."
        )

        modePicker.target = self
        modePicker.action = #selector(modeChanged(_:))
        modePicker.translatesAutoresizingMaskIntoConstraints = false

        // EFI container
        configureFileLabel(isoPathLabel)
        let isoRow = makeFilePickerRow(label: "ISO Image", pathLabel: isoPathLabel, kind: .iso)
        let isoSubtitle = NSTextField(labelWithString: "Select an ISO image to boot from via EFI.")
        isoSubtitle.font = .preferredFont(forTextStyle: .caption1)
        isoSubtitle.textColor = .secondaryLabelColor
        efiContainer.setViews([isoSubtitle, isoRow], in: .leading)
        efiContainer.orientation = .vertical
        efiContainer.alignment = .leading
        efiContainer.spacing = 8

        // Kernel container
        let kernelSubtitle = NSTextField(
            labelWithString: "Provide the kernel image and optional initrd/command line.")
        kernelSubtitle.font = .preferredFont(forTextStyle: .caption1)
        kernelSubtitle.textColor = .secondaryLabelColor

        configureFileLabel(kernelPathLabel)
        let kernelRow = makeFilePickerRow(label: "Kernel", pathLabel: kernelPathLabel, kind: .kernel)

        configureFileLabel(initrdPathLabel)
        let initrdRow = makeFilePickerRow(label: "Initrd", pathLabel: initrdPathLabel, kind: .initrd)

        cmdLineField.placeholderString = "Kernel Command Line"
        cmdLineField.stringValue = creationVM.kernelCommandLine ?? "console=hvc0"
        cmdLineField.target = self
        cmdLineField.action = #selector(cmdLineChanged(_:))
        cmdLineField.translatesAutoresizingMaskIntoConstraints = false

        kernelContainer.setViews([kernelSubtitle, kernelRow, initrdRow, cmdLineField], in: .leading)
        kernelContainer.orientation = .vertical
        kernelContainer.alignment = .leading
        kernelContainer.spacing = 8

        let stack = NSStackView(views: [header, modePicker, efiContainer, kernelContainer])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        // RATIONALE: 3-edge pin (no bottom) so the stack stays at its
        // intrinsic content height at the top. See same rationale in
        // OSSelectionStepViewController.
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        cmdLineField.widthAnchor.constraint(equalToConstant: 380).isActive = true

        view = container

        observation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = self.creationVM.selectedBootMode
                _ = self.creationVM.isoPath
                _ = self.creationVM.kernelPath
                _ = self.creationVM.initrdPath
            },
            apply: { [weak self] in self?.refresh() }
        )
        refresh()
    }

    // MARK: - Row helpers

    private enum FileKind { case iso, kernel, initrd }

    private func configureFileLabel(_ label: NSTextField) {
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func makeFilePickerRow(label: String, pathLabel: NSTextField, kind: FileKind) -> NSStackView {
        let prefix = NSTextField(labelWithString: label)
        prefix.alignment = .right
        prefix.widthAnchor.constraint(equalToConstant: 70).isActive = true

        let button = NSButton(title: "Browse…", target: self, action: #selector(browse(_:)))
        button.tag = {
            switch kind {
            case .iso: return 0
            case .kernel: return 1
            case .initrd: return 2
            }
        }()

        let row = NSStackView(views: [prefix, pathLabel, button])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    // MARK: - Refresh

    private func refresh() {
        modePicker.selectedSegment = (creationVM.selectedBootMode == .linuxKernel) ? 1 : 0
        let isKernel = creationVM.selectedBootMode == .linuxKernel
        efiContainer.isHidden = isKernel
        kernelContainer.isHidden = !isKernel

        isoPathLabel.stringValue = creationVM.isoPath.map(Self.fileName) ?? "No file selected"
        kernelPathLabel.stringValue = creationVM.kernelPath.map(Self.fileName) ?? "No file selected"
        initrdPathLabel.stringValue = creationVM.initrdPath.map(Self.fileName) ?? "No file selected"
    }

    /// Internal so unit tests can verify empty/normal path handling
    /// without standing up the whole view controller.
    static func fileName(_ path: String) -> String {
        // `URL(fileURLWithPath: "")` resolves to the current working
        // directory; if a path optional somehow lands as `""` instead of
        // nil, the empty-string display fallback is more useful than the
        // CWD's last path component.
        guard !path.isEmpty else { return "No file selected" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    // MARK: - Actions

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        creationVM.selectedBootMode = (sender.selectedSegment == 1) ? .linuxKernel : .efi
    }

    @objc private func cmdLineChanged(_ sender: NSTextField) {
        creationVM.kernelCommandLine = sender.stringValue
    }

    @objc private func browse(_ sender: NSButton) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        switch sender.tag {
        case 0:
            panel.title = "Select ISO Image"
            panel.allowedContentTypes = [.iso]
        case 1:
            panel.title = "Select Kernel"
            panel.allowedContentTypes = [.data]
        case 2:
            panel.title = "Select Initrd"
            panel.allowedContentTypes = [.data]
        default:
            return
        }

        let kind = sender.tag
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = panel.url else { return }
                switch kind {
                case 0: self.creationVM.isoPath = url.path
                case 1: self.creationVM.kernelPath = url.path
                case 2: self.creationVM.initrdPath = url.path
                default: break
                }
            }
        }
    }
}
