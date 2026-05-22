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

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        button.target = context.coordinator
        button.action = #selector(Coordinator.buttonClicked(_:))
        configure(button: button)
        context.coordinator.paragraphs = paragraphs
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.paragraphs = paragraphs
        configure(button: button)
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
