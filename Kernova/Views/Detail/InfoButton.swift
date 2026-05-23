import AppKit
import SwiftUI

/// SwiftUI shim wrapping an AppKit info-circle `NSButton` that opens an
/// `NSPopover` showing the supplied body paragraphs.
///
/// Replaces the previous SwiftUI-only `InfoButton<Content: View>` that
/// accepted arbitrary SwiftUI content via `@ViewBuilder`. The AppKit
/// popover takes plain `String` paragraphs because hosting arbitrary
/// SwiftUI inside an AppKit popover would defeat the AppKit-first
/// migration — the call surface is `(label:, paragraphs:)` instead.
///
/// AppKit call sites instantiate ``InfoButtonView`` directly and call
/// ``InfoButtonView/configure(label:paragraphs:)``; this shim exists so
/// SwiftUI parents keep the same `InfoButton(label:paragraphs:)` surface
/// during the incremental SwiftUI→AppKit transition.
struct InfoButton: NSViewRepresentable {
    /// Section or control name.
    ///
    /// Used as the hover tooltip and VoiceOver label ("About \(label)").
    /// Not shown inside the popover itself.
    let label: String
    /// Paragraphs shown inside the popover, top to bottom.
    ///
    /// Use `.body(...)` for plain prose and `.code(...)` for monospaced
    /// selectable snippets (shell commands, paths, etc.).
    let paragraphs: [InfoPopoverParagraph]

    func makeNSView(context: Context) -> InfoButtonView {
        let view = InfoButtonView()
        view.configure(label: label, paragraphs: paragraphs)
        return view
    }

    func updateNSView(_ view: InfoButtonView, context: Context) {
        view.configure(label: label, paragraphs: paragraphs)
    }
}

/// Wrapper `NSView` housing the info-circle `NSButton` and the popover state.
///
/// Two reasons the button is wrapped instead of exposed directly:
///
/// 1. **Stable coordinate system for popover anchoring.** When an `NSView`
///    is hosted directly by SwiftUI via `NSViewRepresentable`, SwiftUI sets
///    `isFlipped = true` on the outermost hosted view to match its
///    top-left-origin layout system. `NSPopover.preferredEdge` is
///    geometric, so `.minY` on a flipped view picks the top edge and the
///    popover anchors *above* the button. Anchoring to an inner subview
///    (this view's `button`) keeps it in standard AppKit coordinates so
///    `.minY` correctly means "below."
/// 2. **Tight intrinsic size.** A bare `NSButton` exposed to SwiftUI has no
///    fixed size and is expanded by `HStack` to fill remaining row width,
///    floating the info-circle image into the middle of the row. The
///    explicit 16×16 size below keeps the icon adjacent to the trailing
///    edge of the section or control label.
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
    /// Safe to call repeatedly — used both by the SwiftUI shim
    /// (re-invoked on every `updateNSView`) and by pure-AppKit callers
    /// during view-controller setup.
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

        @objc func buttonClicked(_ sender: NSButton) {
            guard let anchor else { return }
            let vc = InfoPopoverContentViewController(paragraphs: paragraphs)
            presenter.show(content: vc, from: anchor, preferredEdge: .minY)
        }
    }
}
