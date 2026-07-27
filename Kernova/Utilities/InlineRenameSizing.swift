import AppKit

/// Sizing for an inline-rename box that hugs its text and grows as you type.
///
/// Shared by the storage-disk rows, the sidebar VM rows, and the Settings name
/// field so all three rename boxes size identically, clamped by each surface's
/// own layout.
enum InlineRenameSizing {
    /// Extra width added beyond the measured box width.
    ///
    /// Kept at zero: ``boxWidth(for:font:)`` measures the bezeled chrome, whose
    /// own right-hand inset houses the caret. Nudge up a couple of points only if
    /// a caret ever clips.
    static let horizontalPadding: CGFloat = 0
    /// Floor so a very short or momentarily empty name still has a usable box.
    static let minWidth: CGFloat = 48

    /// Width of an edit box that snugly fits `text` in `font`, floored at
    /// ``minWidth``.
    @MainActor
    static func boxWidth(for text: String, font: NSFont) -> CGFloat {
        measuringField.font = font
        measuringField.stringValue = text
        let measured = ceil(measuringField.fittingSize.width)
        return max(measured + horizontalPadding, minWidth)
    }

    /// Field carrying the editing field's bezeled chrome, reused to measure text
    /// width. `fittingSize` includes the bezel's internal inset that a bare
    /// string measurement omits.
    @MainActor
    private static let measuringField: NSTextField = {
        let field = NSTextField()
        field.isBezeled = true
        field.isEditable = false
        field.maximumNumberOfLines = 1
        field.cell?.usesSingleLineMode = true
        return field
    }()
}
