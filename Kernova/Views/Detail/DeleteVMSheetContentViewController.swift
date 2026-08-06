import AppKit

/// Delegate for ``DeleteVMSheetContentViewController``.
@MainActor
protocol DeleteVMSheetContentViewControllerDelegate: AnyObject {
    /// Invoked when the user clicks Cancel (or presses Escape).
    func deleteVMSheetDidCancel(_ vc: DeleteVMSheetContentViewController)

    /// Invoked when the user clicks the confirm button (Move to Trash, or
    /// Delete Immediately in the immediate-delete mode).
    ///
    /// `ids` are the externals whose checkbox is on at the moment of
    /// confirmation; locked-off shared or missing rows are never included.
    func deleteVMSheet(
        _ vc: DeleteVMSheetContentViewController,
        didConfirmDeletingExternalIDs ids: Set<UUID>
    )
}

/// Confirmation sheet shown when deleting a VM.
///
/// Lists the VM's in-bundle disks read-only, and external attachments with a
/// per-row checkbox defaulting off. A file shared with other VMs is locked off,
/// so a delete can never pull a disk out from under another VM.
@MainActor
final class DeleteVMSheetContentViewController: NSViewController {
    /// Disposition the sheet confirms: move the VM to the Trash, or delete it
    /// immediately (bypassing the Trash).
    enum Mode {
        case trash
        case immediate
    }

    weak var delegate: DeleteVMSheetContentViewControllerDelegate?

    private let vmName: String
    private let bundledDisks: [StorageDisk]
    private let externals: [ExternalAttachment]
    private let mode: Mode

    /// Per-row checkboxes for the *selectable* (non-shared) externals, keyed
    /// by attachment id.
    ///
    /// Shared externals get a disabled checkbox that is deliberately not
    /// recorded here, so they can never be collected on confirm.
    private(set) var checkboxes: [UUID: NSButton] = [:]

    /// Ids of the externals whose checkbox is currently on.
    var selectedExternalIDs: Set<UUID> {
        Set(checkboxes.filter { $0.value.state == .on }.map(\.key))
    }

    /// The "Select All" / "Deselect All" link in the external-files section header.
    ///
    /// Present only when two or more rows are selectable; its title tracks
    /// whether every selectable row is currently checked.
    private weak var selectAllButton: NSButton?

    /// Whether the content list is taller than the cap, so it scrolls rather than
    /// growing an over-tall sheet.
    private(set) var contentOverflows = false

    /// Shows the shared "more content below" cue (chevron + fade + scroller flash)
    /// while the list overflows the cap.
    private var scrollMoreIndicator: ScrollMoreIndicator?

    // MARK: - Layout constants

    private static let sheetWidth: CGFloat = 520
    private static let padding: CGFloat = 16
    /// Height at which the content list stops growing and starts scrolling.
    private static let scrollMaxHeight: CGFloat = 320

    /// Shared leading-icon column width for the header trash icon and the
    /// per-row attachment icon (sized to the 22pt header glyph; smaller
    /// symbols center within it).
    private static let iconColumnWidth: CGFloat = 22

