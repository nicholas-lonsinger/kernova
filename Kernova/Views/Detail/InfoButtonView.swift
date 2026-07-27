import AppKit

/// Info-circle `NSButton` that opens an `NSPopover` of body paragraphs when
/// clicked.
///
/// The button is wrapped in a fixed 16×16 view so the info circle stays tight
/// against the trailing edge of its label instead of being stretched by its
/// container, and the popover anchors to that wrapper so `.minY` ("below") is
/// read in an unflipped coordinate system.
@MainActor
final class InfoButtonView: NSView {
    let button = NSButton()

    /// Owns the per-button popover lifecycle.
    private let coordinator = Coordinator()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        button.target = coordinator
        button.action = #selector(Coordinator.buttonClicked(_:))
        coordinator.anchor = self
        addSubview(button)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 16),
            heightAnchor.constraint(equalToConstant: 16),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("InfoButtonView does not support NSCoder")
    }

    /// Set the info-circle icon, hover tooltip, VoiceOver label, and the
    /// popover paragraph payload that fires on click.
    ///
    /// Safe to call repeatedly; `label` is the section or control name, rendered
    /// as "About \(label)".
    func configure(label: String, paragraphs: [InfoPopoverParagraph]) {
        let about = "About \(label)"
        let config = NSImage.SymbolConfiguration(scale: .small)
        button.image = NSImage.systemSymbol(
            "info.circle", accessibilityDescription: about
        )
        .withSymbolConfiguration(config)
        button.toolTip = about
        button.setAccessibilityLabel(about)
        coordinator.paragraphs = paragraphs
    }

    /// Owns the per-button ``PopoverPresenter`` and the latest paragraph
    /// snapshot to render when the button is clicked.
    @MainActor
    private final class Coordinator {
        let presenter = PopoverPresenter()
        /// Wrapper `NSView` used as the popover's positioning view.
        weak var anchor: NSView?
        var paragraphs: [InfoPopoverParagraph] = []

        @objc func buttonClicked(_: NSButton) {
            guard let anchor else { return }
            let vc = InfoPopoverContentViewController(paragraphs: paragraphs)
            presenter.show(content: vc, from: anchor, preferredEdge: .minY)
        }
    }
}
