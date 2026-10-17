import AppKit

/// Leading icon for a storage / removable-media row.
@MainActor
final class AttachmentIconButton: NSView {
    private let warningButton = NSButton()
    private let plainIcon = NSImageView()
    private let popoverPresenter = PopoverPresenter()
    private var currentPath: String?

    /// Optional action for clicking the icon in its non-missing (plain) state.
    ///
    /// Receives `self` so the caller can anchor a popover to the icon.
    var onActivate: ((NSView) -> Void)? {
        didSet {
            activateRecognizer.isEnabled = onActivate != nil
            toolTip = onActivate != nil ? "Show Info" : nil
        }
    }

    private lazy var activateRecognizer: NSClickGestureRecognizer = {
        let recognizer = NSClickGestureRecognizer(
            target: self, action: #selector(plainIconActivated))
        recognizer.isEnabled = false
        return recognizer
    }()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 20),
            heightAnchor.constraint(equalToConstant: 20),
        ])

        plainIcon.translatesAutoresizingMaskIntoConstraints = false
        plainIcon.contentTintColor = .secondaryLabelColor
        plainIcon.imageScaling = .scaleProportionallyUpOrDown
        plainIcon.addGestureRecognizer(activateRecognizer)
        // Hidden until `configure(systemName:missingPath:)` reveals the correct
        // state; otherwise the unconfigured cell briefly shows an empty 20×20
        // icon slot.
        plainIcon.isHidden = true
        addSubview(plainIcon)
        NSLayoutConstraint.activate([
            plainIcon.leadingAnchor.constraint(equalTo: leadingAnchor),
            plainIcon.trailingAnchor.constraint(equalTo: trailingAnchor),
            plainIcon.topAnchor.constraint(equalTo: topAnchor),
            plainIcon.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        warningButton.translatesAutoresizingMaskIntoConstraints = false
        warningButton.bezelStyle = .accessoryBarAction
        warningButton.isBordered = false
        warningButton.image = .systemSymbol(
            "exclamationmark.triangle.fill", accessibilityDescription: "File missing — show details"
        )
        warningButton.contentTintColor = .systemRed
        warningButton.target = self
        warningButton.action = #selector(showMissingPopover(_:))
        warningButton.imageScaling = .scaleProportionallyUpOrDown
        warningButton.toolTip = "File missing"
        warningButton.setAccessibilityLabel("File missing — show details")
        warningButton.isHidden = true
        addSubview(warningButton)
        NSLayoutConstraint.activate([
            warningButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            warningButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            warningButton.topAnchor.constraint(equalTo: topAnchor),
            warningButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AttachmentIconButton does not support NSCoder")
    }

    /// Pass `missingPath` to render the missing-file warning state.
    func configure(systemName: String, missingPath: String?) {
        currentPath = missingPath
        if missingPath != nil {
            warningButton.isHidden = false
            plainIcon.isHidden = true
        } else {
            warningButton.isHidden = true
            plainIcon.isHidden = false
            plainIcon.image = .systemSymbol(systemName, accessibilityDescription: systemName)
        }
    }

    @objc private func plainIconActivated() {
        onActivate?(self)
    }

    @objc private func showMissingPopover(_: Any?) {
        guard let path = currentPath else { return }
        let content = MissingAttachmentPopoverContentViewController(path: path)
        // Anchor to `self` (the wrapper `NSView`) rather than the inner
        // `warningButton` so `NSPopover.preferredEdge` is interpreted in an
        // unflipped coordinate system — AppKit controls like `NSButton` can
        // return `isFlipped == true`, which inverts `.minY` to mean the top
        // edge and places the popover above instead of below.
        popoverPresenter.show(content: content, from: self, preferredEdge: .minY)
    }
}
