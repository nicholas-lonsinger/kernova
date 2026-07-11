import AppKit
import UniformTypeIdentifiers

/// Step 2 of the creation wizard for Linux guests: choose the boot method —
/// EFI (boot an ISO) or direct Linux-kernel boot (kernel + optional initrd and
/// command line).
///
/// Native macOS layout: a left-aligned heading, a segmented mode switch, and a
/// grouped card holding the selected mode's file pickers / fields. The segmented
/// control and file pickers mutate the shared ``VMCreationViewModel`` and rebuild
/// the conditional card in place. The shell observes the model separately to keep
/// its Next button in sync.
@MainActor
final class BootConfigContentViewController: NSViewController, NSTextFieldDelegate {
    private let creationVM: VMCreationViewModel

    private let bootModeControl = NSSegmentedControl(
        labels: ["EFI (ISO Image)", "Linux Kernel"], trackingMode: .selectOne, target: nil, action: nil)
    private let conditionalContainer = NSStackView()
    /// Shows the "more content below" cue while this step's content — the mode
    /// switch plus the conditional kernel/initrd fields — overflows the sheet; a
    /// hint only.
    private var scrollMoreIndicator: ScrollMoreIndicator?

    /// Default kernel command line shown — and committed — when none is set.
    private static let defaultKernelCommandLine = "console=hvc0"

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

        conditionalContainer.orientation = .vertical
        conditionalContainer.alignment = .leading
        conditionalContainer.spacing = Spacing.standard

        let stack = NSStackView(views: [title, subtitle, bootModeControl, conditionalContainer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.standard
        stack.setCustomSpacing(20, after: subtitle)
        stack.setCustomSpacing(16, after: bootModeControl)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = makeGroupedFormScrollView(documentView: stack)
        NSLayoutConstraint.activate([
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            conditionalContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        view = scrollView
        scrollMoreIndicator = ScrollMoreIndicator(scrollView: scrollView)
        rebuildConditional()
    }

    // MARK: - Conditional section

    private func rebuildConditional() {
        for view in conditionalContainer.arrangedSubviews {
            conditionalContainer.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let caption: String
        let rows: [NSView]
        if creationVM.selectedBootMode == .linuxKernel {
            caption = "Provide the kernel image and optional initrd/command line."

            // Commit the displayed default so the value the user sees is the one
            // `buildConfiguration()` uses; without this an untouched field leaves
            // `kernelCommandLine` nil and the guest boots without it.
            if creationVM.kernelCommandLine == nil {
                creationVM.kernelCommandLine = Self.defaultKernelCommandLine
            }
            let commandLineField = NSTextField(
                string: creationVM.kernelCommandLine ?? Self.defaultKernelCommandLine)
            commandLineField.placeholderString = "Kernel Command Line"
            commandLineField.delegate = self

            rows = [
                makeFileRow(label: "Kernel", path: creationVM.kernelPath, browseAction: #selector(browseKernel)),
                makeFileRow(label: "Initrd", path: creationVM.initrdPath, browseAction: #selector(browseInitrd)),
                makeGroupedFormCardRow("Command Line", control: commandLineField, fillsControl: true),
            ]
        } else {
            caption = "Select an ISO image to boot from via EFI."
            rows = [
                makeFileRow(label: "ISO Image", path: creationVM.isoPath, browseAction: #selector(browseISO))
            ]
        }

        addFullWidth(makeGroupedFormCaption(caption))
        addFullWidth(makeGroupedFormCard(rows: rows))
    }

    /// Adds an arranged subview to the conditional container and pins its width
    /// to the container once it is in the hierarchy.
    private func addFullWidth(_ view: NSView) {
        conditionalContainer.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: conditionalContainer.widthAnchor).isActive = true
    }

    private func makeFileRow(label: String, path: String?, browseAction: Selector) -> NSView {
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

        let browse = NSButton(title: "Browse…", target: self, action: browseAction)
        browse.bezelStyle = .rounded
        browse.controlSize = .small
        browse.setContentHuggingPriority(.required, for: .horizontal)

        let control = NSStackView(views: [pathLabel, browse])
        control.orientation = .horizontal
        control.alignment = .centerY
        control.spacing = Spacing.standard

        return makeGroupedFormCardRow(label, control: control, fillsControl: true)
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
            guard let self else { return }
            let (path, bookmark) = SecurityScopedBookmark.capture(url)
            self.creationVM.isoPath = path
            self.creationVM.isoBookmark = bookmark
            self.rebuildConditional()
        }
    }

    @objc private func browseKernel() {
        browse(title: "Select Kernel", types: [.data]) { [weak self] url in
            guard let self else { return }
            let (path, bookmark) = SecurityScopedBookmark.capture(url)
            self.creationVM.kernelPath = path
            self.creationVM.kernelBookmark = bookmark
            self.rebuildConditional()
        }
    }

    @objc private func browseInitrd() {
        browse(title: "Select Initrd", types: [.data]) { [weak self] url in
            guard let self else { return }
            let (path, bookmark) = SecurityScopedBookmark.capture(url)
            self.creationVM.initrdPath = path
            self.creationVM.initrdBookmark = bookmark
            self.rebuildConditional()
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
