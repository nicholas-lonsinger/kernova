import AppKit
import UniformTypeIdentifiers

/// Step 2 of the creation wizard for Linux guests: choose the boot method —
/// EFI (boot an installer image) or direct Linux-kernel boot (kernel + optional
/// initrd and command line).
///
/// The segmented control, radios and file pickers mutate the shared
/// ``VMCreationViewModel`` and rebuild the conditional section in place. The
/// shell observes the model separately to keep its Next button in sync.
@MainActor
final class BootConfigContentViewController: NSViewController, NSTextFieldDelegate {
    private let creationVM: VMCreationViewModel

    private let bootModeControl = NSSegmentedControl(
        labels: ["EFI (ISO Image)", "Linux Kernel"], trackingMode: .selectOne, target: nil, action: nil)
    private let conditionalContainer = NSStackView()
    /// Hosts the nested distribution picker.
    private let catalogSheetPresenter = SheetPresenter()
    /// Shows the "more content below" cue while this step's content overflows the
    /// sheet; a hint only.
    private var scrollMoreIndicator: ScrollMoreIndicator?

    /// Where the EFI installer image comes from, one radio each.
    private enum ImageSource: Hashable {
        case catalog
        case localISO
    }

    /// Rebuilt with the conditional section, which is where the radios live.
    private var radios: [ImageSource: NSButton] = [:]

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

    override func viewWillDisappear() {
        super.viewWillDisappear()
        // The step is swapped out on navigation; a picker left attached to a
        // window that is going away would wedge the presenter as shown.
        catalogSheetPresenter.reset()
    }

    // MARK: - Conditional section

