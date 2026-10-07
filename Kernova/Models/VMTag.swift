import AppKit

/// A label the user puts on any of the library's VMs — a name and a color —
/// which the sidebar shows as a dot on each row carrying it, and a filter, a
/// grouping and `kernova list --tag` select by.
///
/// The definition lives at library level, in ``VMOrganizationDirectory``; each
/// VM's assignments live in its ``VMHostState/tags``, by ``id``. Its name is
/// unique among tags ignoring case.
struct VMTag: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    var name: String
    var color: VMTagColor
}

/// The colors a tag takes: the system's adaptive palette, which follows the
/// appearance and the accessibility contrast settings.
enum VMTagColor: String, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, blue, purple, gray

    var title: String {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        case .gray: "Gray"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .gray: .systemGray
        }
    }

    /// A filled circle `diameter` points across in this color as `appearance`
    /// resolves it — for a menu item's image, so a menu built as it opens
    /// shows the appearance it opens in.
    ///
    /// Held as bitmaps at 1x and 2x: a menu draws an item image only from
    /// pixels, and a drawing-handler image (`NSCustomImageRep`) has none, so
    /// it showed as nothing in the sidebar's menus while an in-process view
    /// drew it.
    @MainActor
    func dotImage(diameter: CGFloat = 8, appearance: NSAppearance = NSApp.effectiveAppearance) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size)
        appearance.performAsCurrentDrawingAppearance {
            for scale in [1, 2] {
                let pixels = Int(diameter) * scale
                guard
                    let bitmap = NSBitmapImageRep(
                        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                        bytesPerRow: 0, bitsPerPixel: 0)
                else {
                    assertionFailure("A \(pixels)-pixel RGBA bitmap could not be made")
                    continue
                }
                // Sized before the context is made, which scales points to
                // pixels by it.
                bitmap.size = size
                guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                    assertionFailure("A context over an RGBA bitmap could not be made")
                    continue
                }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                nsColor.setFill()
                NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
                NSGraphicsContext.restoreGraphicsState()
                image.addRepresentation(bitmap)
            }
        }
        image.accessibilityDescription = title
        return image
    }
}

extension Sequence<VMTag> {
    /// These tags, in this order, less every one `ids` does not name — the
    /// tags a VM whose ``VMHostState/tags`` is `ids` carries, so an
    /// assignment naming a tag the library no longer defines reads as none.
    func assigned(_ ids: Set<UUID>) -> [VMTag] {
        filter { ids.contains($0.id) }
    }
}
