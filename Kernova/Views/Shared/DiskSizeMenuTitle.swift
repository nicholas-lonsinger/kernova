import AppKit

/// Builds a disk-size menu-item title with the number right-aligned and the
/// unit left-aligned to shared tab stops, so the number/unit columns line up
/// (and sit centered as a block) down the menu — using generic AppKit tab
/// stops, no custom menu-item view. The unit column starts one space past the
/// number column, so each title still reads as "100 GB".
func diskSizeMenuItemTitle(_ sizeInGB: Int) -> NSAttributedString {
    let parts = DataFormatters.diskSizeParts(sizeInGB)
    let numberColumnEnd: CGFloat = 30
    let space = (" " as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width
    let style = NSMutableParagraphStyle()
    style.tabStops = [
        NSTextTab(textAlignment: .right, location: numberColumnEnd),
        NSTextTab(textAlignment: .left, location: numberColumnEnd + space),
    ]
    return NSAttributedString(
        string: "\t\(parts.number)\t\(parts.unit)", attributes: [.paragraphStyle: style])
}
