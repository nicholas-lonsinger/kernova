import AppKit

/// Popover content for "Create New Disk".
///
/// Shared between the Storage Disks and Removable Media sections. The
/// caller owns the ``PopoverPresenter`` and closes it from inside the
/// ``onCancel`` / ``onCreate`` callbacks.
@MainActor
final class CreateDiskPopoverController: NSViewController {
    private let isRemovable: Bool
    private var currentSize: Int
    private let onCancel: () -> Void
    private let onCreate: (Int) -> Void

    init(
        isRemovable: Bool,
        initialSize: Int,
        onCancel: @escaping () -> Void,
        onCreate: @escaping (Int) -> Void
    ) {
        self.isRemovable = isRemovable
        self.currentSize = initialSize
        self.onCancel = onCancel
        self.onCreate = onCreate
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CreateDiskPopoverController does not support NSCoder")
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(
            labelWithString:
                isRemovable ? "Create New Removable Disk" : "Create New Disk")
        title.font = .preferredFont(forTextStyle: .headline)

        let sizePopup = NSPopUpButton()
        for size in VMGuestOS.allDiskSizes {
            let item = NSMenuItem(
                title: DataFormatters.formatDiskSize(size), action: nil, keyEquivalent: ""
            )
            item.representedObject = size
            sizePopup.menu?.addItem(item)
        }
        if let idx = VMGuestOS.allDiskSizes.firstIndex(of: currentSize) {
            sizePopup.selectItem(at: idx)
        }
        sizePopup.target = self
        sizePopup.action = #selector(sizeChanged(_:))

        let body = NSTextField(
            wrappingLabelWithString:
                isRemovable
                ? "Creates a writable ASIF sparse disk image at a location you choose, attached as a hot-pluggable USB drive. The file lives outside the VM bundle."
                : "Creates an ASIF sparse disk image inside the VM bundle. Physical size grows as data is written."
        )
        body.font = .preferredFont(forTextStyle: .caption1)
        body.textColor = .secondaryLabelColor
        body.maximumNumberOfLines = 0
        body.preferredMaxLayoutWidth = 240

        let cancel = NSButton(
            title: "Cancel", target: self, action: #selector(cancelTapped(_:)))
        cancel.keyEquivalent = "\u{1B}"
        let confirm = NSButton(
            title: "Create", target: self, action: #selector(createTapped(_:)))
        confirm.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [cancel, spacer, confirm])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY

        let stack = NSStackView(views: [title, sizePopup, body, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])
        view = root
        root.layoutSubtreeIfNeeded()
        preferredContentSize = root.fittingSize
    }

    @objc private func sizeChanged(_ sender: NSPopUpButton) {
        if let size = sender.selectedItem?.representedObject as? Int {
            currentSize = size
        }
    }

    @objc private func cancelTapped(_ sender: Any?) {
        onCancel()
    }

    @objc private func createTapped(_ sender: Any?) {
        onCreate(currentSize)
    }
}
