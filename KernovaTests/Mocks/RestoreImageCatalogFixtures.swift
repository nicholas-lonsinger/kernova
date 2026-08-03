import Foundation

@testable import Kernova

/// Builds a catalog entry, defaulted so a test only names what it cares about.
func makeCatalogEntry(
    version: String = "15.6.1",
    build: String = "24G90",
    urlString: String? = nil,
    sizeBytes: UInt64 = 16_808_427_372,
    lastModified: String = "Mon, 18 Aug 2025 12:00:00 GMT",
    source: String = "apple-live"
) -> RestoreImageCatalogEntry {
    let resolved =
        urlString
        ?? "https://updates.cdn-apple.com/fullrestores/UniversalMac_\(version)_\(build)_Restore.ipsw"
    return RestoreImageCatalogEntry(
        version: version,
        build: build,
        url: URL(string: resolved) ?? URL(fileURLWithPath: "/"),
        sizeBytes: sizeBytes,
        lastModified: lastModified,
        source: source
    )
}
