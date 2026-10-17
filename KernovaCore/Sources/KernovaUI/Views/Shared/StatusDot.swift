import AppKit

/// A small `circle.fill` colored through `contentTintColor`, hidden from
/// accessibility: the text beside it states what its color shows.
@MainActor
func makeStatusDot() -> NSImageView {
    let dot = NSImageView(image: .systemSymbol("circle.fill", accessibilityDescription: ""))
    dot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
    dot.setContentHuggingPriority(.required, for: .horizontal)
    dot.cell?.setAccessibilityElement(false)
    return dot
}
