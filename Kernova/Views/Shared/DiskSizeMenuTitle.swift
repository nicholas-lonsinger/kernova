import AppKit

/// Builds a disk-size menu-item title with the number right-aligned and the
/// unit left-aligned to shared tab stops, so the number/unit columns line up
/// (and sit centered as a block) down the menu — using generic AppKit tab
/// stops, no custom menu-item view.
///
/// Shared by the creation wizard's disk-size popup and the "Create New Disk" /
/// "Create New Removable Disk" popover so both render identically.
func diskSizeMenuItemTitle(_ sizeInGB: Int) -> NSAttributedString {
    let formatted = DataFormatters.formatDiskSize(sizeInGB)
        .replacingOccurrences(of: "\u{2007}", with: " ")
    let parts = formatted.split(separator: " ").filter { !$0.isEmpty }
    guard parts.count == 2 else { return NSAttributedString(string: formatted) }

    let style = NSMutableParagraphStyle()
    style.tabStops = [
        NSTextTab(textAlignment: .right, location: 30),
        NSTextTab(textAlignment: .left, location: 38),
    ]
    return NSAttributedString(
        string: "\t\(parts[0])\t\(parts[1])", attributes: [.paragraphStyle: style])
}
