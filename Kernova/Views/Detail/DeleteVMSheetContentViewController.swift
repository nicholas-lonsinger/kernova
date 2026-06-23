import AppKit

/// Delegate for ``DeleteVMSheetContentViewController``.
///
/// The view controller is intentionally decoupled from `VMLibraryViewModel`.
/// The host (the presenter, e.g. `DetailAlertsPresenter`) implements these
/// methods and forwards the user's choice to the view model.
@MainActor
protocol DeleteVMSheetContentViewControllerDelegate: AnyObject {
    /// Invoked when the user clicks Cancel (or presses Escape).
    func deleteVMSheetDidCancel(_ vc: DeleteVMSheetContentViewController)

    /// Invoked when the user clicks the confirm button (Move to Trash, or
    /// Delete Immediately in the immediate-delete mode).
    ///
    /// The host knows which disposition the sheet was shown with, so the
    /// trash-vs-immediate choice is not re-encoded here.
    ///
    /// - Parameters:
    ///   - vc: The sheet view controller firing the event.
    ///   - ids: The ids of the external attachments whose per-row checkbox
    ///     is on at the moment of confirmation. Shared attachments are never
    ///     included — their checkbox is locked off.
    func deleteVMSheet(
        _ vc: DeleteVMSheetContentViewController,
        didConfirmDeletingExternalIDs ids: Set<UUID>
    )
}

/// Confirmation sheet shown when deleting a VM.
///
/// Lists everything the deletion touches in two sections:
///
/// - **Removed with the VM** — the VM's in-bundle (internal) disks, shown
///   read-only. They live inside the bundle and are trashed along with it;
///   there's nothing to decide, but they're surfaced so the user sees the
///   full picture of what's being deleted.
/// - **Files outside this VM** — external storage disks and removable media
///   that live outside the bundle. Each gets its own checkbox so the user
///   can pick which to move to Trash. A file **shared** with other VMs is
///   shown with its checkbox locked off (deleting this VM only detaches it),
///   so a delete can never pull a disk out from under another VM.
///
/// The bundled Guest Agent installer is already filtered out upstream (it's
/// app-owned, not a user file), so it never appears here.
@MainActor
final class DeleteVMSheetContentViewController: NSViewController {
    /// Disposition the sheet confirms: move the VM to the Trash, or delete it
    /// immediately (bypassing the Trash).
    ///
    /// Drives the title, body, and confirm button — including whether the
    /// confirm button is the Return default.
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
    /// recorded here, so they can never be collected on confirm. Exposed
    /// `private(set)` so tests can read state and toggle a specific row's
    /// `NSButton`.
    private(set) var checkboxes: [UUID: NSButton] = [:]

    /// Ids of the externals whose checkbox is currently on.
    var selectedExternalIDs: Set<UUID> {
        Set(checkboxes.filter { $0.value.state == .on }.map(\.key))
    }

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
    ///
    /// The list hugs its content below this; a VM with many disks scrolls
    /// rather than producing an over-tall sheet. Every row keeps its full
    /// intrinsic height either way (see the constraints in `makeContentList`).
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
        // Immediate delete bypasses the Trash, so it gets a caution glyph rather
        // than the trash can that visually implies the recoverable Put-Back flow.
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
            // When externals are listed, they're removed with the same (permanent)
            // disposition, so name them — the body shows above the checkbox list.
            bodyText =
                externals.isEmpty
                ? "This VM and its disks will be deleted immediately. You can't undo this action."
                : "This VM and its disks, plus any external files you select below, will be deleted immediately. You can't undo this action."
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
        // and shows the bottom first). Same `FlippedClipView` the grouped-form
        // scroll views use.
        scrollView.contentView = FlippedClipView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        // Use the system's scroller style (matches every other scroll view in
        // the app). When the list overflows, `ScrollMoreIndicator` shows the
        // "there's more below" cue (chevron + fade + a one-time scroller flash).
        // Disable safe-area-like auto-adjustment AND zero the clip view's
        // own contentInsets — on macOS Tahoe the default contributes a
        // visible ~10pt of padding above the document.
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

        // Section 1 — in-bundle disks removed along with the VM. Always
        // present: every VM has at least its main disk.
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
            listStack.addArrangedSubview(makeGroupedFormSectionHeader("Files outside this VM"))
            for external in externals {
                listStack.addArrangedSubview(makeExternalRow(external))
            }
        }

        // Wrap the stack in a plain document view pinned to all four edges of
        // it, so the document view exactly tracks the stack.
        let docView = NSView()
        docView.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(listStack)
        scrollView.documentView = docView
        let clip = scrollView.contentView

        // Drive the geometry from the content's measured height rather than the
        // NSScrollView/NSStackView priority interplay (which kept resolving the
        // cap by *compressing* the rows). The document is pinned to its measured
        // height (so it physically cannot compress — every row keeps its full
        // height) and the scroll view's visible height is `min(content, cap)`:
        // a short list is hugged, a long one is capped and scrolls.
        //
        // The height MUST be measured at the actual render width, because the
        // shared-file warning ("Kept — still used by …") and the row titles are
        // wrapping labels: a file shared with several VMs wraps onto extra lines.
        // The render width is the full sheet width — minus a scroller gutter
        // only on systems set to "Always show scroll bars" (legacy style, which
        // reserves width); overlay scrollers float and reserve nothing. So
        // measure at full width to detect overflow, then re-measure narrower
        // only when an in-flow gutter scroller will actually be shown.
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
    ///
    /// Pins the stack to `width` so wrapping rows (the shared-file warning)
    /// report their true multi-line height, measures, then releases the
    /// constraint (render width is governed by the clip-view pin).
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

    /// Row for an external attachment, with a leading checkbox.
    ///
    /// Exclusively owned files default to on (trash). Shared files get a
    /// disabled, always-off checkbox plus an inline "kept" warning. Missing
    /// files (backing path no longer resolves) are likewise locked off — there
    /// is nothing to trash — with the path shown in the red "Missing —" style
    /// and an "already gone" note. A locked-off checkbox is never recorded in
    /// `checkboxes`, so it can never be collected on confirm.
    private func makeExternalRow(_ external: ExternalAttachment) -> NSView {
        let checkbox = NSButton(checkboxWithTitle: "", target: self, action: nil)
        checkbox.identifier = NSUserInterfaceItemIdentifier(external.id.uuidString)
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.setContentHuggingPriority(.required, for: .horizontal)
        checkbox.setContentCompressionResistancePriority(.required, for: .horizontal)
        if external.isShared || external.isMissing {
            checkbox.state = .off
            checkbox.isEnabled = false
        } else {
            checkbox.state = .on
            checkboxes[external.id] = checkbox
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

        // Shared by the settings pane and Boot Order sheet: a present path renders
        // as a secondary-color middle-truncated caption; a missing one gets the
        // bold red "Missing —" prefix.
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
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1B}"  // Escape

        // No ellipsis on the action buttons themselves (project HIG: "none on alert
        // buttons"); the ellipsis lives on the menu items that open this sheet.
        let confirmButton = NSButton(
            title: mode == .immediate ? "Delete Immediately" : "Move to Trash",
            target: self, action: #selector(confirmTapped(_:))
        )
        confirmButton.bezelStyle = .rounded
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

    // MARK: - Helpers

    private func makeHorizontalSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
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
