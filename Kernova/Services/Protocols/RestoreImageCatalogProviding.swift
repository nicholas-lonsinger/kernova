import Foundation

/// Abstraction for reading the bundled catalog of macOS restore images.
protocol RestoreImageCatalogProviding: Sendable {
    /// Every usable image, newest first.
    ///
    /// Empty when the catalog resource is missing or unreadable — the picker
    /// then has nothing to offer, and the other two IPSW sources still work.
    var entries: [RestoreImageCatalogEntry] { get }

    /// `yyyy-MM-dd` the catalog was generated, or `nil` when it did not load.
    var generatedAt: String? { get }
}
