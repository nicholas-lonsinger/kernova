import AppKit

/// Info-circle `NSButton` that opens an `NSPopover` of body paragraphs when
/// clicked.
///
/// AppKit call sites instantiate `InfoButtonView` and call
/// ``InfoButtonView/configure(label:paragraphs:)``. Paragraphs are plain values
/// (`.body(...)` for prose, `.code(...)` for monospaced snippets); the popover
/// content is rendered by ``InfoPopoverContentViewController``.
///
/// The button is wrapped in this view rather than exposed directly so the
/// popover anchors to a fixed 16×16 inner button: that keeps the info-circle
/// tight against the trailing edge of the section/control label instead of
/// being stretched by its container, and anchoring on the inner button keeps
/// `.minY` ("below") in standard AppKit coordinates.
@MainActor
final class InfoButtonView: NSView {
    let button = NSButton()

    /// Owns the per-button popover lifecycle.
    ///
    /// Private so AppKit callers don't accidentally couple to the
    /// internal state — go through ``configure(label:paragraphs:)``
    /// instead.
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
    /// Safe to call repeatedly — re-invoked by callers during
    /// view-controller setup or reuse.
    ///
    /// - Parameters:
    ///   - label: Section or control name; rendered as "About \(label)"
    ///     in the tooltip and VoiceOver label.
    ///   - paragraphs: Popover body content.
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
        ///
        /// See the type-level note on ``InfoButtonView`` for why
        /// anchoring on the wrapper (not the inner `NSButton`) matters.
        weak var anchor: NSView?
        var paragraphs: [InfoPopoverParagraph] = []

        @objc func buttonClicked(_: NSButton) {
            guard let anchor else { return }
            let vc = InfoPopoverContentViewController(paragraphs: paragraphs)
            presenter.show(content: vc, from: anchor, preferredEdge: .minY)
        }
    }
}
