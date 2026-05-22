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
/// Each call site builds an `InfoButton` per occurrence — its `Coordinator`
/// owns the per-instance ``PopoverPresenter`` and popover state.
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

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> InfoButtonView {
        let view = InfoButtonView()
        view.button.target = context.coordinator
        view.button.action = #selector(Coordinator.buttonClicked(_:))
        context.coordinator.paragraphs = paragraphs
        configure(button: view.button)
        return view
    }

    func updateNSView(_ view: InfoButtonView, context: Context) {
        context.coordinator.paragraphs = paragraphs
        configure(button: view.button)
    }

    /// Sets the info-circle icon (scaled `.small` to match the SwiftUI
    /// predecessor) plus hover tooltip and VoiceOver label.
    private func configure(button: NSButton) {
        let about = "About \(label)"
        let config = NSImage.SymbolConfiguration(scale: .small)
        button.image = NSImage.systemSymbol(
            "info.circle", accessibilityDescription: about
        )
        .withSymbolConfiguration(config)
        button.toolTip = about
        button.setAccessibilityLabel(about)
    }

    /// Owns the per-button ``PopoverPresenter`` and the latest paragraph
    /// snapshot to render when the button is clicked.
    @MainActor
    final class Coordinator {
        let presenter = PopoverPresenter()
        var paragraphs: [InfoPopoverParagraph] = []

        @objc func buttonClicked(_ sender: NSButton) {
            let vc = InfoPopoverContentViewController(paragraphs: paragraphs)
            presenter.show(content: vc, from: sender, preferredEdge: .minY)
        }
    }
}

/// Wrapper `NSView` housing the info-circle `NSButton`.
///
/// Two reasons the button is wrapped instead of exposed directly to SwiftUI:
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

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
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
}
