import AppKit

/// A sheet's headline title, followed by an info button holding `info` when it
/// has paragraphs — the home for background about the sheet as a whole.
///
/// Hugs its content, so a sheet that lays the title out against a trailing
/// spacer or centers it gets the title and button side by side either way. A
/// title wider than the space it is given truncates in the middle.
@MainActor
func makeSheetTitle(_ text: String, info: [InfoPopoverParagraph] = []) -> NSStackView {
    let title = NSTextField(labelWithString: text)
    title.font = .preferredFont(forTextStyle: .headline)
    title.lineBreakMode = .byTruncatingMiddle
    title.isSelectable = false

    var views: [NSView] = [title]
    if !info.isEmpty {
        views.append(makeGroupedFormInfoButton(label: text, paragraphs: info))
    }
    let row = NSStackView(views: views)
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = Spacing.small
    row.setHuggingPriority(.defaultHigh, for: .horizontal)
    return row
}
