import Foundation

/// One Linux installer image in the bundled catalog.
///
/// Identity is ``id``, a hand-assigned slug, because nothing else about the
/// image is stable: a point release renames the ISO in place, so the entry
/// names the directory the images live in plus a glob and a checksum manifest,
/// and the exact file is resolved at download time.
package struct LinuxImageCatalogEntry: Codable, Sendable, Identifiable, Equatable {
    /// Stable slug, unique across the catalog (`"ubuntu-desktop-26.04"`).
    package var id: String
    /// Distribution and edition as shown to the user (`"Ubuntu Desktop"`).
    package var distribution: String
    /// Version as shown to the user (`"26.04 LTS"`), not necessarily numeric.
    package var version: String
    /// Directory the ISO is fetched from, written with a trailing slash.
    ///
    /// Pointed at whichever address the distribution publishes for downloads,
    /// redirector included: the digest ``checksumManifest`` states is what binds
    /// the bytes, so the ISO can come off any mirror in the network.
    package var directoryURL: URL
    /// Glob matching the ISO's filename inside ``directoryURL``, anchored at
    /// both ends, where each `*` matches a run of characters within the one
    /// filename (`"ubuntu-26.04*-desktop-arm64.iso"`).
    package var isoPattern: String
    /// Directory the checksum manifest is fetched from, present only where the
    /// distribution serves it somewhere other than ``directoryURL``.
    ///
    /// Nothing binds the manifest the way the manifest binds the ISO, so
    /// whichever host answers for it is the trust anchor. This names a host the
    /// distribution runs itself, and ``LinuxImageResolveService`` refuses a
    /// redirect that would leave it.
    var manifestDirectoryURL: URL?
    /// Filename of the checksum manifest inside ``manifestDirectory``.
    var checksumManifest: String
    /// Size of the ISO the catalog was generated against, for the picker's size
    /// column.
    ///
    /// The file resolved at download time is a near neighbour of it, never the
    /// same byte count twice.
    package var approxSizeBytes: UInt64

    /// Directory ``checksumManifest`` is read from.
    var manifestDirectory: URL { manifestDirectoryURL ?? directoryURL }

    /// Where ``checksumManifest`` is read from.
    var manifestURL: URL { manifestDirectory.appendingPathComponent(checksumManifest) }

    /// What the resolved image's digest comes from.
    package var digestSource: DigestSource { .checksumList(manifestURL) }

    // MARK: - Admission

    /// Why an entry may not name a host to contact or a file to read.
    enum AdmissionError: LocalizedError, Equatable {
        /// ``directoryURL`` or ``manifestDirectory`` is not an HTTPS URL.
        case insecureDirectory(url: URL)
        /// ``isoPattern`` is not a wildcard `.iso` filename.
        case invalidISOPattern(pattern: String)
        /// ``checksumManifest`` does not name a file in its directory.
        case invalidManifestName(manifest: String)

        var errorDescription: String? {
            switch self {
            case .insecureDirectory(let url):
                "The saved image source isn't an HTTPS address ('\(url.absoluteString)')."
            case .invalidISOPattern(let pattern):
                "The saved image source doesn't name an ISO to look for ('\(pattern)')."
            case .invalidManifestName(let manifest):
                "The saved image source doesn't name a checksum list to read ('\(manifest)')."
            }
        }
    }

    /// Throws when the entry may not be used, before it names a host to contact
    /// or a file to read.
    ///
    /// The bundled catalog admits each entry as it loads, and the resolver
    /// admits it again because the entry it receives comes off a `config.json`
    /// a user can edit.
    ///
    /// There is no host allowlist to check the way the macOS catalog checks for
    /// Apple: an ISO is fetched from whatever address a distribution publishes
    /// for downloads, mirror network included, and a list of those written here
    /// would go stale without anything noticing. What the entry pins instead is
    /// the host its *manifest* is read from — see ``manifestDirectoryURL``.
    func admit() throws(AdmissionError) {
        guard directoryURL.scheme?.lowercased() == "https" else {
            throw .insecureDirectory(url: directoryURL)
        }
        guard manifestDirectory.scheme?.lowercased() == "https" else {
            throw .insecureDirectory(url: manifestDirectory)
        }
        guard Self.isFilenameGlob(isoPattern) else {
            throw .invalidISOPattern(pattern: isoPattern)
        }
        guard Self.isFilename(checksumManifest) else {
            throw .invalidManifestName(manifest: checksumManifest)
        }
    }

    /// Whether a string names one file inside the entry's directory.
    private static func isFilename(_ candidate: String) -> Bool {
        !candidate.isEmpty && !candidate.contains("/")
    }

    /// Whether a string is a usable ISO glob: a filename, carrying at least one
    /// `*` to absorb the version, and ending in the extension the resolved file
    /// must have.
    private static func isFilenameGlob(_ candidate: String) -> Bool {
        isFilename(candidate) && candidate.contains("*") && candidate.hasSuffix(".iso")
    }

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
    package static func isOrderedBefore(_ lhs: Self, _ rhs: Self) -> Bool {
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
    package func matches(searchTerm: String) -> Bool {
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
