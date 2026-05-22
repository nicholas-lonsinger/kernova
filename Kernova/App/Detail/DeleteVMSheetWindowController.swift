import AppKit

/// Confirmation sheet shown when deleting a VM that references external
/// files (storage disks or removable media outside the bundle).
///
/// The simple delete confirmation (no externals) is handled by
/// ``LifecycleAlertCoordinator`` via ``AlertPresenter``.
@MainActor
final class DeleteVMSheetWindowController: NSWindowController {
    private let instance: VMInstance
    private let externals: [ExternalAttachment]
    private var trashExternals: Bool
    private let onCancel: () -> Void
    private let onConfirm: (Bool) -> Void

    private let toggleButton = NSButton(checkboxWithTitle: "Also move these files to Trash", target: nil, action: nil)
    private let warningStack = NSStackView()
    private var continuation: CheckedContinuation<Void, Never>?

    init(
        instance: VMInstance,
        externals: [ExternalAttachment],
        initialTrashExternals: Bool,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (Bool) -> Void
    ) {
        self.instance = instance
        self.externals = externals
        self.trashExternals = initialTrashExternals
        self.onCancel = onCancel
        self.onConfirm = onConfirm

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Delete Virtual Machine"

        super.init(window: window)

        let root = NSViewController()
        root.view = buildRootView()
        window.contentViewController = root
        toggleButton.state = trashExternals ? .on : .off
        toggleButton.target = self
        toggleButton.action = #selector(toggleTrashExternals(_:))
        updateWarningVisibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DeleteVMSheetWindowController does not support NSCoder")
    }

    func runSheet(on parent: NSWindow) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
            guard let window = self.window else {
                cont.resume()
                return
            }
            parent.beginSheet(window) { [weak self] _ in
                self?.continuation?.resume()
                self?.continuation = nil
            }
        }
    }

    // MARK: - View construction

    private func buildRootView() -> NSView {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let header = buildHeader()
        let topDivider = NSBox(); topDivider.boxType = .separator
        topDivider.translatesAutoresizingMaskIntoConstraints = false
        let externalsScroll = buildExternalsScrollView()
        let bottomDivider = NSBox(); bottomDivider.boxType = .separator
        bottomDivider.translatesAutoresizingMaskIntoConstraints = false
        let footer = buildFooter()

        root.addSubview(header)
        root.addSubview(topDivider)
        root.addSubview(externalsScroll)
        root.addSubview(bottomDivider)
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            topDivider.topAnchor.constraint(equalTo: header.bottomAnchor),
            topDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            externalsScroll.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            externalsScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            externalsScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            externalsScroll.heightAnchor.constraint(lessThanOrEqualToConstant: 240),

            bottomDivider.topAnchor.constraint(equalTo: externalsScroll.bottomAnchor),
            bottomDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            footer.topAnchor.constraint(equalTo: bottomDivider.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            root.widthAnchor.constraint(equalToConstant: 520),
        ])

        return root
    }

    private func buildHeader() -> NSView {
        let icon = NSImageView(image: .systemSymbol("trash", accessibilityDescription: ""))
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        icon.contentTintColor = .systemRed

        let title = NSTextField(labelWithString: "Move \u{201C}\(instance.name)\u{201D} to Trash?")
        title.font = .preferredFont(forTextStyle: .headline)
        title.lineBreakMode = .byTruncatingMiddle

        let body = NSTextField(
            wrappingLabelWithString:
                "The VM bundle will be moved to the Trash. You can restore it using Finder's "
                + "Put Back command. Empty the Trash to permanently delete the VM and reclaim disk space."
        )
        body.font = .preferredFont(forTextStyle: .callout)
        body.textColor = .secondaryLabelColor
        body.maximumNumberOfLines = 0

        let textStack = NSStackView(views: [title, body])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4

        let row = NSStackView(views: [icon, textStack])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func buildExternalsScrollView() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 12
        list.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        list.translatesAutoresizingMaskIntoConstraints = false

        for external in externals {
            list.addArrangedSubview(buildRow(for: external))
        }

        let documentView = NSView()
        documentView.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: documentView.topAnchor),
            list.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
        scroll.documentView = documentView
        return scroll
    }

    private func buildRow(for external: ExternalAttachment) -> NSView {
        let symbolName = external.kind == .storageDisk ? "externaldrive" : "opticaldisc"
        let icon = NSImageView(image: .systemSymbol(symbolName, accessibilityDescription: ""))
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 18)
        ])

        let label = NSTextField(labelWithString: external.label)
        label.font = .preferredFont(forTextStyle: .body)

        let pathLabel = NSTextField(labelWithString: external.path)
        pathLabel.font = .preferredFont(forTextStyle: .caption1)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle

        var stackSubviews: [NSView] = [label, pathLabel]
        if external.isShared {
            stackSubviews.append(buildSharedWarning(external: external))
        }
        let textStack = NSStackView(views: stackSubviews)
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let row = NSStackView(views: [icon, textStack])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        return row
    }

    private func buildSharedWarning(external: ExternalAttachment) -> NSView {
        let warningIcon = NSImageView(
            image: .systemSymbol("exclamationmark.triangle.fill", accessibilityDescription: "")
        )
        warningIcon.contentTintColor = .systemOrange
        let text = NSTextField(
            labelWithString: "Also used by \(Self.formatSharedVMs(external.sharedWithVMNames))"
        )
        text.font = .preferredFont(forTextStyle: .caption1)
        text.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [warningIcon, text])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        return stack
    }

    private func buildFooter() -> NSView {
        warningStack.orientation = .horizontal
        warningStack.spacing = 4
        warningStack.alignment = .top
        let warningIcon = NSImageView(
            image: .systemSymbol("exclamationmark.triangle.fill", accessibilityDescription: "")
        )
        warningIcon.contentTintColor = .systemOrange
        let warningText = NSTextField(
            wrappingLabelWithString:
                "Files marked as shared will become unavailable to the VMs listed above."
        )
        warningText.font = .preferredFont(forTextStyle: .caption1)
        warningText.maximumNumberOfLines = 0
        warningStack.setViews([warningIcon, warningText], in: .leading)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.keyEquivalent = "\u{1B}"

        let confirmButton = NSButton(title: "Move to Trash", target: self, action: #selector(confirm(_:)))
        confirmButton.keyEquivalent = "\r"
        confirmButton.hasDestructiveAction = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let buttonRow = NSStackView(views: [spacer, cancelButton, confirmButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY

        let stack = NSStackView(views: [toggleButton, warningStack, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    // MARK: - Actions

    @objc private func toggleTrashExternals(_ sender: NSButton) {
        trashExternals = sender.state == .on
        updateWarningVisibility()
    }

    private func updateWarningVisibility() {
        let anyShared = externals.contains(where: \.isShared)
        warningStack.isHidden = !(trashExternals && anyShared)
    }

    @objc private func cancel(_ sender: Any?) {
        endSheet(returnCode: .cancel)
        onCancel()
    }

    @objc private func confirm(_ sender: Any?) {
        endSheet(returnCode: .OK)
        onConfirm(trashExternals)
    }

    private func endSheet(returnCode: NSApplication.ModalResponse) {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window, returnCode: returnCode)
    }

    // MARK: - Helpers

    private static func formatSharedVMs(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return "\u{201C}\(names[0])\u{201D}"
        case 2: return "\u{201C}\(names[0])\u{201D} and \u{201C}\(names[1])\u{201D}"
        default:
            let head = names.dropLast().map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")
            return "\(head), and \u{201C}\(names.last ?? "")\u{201D}"
        }
    }
}
