import Foundation

/// Abstraction for reading the bundled catalog of Linux installer images.
protocol LinuxImageCatalogProviding: Sendable {
    /// Every usable image, in catalog display order.
    ///
    /// Empty when the catalog resource is missing or unreadable — the wizard
    /// then offers no distributions, and the bring-your-own-ISO source still
    /// works.
    var entries: [LinuxImageCatalogEntry] { get }

    /// `yyyy-MM-dd` the catalog was generated, or `nil` when it did not load.
    var generatedAt: String? { get }
}
