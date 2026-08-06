import Foundation

/// One Linux installer image in the bundled catalog.
///
/// Identity is ``id``, a hand-assigned slug, because nothing else about the
/// image is stable: a point release renames the ISO in place, so the entry
/// names the directory the images live in plus a glob and a checksum manifest,
/// and the exact file is resolved at download time.
struct LinuxImageCatalogEntry: Codable, Sendable, Identifiable, Equatable {
    /// Stable slug, unique across the catalog (`"ubuntu-desktop-26.04"`).
    var id: String
    /// Distribution and edition as shown to the user (`"Ubuntu Desktop"`).
    var distribution: String
    /// Version as shown to the user (`"26.04 LTS"`), not necessarily numeric.
    var version: String
    /// Directory holding both the ISO and ``checksumManifest``, written with a
    /// trailing slash.
    var directoryURL: URL
    /// Glob matching the ISO's filename inside ``directoryURL``, anchored at
    /// both ends, where each `*` matches a run of characters within the one
    /// filename (`"ubuntu-26.04*-desktop-arm64.iso"`).
    var isoPattern: String
    /// Filename of the checksum manifest inside ``directoryURL``.
    var checksumManifest: String
    /// Size of the ISO the catalog was generated against, for the picker's size
    /// column.
    ///
    /// The file resolved at download time is a near neighbour of it, never the
    /// same byte count twice.
    var approxSizeBytes: UInt64

    /// The order distributions are offered in, which is neither alphabetical
    /// nor derivable from the entries.
    static let distributionOrder = [
        "Ubuntu Desktop", "Ubuntu Server", "Debian", "Fedora Workstation", "Kali Linux",
    ]

    /// Position of ``distribution`` in ``distributionOrder``; one not listed
    /// sorts after every one that is.
    var distributionRank: Int {
        Self.distributionOrder.firstIndex(of: distribution) ?? Self.distributionOrder.count
    }

    /// The leading numeric run of ``version``, split into components, so that
    /// `"26.04 LTS"` reads as `[26, 4]`.
    ///
    /// A component that is not a number ends the run, so a version carrying no
    /// number at all is `[]` and sorts below every numbered sibling.
    var versionComponents: [Int] {
        var components: [Int] = []
        for part in version.split(separator: ".") {
            guard let number = Int(part.prefix(while: \.isNumber)) else { break }
            components.append(number)
        }
        return components
    }

    /// Catalog display order: distributions in ``distributionOrder``, newest
    /// version first within each.
    ///
    /// Equal versions fall back to `id` so the order is total.
    static func isOrderedBefore(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.distributionRank != rhs.distributionRank {
            return lhs.distributionRank < rhs.distributionRank
        }
        if lhs.distribution != rhs.distribution { return lhs.distribution < rhs.distribution }
        let left = lhs.versionComponents
        let right = rhs.versionComponents
        for (leftPart, rightPart) in zip(left, right) where leftPart != rightPart {
            return leftPart > rightPart
        }
        if left.count != right.count { return left.count > right.count }
        return lhs.id < rhs.id
    }

    /// Whether the entry matches a picker search term, over distribution and
    /// version.
    func matches(searchTerm: String) -> Bool {
        let term = searchTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return true }
        return distribution.localizedCaseInsensitiveContains(term)
            || version.localizedCaseInsensitiveContains(term)
    }
}

/// The bundled catalog document.
struct LinuxImageCatalog: Codable, Sendable, Equatable {
    /// `yyyy-MM-dd` the catalog was generated, shown in the picker footer.
    var generatedAt: String
    var images: [LinuxImageCatalogEntry]
}
