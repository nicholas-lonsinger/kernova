import AppKit

/// Delegate for ``DeleteVMSheetContentViewController``.
///
/// The view controller is intentionally decoupled from `VMLibraryViewModel`.
/// The host (the SwiftUI bridge modifier) implements these methods and
/// forwards the user's choice to the view model.
@MainActor
protocol DeleteVMSheetContentViewControllerDelegate: AnyObject {
    /// Invoked when the user clicks Cancel (or presses Escape).
    func deleteVMSheetDidCancel(_ vc: DeleteVMSheetContentViewController)

    /// Invoked when the user clicks Move to Trash (or presses Return).
    ///
    /// - Parameters:
    ///   - vc: The sheet view controller firing the event.
    ///   - trashExternals: The current state of the "Also move these
    ///     files to Trash" checkbox at the moment of confirmation.
    func deleteVMSheet(
        _ vc: DeleteVMSheetContentViewController,
        didConfirmTrashExternals trashExternals: Bool
    )
}

/// Confirmation sheet shown when deleting a VM that references external
/// files (storage disks or removable media outside the bundle).
///
/// Unique structure (header with red trash icon + body + scrolling
/// attachment list + footer with checkbox toggle + conditional warning +
/// Cancel/Move-to-Trash buttons) lives in its own concrete subclass per
/// the established per-sheet-subclass pattern.
@MainActor
final class DeleteVMSheetContentViewController: NSViewController {
    weak var delegate: DeleteVMSheetContentViewControllerDelegate?

    private let vmName: String
    private let externals: [ExternalAttachment]

    /// `true` when at least one external in `externals` is shared with another VM in the library.
    ///
    /// Drives the conditional footer warning row's visibility (along with
    /// the checkbox state).
    private var anyShared: Bool { externals.contains(where: \.isShared) }

    // MARK: - Layout constants

    private static let sheetWidth: CGFloat = 520
    private static let padding: CGFloat = 16
    private static let scrollMaxHeight: CGFloat = 240

    // MARK: - Subviews (held for state updates)

    private let trashIconExternalsCheckbox = NSButton()
    private let trashExternalsWarningRow = NSStackView()

    init(vmName: String, externals: [ExternalAttachment]) {
        self.vmName = vmName
        self.externals = externals
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DeleteVMSheetContentViewController does not support NSCoder")
    }

    /// Current "Also move these files to Trash" checkbox state.
    var trashExternalsChecked: Bool {
        trashIconExternalsCheckbox.state == .on
    }

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let header = makeHeader()
        let divider1 = makeHorizontalSeparator()
        let listScrollView = makeAttachmentList()
        let divider2 = makeHorizontalSeparator()
        let footer = makeFooter()

        [header, divider1, listScrollView, divider2, footer].forEach { view in
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.sheetWidth),

            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            divider1.topAnchor.constraint(equalTo: header.bottomAnchor),
            divider1.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider1.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            listScrollView.topAnchor.constraint(equalTo: divider1.bottomAnchor),
            listScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            listScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            divider2.topAnchor.constraint(equalTo: listScrollView.bottomAnchor),
            divider2.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider2.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            footer.topAnchor.constraint(equalTo: divider2.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        view = container
    }

    // MARK: - Header

    private func makeHeader() -> NSView {
        let container = NSView()

        let icon = NSImageView(
            image: .systemSymbol("trash", accessibilityDescription: "")
        )
        icon.contentTintColor = .systemRed
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .title1)

        let title = NSTextField(labelWithString: "Move \u{201C}\(vmName)\u{201D} to Trash?")
        title.font = .preferredFont(forTextStyle: .headline)
        title.translatesAutoresizingMaskIntoConstraints = false
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 0

        let body = NSTextField(
            wrappingLabelWithString:
                "The VM bundle will be moved to the Trash. You can restore it using Finder's Put Back command. Empty the Trash to permanently delete the VM and reclaim disk space."
        )
        body.font = .preferredFont(forTextStyle: .callout)
        body.textColor = .secondaryLabelColor
        body.translatesAutoresizingMaskIntoConstraints = false
        body.lineBreakMode = .byWordWrapping
        body.maximumNumberOfLines = 0
        body.isSelectable = false

