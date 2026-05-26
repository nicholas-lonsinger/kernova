import AppKit
import UniformTypeIdentifiers

/// Step 2 of the creation wizard for Linux guests: choose the boot method —
/// EFI (boot an ISO) or direct Linux-kernel boot (kernel + optional initrd and
/// command line).
///
/// The segmented control and file pickers mutate the shared
/// ``VMCreationViewModel`` and rebuild the conditional section in place. The
/// shell observes the model separately to keep its Next button in sync.
@MainActor
final class BootConfigContentViewController: NSViewController, NSTextFieldDelegate {
    private let creationVM: VMCreationViewModel

    private let bootModeControl = NSSegmentedControl(
        labels: ["EFI (ISO Image)", "Linux Kernel"], trackingMode: .selectOne, target: nil, action: nil)
    private let conditionalContainer = NSStackView()

    init(creationVM: VMCreationViewModel) {
        self.creationVM = creationVM
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BootConfigContentViewController does not support NSCoder")
    }

    override func loadView() {
        let title = makeWizardTitle("Boot Configuration")
        let subtitle = makeWizardSubtitle("Choose how to boot your Linux virtual machine.")

        bootModeControl.selectedSegment = creationVM.selectedBootMode == .linuxKernel ? 1 : 0
        bootModeControl.target = self
        bootModeControl.action = #selector(bootModeChanged)
        bootModeControl.translatesAutoresizingMaskIntoConstraints = false
        bootModeControl.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true

        conditionalContainer.orientation = .vertical
        conditionalContainer.alignment = .leading
        conditionalContainer.spacing = 10

        let stack = NSStackView(views: [title, subtitle, bootModeControl, conditionalContainer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(20, after: subtitle)
        stack.setCustomSpacing(20, after: bootModeControl)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = makeWizardScrollView(documentView: stack)
        NSLayoutConstraint.activate([
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            conditionalContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        view = scrollView
        rebuildConditional()
    }

    // MARK: - Conditional section

    private func rebuildConditional() {
        for view in conditionalContainer.arrangedSubviews {
            conditionalContainer.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if creationVM.selectedBootMode == .linuxKernel {
            addFullWidth(
                makeWizardCaption("Provide the kernel image and optional initrd/command line."))
            addFullWidth(
                makeFilePickerRow(
                    label: "Kernel", path: creationVM.kernelPath, browseAction: #selector(browseKernel)))
            addFullWidth(
                makeFilePickerRow(
                    label: "Initrd", path: creationVM.initrdPath, browseAction: #selector(browseInitrd)))

            let commandLineField = NSTextField(string: creationVM.kernelCommandLine ?? "console=hvc0")
            commandLineField.placeholderString = "Kernel Command Line"
            commandLineField.delegate = self
            addFullWidth(
                makeWizardFormRow("Command Line", control: commandLineField, alignment: .centerY))
        } else {
            addFullWidth(makeWizardCaption("Select an ISO image to boot from via EFI."))
            addFullWidth(
                makeFilePickerRow(
                    label: "ISO Image", path: creationVM.isoPath, browseAction: #selector(browseISO)))
        }
    }

    /// Adds an arranged subview to the conditional container and pins its width
    /// to the container.
    ///
    /// The width constraint is activated *after* the view is in the container's
    /// hierarchy — activating it inside a row builder (before the row is added)
    /// has no common ancestor and traps.
    private func addFullWidth(_ view: NSView) {
        conditionalContainer.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: conditionalContainer.widthAnchor).isActive = true
    }

    private func makeFilePickerRow(label: String, path: String?, browseAction: Selector) -> NSView {
        let pathLabel: NSTextField
        if let path {
            pathLabel = NSTextField(labelWithString: URL(fileURLWithPath: path).lastPathComponent)
        } else {
            pathLabel = NSTextField(labelWithString: "No file selected")
            pathLabel.textColor = .secondaryLabelColor
        }
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.isSelectable = false
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let browse = NSButton(title: "Browse...", target: self, action: browseAction)
        browse.bezelStyle = .rounded
        browse.controlSize = .small
        browse.setContentHuggingPriority(.required, for: .horizontal)

        let control = NSStackView(views: [pathLabel, browse])
        control.orientation = .horizontal
        control.alignment = .centerY
        control.spacing = 8
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Width is pinned by the caller (`addFullWidth`) once the row is in the
        // container, so the control fills the space after the label column and
        // the path truncates while Browse hugs the trailing edge.
        return makeWizardFormRow(label, control: control, alignment: .centerY)
    }

    // MARK: - Actions

    @objc private func bootModeChanged() {
        creationVM.selectedBootMode = bootModeControl.selectedSegment == 1 ? .linuxKernel : .efi
        rebuildConditional()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        creationVM.kernelCommandLine = field.stringValue
    }

    @objc private func browseISO() {
        browse(title: "Select ISO Image", types: [.iso]) { [weak self] url in
            self?.creationVM.isoPath = url.path
            self?.rebuildConditional()
        }
    }

    @objc private func browseKernel() {
        browse(title: "Select Kernel", types: [.data]) { [weak self] url in
            self?.creationVM.kernelPath = url.path
            self?.rebuildConditional()
        }
    }

    @objc private func browseInitrd() {
        browse(title: "Select Initrd", types: [.data]) { [weak self] url in
            self?.creationVM.initrdPath = url.path
            self?.rebuildConditional()
        }
    }

    /// Presents an open panel as a sheet on the wizard window and invokes
    /// `onPick` with the chosen URL (no-op on cancel).
    private func browse(title: String, types: [UTType], onPick: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = types
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            onPick(url)
        }
    }
}