    private func rebuildConditional() {
        for view in conditionalContainer.arrangedSubviews {
            conditionalContainer.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        radios.removeAll()

        if creationVM.selectedBootMode == .linuxKernel {
            addKernelSection()
        } else {
            addImageSection()
        }
    }

    private func addKernelSection() {
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

        addFullWidth(
            makeGroupedFormCaption("Provide the kernel image and optional initrd/command line."))
        addFullWidth(
            makeGroupedFormCard(rows: [
                makeFileRow(
                    label: "Kernel", path: creationVM.kernelPath, browseAction: #selector(browseKernel)),
                makeFileRow(
                    label: "Initrd", path: creationVM.initrdPath, browseAction: #selector(browseInitrd)),
                makeGroupedFormCardRow("Command Line", control: commandLineField, fillsControl: true),
            ]))
    }

    /// Renders the two EFI image sources and, once one has been picked, a badge
    /// naming what it is.
    private func addImageSection() {
        let catalogOption = makeSourceRadio(
            for: .catalog,
            symbol: "list.bullet",
            title: "Choose a Distribution…",
            description: "Download a Linux installer image after the virtual machine is created."
        )
        let localOption = makeSourceRadio(
            for: .localISO,
            symbol: "folder",
            title: "ISO File…",
            description: "Boot an ISO image already on your Mac."
        )

        let options = NSStackView(views: [catalogOption, localOption])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = Spacing.large

        addFullWidth(makeGroupedFormCaption("Choose the installer image to boot from via EFI."))
        addFullWidth(options)

        switch creationVM.linuxSelection {
        case .catalogEntry(let entry):
            conditionalContainer.addArrangedSubview(
                makeWizardBadge(
                    symbolName: "shippingbox.fill",
                    text: [
                        entry.distribution, entry.version,
                        wizardApproximateSize(entry.approxSizeBytes),
                    ].joined(separator: "  ·  "),
                    trailingButton: makeLinkButton(
                        "Change…", target: self, action: #selector(changeDistribution))
                ))
        case .localISO(let path, _):
            conditionalContainer.addArrangedSubview(
                makeWizardPathBadge(
                    path: path,
                    changeButton: makeLinkButton(
                        "Change…", target: self, action: #selector(changeISOFile))
                ))
        case nil:
            break
        }
    }

    private func makeSourceRadio(
        for source: ImageSource, symbol: String, title: String, description: String
    ) -> NSView {
        let radio = NSButton(
            radioButtonWithTitle: title, target: self, action: #selector(sourceRadioClicked(_:)))
        radio.state = source == currentImageSource ? .on : .off
        radios[source] = radio
        return makeWizardRadioOption(radio: radio, iconSymbol: symbol, description: description)
    }

    /// Which radio the current pick lights, or `nil` while nothing is picked.
    private var currentImageSource: ImageSource? {
        switch creationVM.linuxSelection {
        case .catalogEntry: .catalog
        case .localISO: .localISO
        case nil: nil
        }
    }

    /// The distribution the picker re-opens on, from the current pick.
    private var selectedCatalogID: String? {
        guard case .catalogEntry(let entry) = creationVM.linuxSelection else { return nil }
        return entry.id
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
        browse.bezelStyle = .push
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

    @objc private func sourceRadioClicked(_ sender: NSButton) {
        guard let source = radios.first(where: { $0.value === sender })?.key else { return }
        // Both sources commit only when the user actually picks something. Re-render
        // from the (still-current) model so the just-clicked radio doesn't stay
        // selected if the picker is cancelled, then open it.
        rebuildConditional()
        switch source {
        case .catalog: chooseDistribution()
        case .localISO: browseISO()
        }
    }

    @objc private func changeDistribution() {
        chooseDistribution()
    }

    @objc private func changeISOFile() {
        browseISO()
    }

    /// Opens the nested distribution picker, preselecting the current pick.
    private func chooseDistribution() {
        guard let window = view.window, !catalogSheetPresenter.isShown else { return }
        let sheet = LinuxImageCatalogSheetContentViewController(
            entries: creationVM.linuxCatalogService.entries,
            selectedID: selectedCatalogID,
            generatedAt: creationVM.linuxCatalogService.generatedAt
        )
        sheet.delegate = self
        catalogSheetPresenter.show(content: sheet, in: window)
    }

    private func browseISO() {
        browseAndCapture(title: "Select ISO Image", types: [.iso]) { vm, path, bookmark in
            vm.selectLocalISO(path: path, bookmark: bookmark)
        }
    }

    @objc private func browseKernel() {
        browseAndCapture(title: "Select Kernel", types: [.data]) { vm, path, bookmark in
            vm.kernelPath = path
            vm.kernelBookmark = bookmark
        }
    }

    @objc private func browseInitrd() {
        browseAndCapture(title: "Select Initrd", types: [.data]) { vm, path, bookmark in
            vm.initrdPath = path
            vm.initrdBookmark = bookmark
        }
    }

    /// `browse` + `SecurityScopedBookmark.capture` + refresh, shared by the three
    /// pickers; `assign` writes the captured pair onto its model fields.
    private func browseAndCapture(
        title: String, types: [UTType],
        assign: @escaping (VMCreationViewModel, String, Data?) -> Void
    ) {
        browse(title: title, types: types) { [weak self] url in
            guard let self else { return }
            let (path, bookmark) = SecurityScopedBookmark.capture(url)
            assign(self.creationVM, path, bookmark)
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

// MARK: - LinuxImageCatalogSheetContentViewControllerDelegate

extension BootConfigContentViewController: LinuxImageCatalogSheetContentViewControllerDelegate {
    func linuxImageCatalogSheet(
        _ vc: LinuxImageCatalogSheetContentViewController,
        didChoose entry: LinuxImageCatalogEntry
    ) {
        catalogSheetPresenter.close()
        creationVM.selectLinuxCatalogEntry(entry)
        rebuildConditional()
    }

    func linuxImageCatalogSheetDidCancel(
        _ vc: LinuxImageCatalogSheetContentViewController
    ) {
        // The model was never touched, so the radios already show the source
        // that was selected before the picker opened.
        catalogSheetPresenter.close()
    }
}
