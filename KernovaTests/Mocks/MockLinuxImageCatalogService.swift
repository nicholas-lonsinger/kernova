import Foundation

@testable import Kernova

/// Canned `LinuxImageCatalogProviding`, so a test needing entries does not
/// depend on what the bundled resource happens to hold.
struct MockLinuxImageCatalogService: LinuxImageCatalogProviding {
    var entries: [LinuxImageCatalogEntry] = [makeLinuxCatalogEntry()]
    var generatedAt: String? = "2026-08-05"
}
