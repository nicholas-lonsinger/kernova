import AppKit

/// Single-line, middle-truncating caption `NSTextField` for an attachment's
/// path/stats subtitle.
@MainActor
func makeAttachmentSubtitleLabel(path: String, isMissing: Bool) -> NSTextField {
    let field = NSTextField(labelWithString: "")
    field.font = .preferredFont(forTextStyle: .caption1)
    field.lineBreakMode = .byTruncatingMiddle
    field.maximumNumberOfLines = 1
    field.isSelectable = false
    field.translatesAutoresizingMaskIntoConstraints = false
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    applyAttachmentSubtitle(to: field, path: path, isMissing: isMissing)
    return field
}

/// Updates an existing subtitle field's content in place.
///
/// Applies the missing-state red "Missing — " prefix, or the normal secondary
/// path.
@MainActor
func applyAttachmentSubtitle(to field: NSTextField, path: String, isMissing: Bool) {
    if isMissing {
        let attributed = NSMutableAttributedString(
            string: "Missing — ",
            attributes: [
                .font: NSFont.preferredFont(forTextStyle: .caption1)
                    .withWeight(.semibold),
                .foregroundColor: NSColor.systemRed,
            ]
        )
        attributed.append(
            NSAttributedString(
                string: path,
                attributes: [
                    .font: NSFont.preferredFont(forTextStyle: .caption1),
                    .foregroundColor: NSColor.systemRed,
                ]
            )
        )
        field.attributedStringValue = attributed
    } else {
        field.stringValue = path
        field.textColor = .secondaryLabelColor
    }
}

extension NSFont {
    /// Returns a font with the given weight, preserving the descriptor's
    /// other traits (point size, design, slant).
    fileprivate func withWeight(_ weight: NSFont.Weight) -> NSFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.weight: weight]
        ])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