        let textStack = NSStackView(views: [title, body])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(icon)
        container.addSubview(textStack)
        let padding = Self.padding
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            textStack.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            textStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),
        ])
        return container
    }

    // MARK: - Attachment list

    private func makeAttachmentList() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 12
        listStack.translatesAutoresizingMaskIntoConstraints = false

        for external in externals {
            listStack.addArrangedSubview(makeAttachmentRow(external))
        }

        let documentView = NSView()
        documentView.addSubview(listStack)
        let padding = Self.padding
        NSLayoutConstraint.activate([
            listStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: padding),
            listStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: padding),
            listStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -padding),
            listStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -padding),
        ])

        scrollView.documentView = documentView
        // Cap the scroll view at 240pt high, matching the SwiftUI predecessor.
        scrollView.heightAnchor.constraint(
            lessThanOrEqualToConstant: Self.scrollMaxHeight
        ).isActive = true
        // Ensure the scroll view also gets at least the content height up
        // to the cap — otherwise NSScrollView defaults to a small fitting
        // size and clips the list.
        let contentHeight = listStack.fittingSize.height + padding * 2
        scrollView.heightAnchor.constraint(
            equalToConstant: min(contentHeight, Self.scrollMaxHeight)
        ).isActive = true

        return scrollView
    }

    private func makeAttachmentRow(_ external: ExternalAttachment) -> NSView {
        let icon = NSImageView(
            image: .systemSymbol(external.symbolName, accessibilityDescription: "")
        )
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: external.label)
        label.font = .preferredFont(forTextStyle: .body)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.isSelectable = false

        let path = NSTextField(labelWithString: external.path)
        path.font = .preferredFont(forTextStyle: .caption1)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.maximumNumberOfLines = 1
        path.translatesAutoresizingMaskIntoConstraints = false
        path.isSelectable = false
        path.setContentHuggingPriority(.defaultLow, for: .horizontal)
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [label, path])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        if external.isShared {
            let warning = makeSharedWarningRow(
                "Also used by \(formatSharedVMs(external.sharedWithVMNames))"
            )
            textStack.addArrangedSubview(warning)
        }

        let row = NSView()
        row.addSubview(icon)
        row.addSubview(textStack)
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: row.topAnchor, constant: 2),
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            textStack.topAnchor.constraint(equalTo: row.topAnchor),
            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            textStack.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
    }

    private func makeSharedWarningRow(_ text: String) -> NSView {
        let icon = NSImageView(
            image: .systemSymbol("exclamationmark.triangle.fill", accessibilityDescription: "")
        )
        icon.contentTintColor = .systemOrange
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: text)
        label.font = .preferredFont(forTextStyle: .caption1)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.isSelectable = false

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    // MARK: - Footer

    private func makeFooter() -> NSView {
        let container = NSView()

        trashIconExternalsCheckbox.setButtonType(.switch)
        trashIconExternalsCheckbox.title = "Also move these files to Trash"
        trashIconExternalsCheckbox.translatesAutoresizingMaskIntoConstraints = false
        trashIconExternalsCheckbox.target = self
        trashIconExternalsCheckbox.action = #selector(trashExternalsToggled(_:))

        // The "files will become unavailable" warning row is built once and
        // shown/hidden based on (checkbox checked) AND (any external is
        // shared with another VM).
        trashExternalsWarningRow.removeArrangedSubviews()
        let warning = makeSharedWarningRow(
            "Files marked as shared will become unavailable to the VMs listed above."
        )
        trashExternalsWarningRow.orientation = .horizontal
        trashExternalsWarningRow.spacing = 0
        trashExternalsWarningRow.alignment = .top
        trashExternalsWarningRow.addArrangedSubview(warning)
        trashExternalsWarningRow.isHidden = true
        trashExternalsWarningRow.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(
            title: "Cancel", target: self, action: #selector(cancelTapped(_:))
        )
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1B}"  // Escape

        let confirmButton = NSButton(
            title: "Move to Trash", target: self, action: #selector(confirmTapped(_:))
        )
        confirmButton.bezelStyle = .rounded
        confirmButton.keyEquivalent = "\r"  // Return — intentional Return-on-destructive
        confirmButton.hasDestructiveAction = true

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let buttonRow = NSStackView(views: [spacer, cancelButton, confirmButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [
            trashIconExternalsCheckbox, trashExternalsWarningRow, buttonRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        let padding = Self.padding
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return container
    }

    // MARK: - Actions

    @objc private func cancelTapped(_ sender: NSButton) {
        delegate?.deleteVMSheetDidCancel(self)
    }

    @objc private func confirmTapped(_ sender: NSButton) {
        delegate?.deleteVMSheet(self, didConfirmTrashExternals: trashExternalsChecked)
    }

    @objc private func trashExternalsToggled(_ sender: NSButton) {
        // Conditional warning: visible only when checkbox is on AND at
        // least one external is shared with another VM.
        trashExternalsWarningRow.isHidden = !(trashExternalsChecked && anyShared)
    }

    // MARK: - Helpers

    private func formatSharedVMs(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return "\u{201C}\(names[0])\u{201D}"
        case 2: return "\u{201C}\(names[0])\u{201D} and \u{201C}\(names[1])\u{201D}"
        default:
            let head = names.dropLast().map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")
            return "\(head), and \u{201C}\(names.last ?? "")\u{201D}"
        }
    }

    private func makeHorizontalSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}

extension NSStackView {
    fileprivate func removeArrangedSubviews() {
        for view in arrangedSubviews {
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }
}

extension ExternalAttachment {
    /// SF Symbol for the row icon, matching the iconography elsewhere in
    /// the storage settings UI (`externaldrive` for disks, `opticaldisc`
    /// for removable media on the XHCI controller).
    fileprivate var symbolName: String {
        switch kind {
        case .storageDisk: return "externaldrive"
        case .removableMedia: return "opticaldisc"
        }
    }
}
