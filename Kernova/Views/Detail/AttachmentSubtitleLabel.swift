import AppKit

/// AppKit counterpart of the SwiftUI `attachmentSubtitle` helper.
///
/// Produces a single-line, middle-truncating `NSTextField` styled as a
/// caption. When `isMissing` is `true` the field is colored red and
/// prefixed with a bold "Missing — " so the broken state is obvious
/// without relying on a hover tooltip. Otherwise the field renders the
/// path in secondary label color.
///
/// Used by the AppKit Boot Order sheet
/// (``StorageDiskReorderSheetContentViewController``) so its rows match
/// the SwiftUI `attachmentSubtitle` rendering used by
/// `VMSettingsView`.
///
/// - Parameters:
///   - path: Absolute file path of the backing attachment.
///   - isMissing: `true` when the path no longer resolves to a file
///     on disk.
/// - Returns: A configured `NSTextField` ready to add to a stack view.
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
    return field
}

extension NSFont {
    /// Returns a font with the given weight, preserving the descriptor's
    /// other traits (point size, design, slant).
    ///
    /// Used by ``makeAttachmentSubtitleLabel(path:isMissing:)`` to bold
    /// the "Missing — " prefix without losing the caption font's design.
    fileprivate func withWeight(_ weight: NSFont.Weight) -> NSFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.weight: weight]
        ])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
