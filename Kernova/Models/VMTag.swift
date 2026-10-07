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

    /// A filled circle `diameter` points across, drawn in this color as the
    /// appearance it is drawn in resolves it — for a menu item's image.
    @MainActor
    func dotImage(diameter: CGFloat = 8) -> NSImage {
        let color = nsColor
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
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
