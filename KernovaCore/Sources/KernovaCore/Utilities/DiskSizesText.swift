import Foundation

/// How a disk image's measured figures read on every surface stating them: an
/// attachment row's subtitle, Get Info, and the overview's Storage card.
extension VMBundleLayout.DiskSizes {
    /// What a figure that can't be read states.
    static let unreadableText = "Unknown"

    /// The on-disk footprint, or ``unreadableText``.
    package var usedText: String { Self.text(onDiskBytes) ?? Self.unreadableText }

    /// The virtual capacity, or ``unreadableText``.
    package var allocatedText: String { Self.text(capacityBytes) ?? Self.unreadableText }

    private static func text(_ bytes: UInt64?) -> String? {
        bytes.map { DataFormatters.formatBytes($0) }
    }

    /// The subtitle of an attachment row backed by `image`, a storage disk or a
    /// removable medium, from its `measured` figures — the in-bundle
    /// placeholder or the path where none reads, or none was measured yet.
    package static func subtitle(of image: DiskImageReference, measured: Self?) -> String {
        switch (text(measured?.onDiskBytes), text(measured?.capacityBytes)) {
        case let (.some(used), .some(allocated)):
            "\(used) (used) / \(allocated) (allocated)"
        case let (.some(used), .none):
            "\(used) used"
        case let (.none, .some(allocated)):
            "\(allocated) allocated"
        case (.none, .none):
            image.isInternal ? "In-bundle disk image" : image.path
        }
    }
}