    init(
        vmName: String,
        bundledDisks: [StorageDisk],
        externals: [ExternalAttachment],
        mode: Mode = .trash
    ) {
        self.vmName = vmName
        self.bundledDisks = bundledDisks
        self.externals = externals
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DeleteVMSheetContentViewController does not support NSCoder")
    }

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let header = makeHeader()
        let divider1 = makeHorizontalSeparator()
        let listScrollView = makeContentList()
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
        let iconName = mode == .immediate ? "exclamationmark.triangle.fill" : "trash"
        let icon = NSImageView(
            image: .systemSymbol(iconName, accessibilityDescription: "")
        )
        icon.contentTintColor = .systemRed
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageAlignment = .alignCenter
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentHuggingPriority(.required, for: .vertical)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .vertical)
        // Pin to the shared icon column so the title text starts at the
        // same X as the row labels below the first divider.
        icon.widthAnchor.constraint(equalToConstant: Self.iconColumnWidth).isActive = true

        let titleText: String
        let bodyText: String
        switch mode {
        case .trash:
            titleText = "Move \u{201C}\(vmName)\u{201D} to Trash?"
            bodyText =
                "The VM moves to the Trash. Restore it with Finder's Put Back, or empty the Trash to delete it permanently."
        case .immediate:
            titleText = "Delete \u{201C}\(vmName)\u{201D} Immediately?"
            // Name the external files only when at least one is selectable — a
            // list of only locked-off rows offers no choice, so the plain
            // VM-only wording stays accurate.
            bodyText =
                externals.contains(where: \.isSelectable)
                ? "This VM and its disks, plus any external files you select below, will be deleted immediately. You can't undo this action."
                : "This VM and its disks will be deleted immediately. You can't undo this action."
        }

        let title = NSTextField(labelWithString: titleText)
        title.font = .preferredFont(forTextStyle: .headline)
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 0
        title.isSelectable = false

        let body = NSTextField(wrappingLabelWithString: bodyText)
        body.font = .preferredFont(forTextStyle: .callout)
        body.textColor = .secondaryLabelColor
        body.lineBreakMode = .byWordWrapping
        body.maximumNumberOfLines = 0
        body.isSelectable = false

        let textStack = NSStackView(views: [title, body])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = Spacing.tight

        let headerStack = NSStackView(views: [icon, textStack])
        headerStack.orientation = .horizontal
        headerStack.alignment = .firstBaseline
        headerStack.spacing = Spacing.medium
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(headerStack)
        let padding = Self.padding
        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            headerStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            headerStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            headerStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),
        ])
        return container
    }

    // MARK: - Content list

    private func makeContentList() -> NSScrollView {
        let scrollView = NSScrollView()
        // Flipped clip view so content anchors at the TOP and tall content
        // scrolls downward (a default NSClipView bottom-anchors short content
        // and shows the bottom first).
        scrollView.contentView = FlippedClipView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        // Disable safe-area-like auto-adjustment AND zero the clip view's own
        // contentInsets — on macOS Tahoe the default contributes a visible ~10pt
        // of padding above the document.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.contentView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.contentInsets = NSEdgeInsetsZero
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = Spacing.medium
        listStack.edgeInsets = NSEdgeInsets(
            top: Self.padding,
            left: Self.padding,
            bottom: Self.padding,
            right: Self.padding
        )
        listStack.translatesAutoresizingMaskIntoConstraints = false

        // Section 1 — in-bundle disks removed along with the VM.
        listStack.addArrangedSubview(makeGroupedFormSectionHeader("Removed with the VM"))
        for disk in bundledDisks {
            listStack.addArrangedSubview(makeBundledRow(disk))
        }

        // Section 2 — external files the user can individually trash.
        if !externals.isEmpty {
            // Extra breathing room separating the two sections.
            if let lastBundledRow = listStack.arrangedSubviews.last {
                listStack.setCustomSpacing(Self.padding, after: lastBundledRow)
            }
            let selectableCount = externals.filter(\.isSelectable).count
            let externalHeader = makeExternalSectionHeader(selectableCount: selectableCount)
            listStack.addArrangedSubview(externalHeader)
            // With a Select All link present, the row must span the content
            // column so the link trails — the .leading-aligned stack otherwise
            // lets it hug its label. Insets trim the stack's padding.
            if selectAllButton != nil {
                externalHeader.widthAnchor.constraint(
                    equalTo: listStack.widthAnchor, constant: -2 * Self.padding
                ).isActive = true
            }
            for external in externals {
                listStack.addArrangedSubview(makeExternalRow(external))
            }
            refreshSelectAllButtonTitle()
        }

        let docView = NSView()
        docView.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(listStack)
        scrollView.documentView = docView
        let clip = scrollView.contentView

        // Drive the geometry from the content's measured height rather than the
        // NSScrollView/NSStackView priority interplay, which resolves the cap by
        // *compressing* rows. The document is pinned to its measured height, and
        // the scroll view's visible height is `min(content, cap)`.
        //
        // Measure at the actual render width — the row titles and shared-file
        // warning are wrapping labels — and re-measure narrower only when a
        // legacy (always-shown) scroller reserves a gutter; overlay ones float.
        let fullWidthHeight = measuredContentHeight(of: listStack, atWidth: Self.sheetWidth)
        contentOverflows = fullWidthHeight > Self.scrollMaxHeight
        let contentHeight: CGFloat
        let visibleHeight: CGFloat
        if contentOverflows {
            let gutter =
                NSScroller.preferredScrollerStyle == .legacy
                ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
                : 0
            contentHeight =
                gutter > 0
                ? measuredContentHeight(of: listStack, atWidth: Self.sheetWidth - gutter)
                : fullWidthHeight
            visibleHeight = Self.scrollMaxHeight
        } else {
            contentHeight = fullWidthHeight
            visibleHeight = fullWidthHeight
        }

        NSLayoutConstraint.activate([
            docView.topAnchor.constraint(equalTo: clip.topAnchor),
            docView.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            docView.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            docView.widthAnchor.constraint(equalTo: clip.widthAnchor),
            docView.heightAnchor.constraint(equalToConstant: contentHeight),

            listStack.topAnchor.constraint(equalTo: docView.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: docView.bottomAnchor),
            listStack.leadingAnchor.constraint(equalTo: docView.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: docView.trailingAnchor),

            scrollView.heightAnchor.constraint(equalToConstant: visibleHeight),
        ])

        scrollMoreIndicator = ScrollMoreIndicator(scrollView: scrollView)
        return scrollView
    }

    /// Height the content `stack` needs when laid out at `width`.
    private func measuredContentHeight(of stack: NSView, atWidth width: CGFloat) -> CGFloat {
        let widthConstraint = stack.widthAnchor.constraint(equalToConstant: width)
        widthConstraint.isActive = true
        stack.layoutSubtreeIfNeeded()
        let height = stack.fittingSize.height
        widthConstraint.isActive = false
        return height
    }

    /// Read-only row for an in-bundle disk (no checkbox; it rides along with
    /// the bundle).
    private func makeBundledRow(_ disk: StorageDisk) -> NSView {
        let icon = NSImageView(
            image: .systemSymbol(diskIconSystemName(for: disk), accessibilityDescription: "")
        )
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageAlignment = .alignCenter
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: Self.iconColumnWidth).isActive = true

        let label = NSTextField(labelWithString: disk.label)
        label.font = Typography.body
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.isSelectable = false
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let subtitle = NSTextField(labelWithString: disk.displayPath)
        subtitle.font = .preferredFont(forTextStyle: .caption1)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.maximumNumberOfLines = 1
        subtitle.isSelectable = false
        subtitle.setContentHuggingPriority(.defaultLow, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [label, subtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = Spacing.hairline

        let row = NSStackView(views: [icon, textStack])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = Spacing.medium
        return row
    }

    /// Header for the "Files outside this VM" section.
    private func makeExternalSectionHeader(selectableCount: Int) -> NSView {
        let label = makeGroupedFormSectionHeader("Files outside this VM")
        guard selectableCount >= 2 else { return label }

        // The label hugs its text so the spacer (lower hugging) is the view that
        // stretches to fill the full-width row — otherwise the label and spacer
        // share the default 250 priority and Auto Layout can't tell which grows.
        label.setContentHuggingPriority(.required, for: .horizontal)

        let button = makeLinkButton(
            "Select All", target: self, action: #selector(selectAllToggled(_:)))
        selectAllButton = button

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [label, spacer, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Spacing.medium
        return row
    }

    /// Row for an external attachment, with a leading checkbox.
    ///
    /// Exclusively owned files default to **off** (kept), so trashing a host file
    /// the user placed outside the bundle is opt-in. Shared and missing files are
    /// locked off with an inline warning and never recorded in `checkboxes`, so
    /// they can never be collected on confirm.
    private func makeExternalRow(_ external: ExternalAttachment) -> NSView {
        let checkbox = NSButton(checkboxWithTitle: "", target: self, action: nil)
        checkbox.identifier = NSUserInterfaceItemIdentifier(external.id.uuidString)
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.setContentHuggingPriority(.required, for: .horizontal)
        checkbox.setContentCompressionResistancePriority(.required, for: .horizontal)
        if external.isSelectable {
            checkbox.state = .off
            checkbox.action = #selector(externalRowToggled(_:))
            checkboxes[external.id] = checkbox
        } else {
            checkbox.state = .off
            checkbox.isEnabled = false
        }

        let icon = NSImageView(
            image: .systemSymbol(external.symbolName, accessibilityDescription: "")
        )
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageAlignment = .alignCenter
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: Self.iconColumnWidth).isActive = true

        let label = NSTextField(labelWithString: external.label)
        label.font = Typography.body
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.isSelectable = false
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let path = makeAttachmentSubtitleLabel(path: external.path, isMissing: external.isMissing)

        var textViews: [NSView] = [label, path]
        if external.isShared {
            // Shared takes precedence over missing: other VMs still reference the
            // path, so "kept" is the accurate framing even if this VM's copy is gone.
            textViews.append(
                makeInlineWarningRow(
                    "Kept — still used by \(DataFormatters.quotedList(external.sharedWithVMNames))"
                )
            )
        } else if external.isMissing {
            textViews.append(makeInlineWarningRow("Already gone — nothing to remove"))
        }

        let textStack = NSStackView(views: textViews)
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = Spacing.hairline

        let row = NSStackView(views: [checkbox, icon, textStack])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = Spacing.medium
        return row
    }

    /// A caution-triangle + caption row appended under a locked-off external,
    /// used for both the shared ("Kept — …") and missing ("Already gone …") notes.
    private func makeInlineWarningRow(_ text: String) -> NSView {
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
        stack.spacing = Spacing.small
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    // MARK: - Footer

    private func makeFooter() -> NSView {
        let container = NSView()

        let cancelButton = NSButton(
            title: "Cancel", target: self, action: #selector(cancelTapped(_:))
        )
        cancelButton.bezelStyle = .push
        cancelButton.keyEquivalent = "\u{1B}"  // Escape

        // No ellipsis on the action buttons themselves (project HIG: "none on alert
        // buttons"); the ellipsis lives on the menu items that open this sheet.
        let confirmButton = NSButton(
            title: mode == .immediate ? "Delete Immediately" : "Move to Trash",
            target: self, action: #selector(confirmTapped(_:))
        )
        confirmButton.bezelStyle = .push
        // Trash is recoverable, so confirm is the intentional Return default. Immediate
        // delete is irreversible: no Return default, so a stray Return can't trigger it —
        // the user must click (or press Escape to cancel).
        if mode == .trash {
            confirmButton.keyEquivalent = "\r"
        }
        confirmButton.hasDestructiveAction = true

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let buttonRow = NSStackView(views: [spacer, cancelButton, confirmButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = Spacing.standard
        buttonRow.alignment = .centerY
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(buttonRow)
        let padding = Self.padding
        NSLayoutConstraint.activate([
            buttonRow.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            buttonRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            buttonRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            buttonRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),
        ])
        return container
    }

    // MARK: - Actions

    @objc private func cancelTapped(_: NSButton) {
        delegate?.deleteVMSheetDidCancel(self)
    }

    @objc private func confirmTapped(_: NSButton) {
        delegate?.deleteVMSheet(self, didConfirmDeletingExternalIDs: selectedExternalIDs)
    }

    /// Bulk-toggles every selectable external row.
    @objc private func selectAllToggled(_: NSButton) {
        let newState: NSControl.StateValue = allSelectableRowsOn ? .off : .on
        for checkbox in checkboxes.values { checkbox.state = newState }
        refreshSelectAllButtonTitle()
    }

    /// Keeps the Select All / Deselect All title in sync when an individual row
    /// is toggled.
    @objc private func externalRowToggled(_: NSButton) {
        refreshSelectAllButtonTitle()
    }

    /// `true` when every selectable external row is currently checked (and at
    /// least one exists).
    private var allSelectableRowsOn: Bool {
        !checkboxes.isEmpty && checkboxes.values.allSatisfy { $0.state == .on }
    }

    private func refreshSelectAllButtonTitle() {
        selectAllButton?.title = allSelectableRowsOn ? "Deselect All" : "Select All"
    }

    // MARK: - Helpers

    private func makeHorizontalSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}

extension ExternalAttachment {
    /// `true` when this external can be individually selected for trashing —
    /// i.e. it is exclusively owned (not shared with another VM) and present on
    /// disk.
    fileprivate var isSelectable: Bool { !isShared && !isMissing }

    /// SF Symbol for the row icon, matching the storage settings UI.
    fileprivate var symbolName: String {
        switch kind {
        case .storageDisk: return "externaldrive"
        case .removableMedia: return "opticaldisc"
        }
    }
}
