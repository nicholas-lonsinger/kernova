import Foundation
import os

/// Reads the catalog of Linux installer images bundled with the app.
///
/// The shipped app fetches nothing to build this list: the resource is a
/// generation-time snapshot, so the picker opens instantly and offline. Only
/// the chosen distribution's checksum manifest and ISO come off the network,
/// from the distribution's own mirror.
struct LinuxImageCatalogService: LinuxImageCatalogProviding {
    private static let logger = Logger(
        subsystem: "app.kernova", category: "LinuxImageCatalogService")

    private static let resourceName = "LinuxImageCatalog"
    private static let resourceExtension = "json"

    let entries: [LinuxImageCatalogEntry]
    let generatedAt: String?

    init(bundle: Bundle = .main) {
        guard
            let url = bundle.url(
                forResource: Self.resourceName, withExtension: Self.resourceExtension),
            let data = try? Data(contentsOf: url)
        else {
            Self.logger.fault(
                "Bundled Linux image catalog '\(Self.resourceName, privacy: .public).\(Self.resourceExtension, privacy: .public)' is missing or unreadable"
            )
            assertionFailure(
                "Bundled Linux image catalog is missing or unreadable: \(Self.resourceName).\(Self.resourceExtension)"
            )
            self.entries = []
            self.generatedAt = nil
            return
        }

        let result = Self.parse(data)
        for rejection in result.rejections {
            Self.logger.fault(
                "Dropping Linux image catalog entry: \(rejection.description, privacy: .public)")
            assertionFailure("Dropping Linux image catalog entry: \(rejection.description)")
        }
        self.entries = result.catalog?.images ?? []
        self.generatedAt = result.catalog?.generatedAt
    }

    // MARK: - Parsing

    /// Why one entry, or the whole document, did not survive parsing.
    enum Rejection: Equatable, CustomStringConvertible {
        case undecodableDocument
        case undecodableEntry(index: Int)
        case insecureURL(id: String, url: URL)
        case invalidPattern(id: String, pattern: String)
        case invalidManifestName(id: String, manifest: String)
        case duplicateID(id: String)

        var description: String {
            switch self {
            case .undecodableDocument:
                "the document did not decode"
            case .undecodableEntry(let index):
                "entry at index \(index) did not decode"
            case .insecureURL(let id, let url):
                "\(id) has a non-HTTPS directory URL (\(url))"
            case .invalidPattern(let id, let pattern):
                "\(id) has an ISO pattern that is not a wildcard .iso filename ('\(pattern)')"
            case .invalidManifestName(let id, let manifest):
                "\(id) has a checksum manifest that is not a filename ('\(manifest)')"
            case .duplicateID(let id):
                "\(id) appears more than once"
            }
        }
    }

    struct ParseResult: Equatable {
        /// `nil` only when the document itself failed to decode.
        var catalog: LinuxImageCatalog?
        var rejections: [Rejection]
    }

    /// Decodes and validates catalog JSON, dropping unusable entries rather
    /// than failing the whole document.
    ///
    /// Pure and non-asserting so the drop paths are testable; ``init(bundle:)``
    /// is what turns a rejection into a fault, because a rejection in the
    /// *shipped* resource is a build-time mistake.
    ///
    /// There is no host allowlist to check the way the macOS catalog checks for
    /// Apple: an ISO is fetched from whatever address a distribution publishes
    /// for downloads, mirror network included, and a list of those written here
    /// would go stale without anything noticing. What the entry pins instead is
    /// the host its *manifest* is read from — see
    /// ``LinuxImageCatalogEntry/manifestDirectoryURL``.
    static func parse(_ data: Data) -> ParseResult {
        guard let document = try? JSONDecoder().decode(LenientCatalog.self, from: data) else {
            return ParseResult(catalog: nil, rejections: [.undecodableDocument])
        }

        var rejections: [Rejection] = document.undecodableIndices.map {
            .undecodableEntry(index: $0)
        }
        var kept: [LinuxImageCatalogEntry] = []
        var seenIDs: Set<String> = []

        for entry in document.decodedImages {
            guard entry.directoryURL.scheme?.lowercased() == "https" else {
                rejections.append(.insecureURL(id: entry.id, url: entry.directoryURL))
                continue
            }
            guard entry.manifestDirectory.scheme?.lowercased() == "https" else {
                rejections.append(.insecureURL(id: entry.id, url: entry.manifestDirectory))
                continue
            }
            guard isFilenameGlob(entry.isoPattern) else {
                rejections.append(.invalidPattern(id: entry.id, pattern: entry.isoPattern))
                continue
            }
            guard isFilename(entry.checksumManifest) else {
                rejections.append(
                    .invalidManifestName(id: entry.id, manifest: entry.checksumManifest))
                continue
            }
            guard seenIDs.insert(entry.id).inserted else {
                rejections.append(.duplicateID(id: entry.id))
                continue
            }
            kept.append(entry)
        }

        let catalog = LinuxImageCatalog(
            generatedAt: document.generatedAt,
            images: kept.sorted(by: LinuxImageCatalogEntry.isOrderedBefore)
        )
        return ParseResult(catalog: catalog, rejections: rejections)
    }

    /// Whether a string names one file inside the entry's directory.
    static func isFilename(_ candidate: String) -> Bool {
        !candidate.isEmpty && !candidate.contains("/")
    }

    /// Whether a string is a usable ISO glob: a filename, carrying at least one
    /// `*` to absorb the version, and ending in the extension the resolved file
    /// must have.
    static func isFilenameGlob(_ candidate: String) -> Bool {
        isFilename(candidate) && candidate.contains("*") && candidate.hasSuffix(".iso")
    }

    /// Catalog document whose `images` array tolerates a bad element.
    ///
    /// Each element decodes through a wrapper that never throws, so one
    /// malformed entry costs that entry rather than the document.
    private struct LenientCatalog: Decodable {
        let generatedAt: String
        let decodedImages: [LinuxImageCatalogEntry]
        let undecodableIndices: [Int]

        private enum CodingKeys: String, CodingKey {
            case generatedAt, images
        }

        private struct LenientEntry: Decodable {
            let entry: LinuxImageCatalogEntry?

            init(from decoder: any Decoder) throws {
                entry = try? LinuxImageCatalogEntry(from: decoder)
            }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            generatedAt = try container.decode(String.self, forKey: .generatedAt)
            let lenient = try container.decode([LenientEntry].self, forKey: .images)
            decodedImages = lenient.compactMap(\.entry)
            undecodableIndices = lenient.enumerated().compactMap {
                $0.element.entry == nil ? $0.offset : nil
            }
        }
    }
}
