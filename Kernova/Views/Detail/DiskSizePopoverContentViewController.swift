import AppKit

/// Delegate for ``DiskSizePopoverContentViewController``.
///
/// The view controller is intentionally decoupled from `VMLibraryViewModel`
/// — the host (typically a SwiftUI/AppKit bridge representable) implements
/// these methods to forward the user's choice to the appropriate view-model
/// action and to close the surrounding popover.
@MainActor
protocol DiskSizePopoverContentViewControllerDelegate: AnyObject {
    /// Invoked when the user clicks the confirm (Create) button.
    ///
    /// - Parameters:
    ///   - vc: The popover content view controller firing the event.
    ///   - sizeInGB: The size (in gigabytes) the user selected from the
    ///     popup. Always one of the `availableSizes` passed to the
    ///     controller's initializer.
    func diskSizePopover(
        _ vc: DiskSizePopoverContentViewController,
        didConfirmSizeInGB sizeInGB: Int
    )

    /// Invoked when the user clicks Cancel.
    func diskSizePopoverDidCancel(_ vc: DiskSizePopoverContentViewController)
}

/// Generic popover content for asking the user to pick a disk size and
/// confirm or cancel.
///
/// Reused for both Storage Disks ("Create New Disk") and Removable Media
/// ("Create New Removable Disk") — the two surfaces are visually identical
/// (headline + size popup + caption + Cancel/Create) and only differ in the
/// headline text, the caption text, and what the host does on confirm.
/// The controller knows nothing about either flow; the host supplies the
/// strings via init and implements the delegate.
///
/// Owns its full layout via `loadView()` using the shared ``CalloutStyle``
/// tokens and the `makeCalloutHeadline` / `makeCalloutBody` atom factories.
/// The surrounding `NSPopover` chrome is managed externally by the host
/// (via ``PopoverPresenter``); this controller has no reference to it.
@MainActor
final class DiskSizePopoverContentViewController: NSViewController {
    weak var delegate: DiskSizePopoverContentViewControllerDelegate?

    /// Headline shown at the top of the popover (e.g. "Create New Disk").
    let headline: String

    /// Caption shown below the size popup explaining what will be created
    /// and where.
    let caption: String

    /// All disk sizes the user can pick from, in display order.
    let availableSizes: [Int]

    /// The size pre-selected when the popover opens.
    ///
    /// Should be a member of `availableSizes`; if it isn't, the popup falls
    /// back to its first item.
    let defaultSizeInGB: Int

    private let sizePopUp = NSPopUpButton()

    init(
        headline: String,
        caption: String,
        availableSizes: [Int],
        defaultSizeInGB: Int
    ) {
        self.headline = headline
        self.caption = caption
        self.availableSizes = availableSizes
        self.defaultSizeInGB = defaultSizeInGB
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DiskSizePopoverContentViewController does not support NSCoder")
    }

    override func loadView() {
        let container = NSView()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CalloutStyle.verticalSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(makeCalloutHeadline(headline))
        stack.addArrangedSubview(makeSizeRow())
        stack.addArrangedSubview(makeCalloutBody(caption))
        stack.addArrangedSubview(makeButtonRow())

        container.addSubview(stack)
        let padding = CalloutStyle.padding
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),
            container.widthAnchor.constraint(equalToConstant: CalloutStyle.width),
        ])

        view = container
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Re-pin so `NSPopover` resizes its frame to the measured stack
        // height under the configured width.
        let fittingSize = view.fittingSize
        if preferredContentSize != fittingSize {
            preferredContentSize = fittingSize
        }
    }

    /// Returns the currently selected size in gigabytes.
    ///
    /// Reads the popup's selected `tag`, falling back to `defaultSizeInGB`
    /// if the popup has no selection (shouldn't happen after `loadView`).
    var selectedSizeInGB: Int {
        let tag = sizePopUp.selectedItem?.tag ?? defaultSizeInGB
        return tag == 0 ? defaultSizeInGB : tag
    }

    /// "Size:" label + `NSPopUpButton` populated from `availableSizes`.
    private func makeSizeRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .firstBaseline

        let label = NSTextField(labelWithString: "Size:")
        label.font = CalloutStyle.bodyFont

        for size in availableSizes {
            sizePopUp.addItem(withTitle: DataFormatters.formatDiskSize(size))
            sizePopUp.lastItem?.tag = size
        }
        if availableSizes.contains(defaultSizeInGB) {
            sizePopUp.selectItem(withTag: defaultSizeInGB)
        }

        row.addArrangedSubview(label)
        row.addArrangedSubview(sizePopUp)
        return row
    }

    /// Trailing-aligned Cancel + Create button row.
    private func makeButtonRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let cancelButton = NSButton(
            title: "Cancel", target: self, action: #selector(cancelTapped(_:))
        )
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1B}"  // Escape

        let createButton = NSButton(
            title: "Create", target: self, action: #selector(createTapped(_:))
        )
        createButton.bezelStyle = .rounded
        createButton.keyEquivalent = "\r"
        createButton.setAccessibilityLabel("Create disk")

        row.addArrangedSubview(spacer)
        row.addArrangedSubview(cancelButton)
        row.addArrangedSubview(createButton)
        return row
    }

    @objc private func cancelTapped(_ sender: NSButton) {
        delegate?.diskSizePopoverDidCancel(self)
    }

    @objc private func createTapped(_ sender: NSButton) {
        delegate?.diskSizePopover(self, didConfirmSizeInGB: selectedSizeInGB)
    }
}
