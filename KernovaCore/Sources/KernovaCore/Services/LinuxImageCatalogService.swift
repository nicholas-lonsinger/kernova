import Foundation
import KernovaLogging

/// Reads the catalog of Linux installer images bundled with the app.
///
/// The shipped app fetches nothing to build this list: the resource is a
/// generation-time snapshot, so the picker opens instantly and offline. Only
/// the chosen distribution's checksum manifest and ISO come off the network,
/// from the distribution's own mirror.
package struct LinuxImageCatalogService {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "LinuxImageCatalogService")

    private static let resourceName = "LinuxImageCatalog"
    private static let resourceExtension = "json"

    /// Every usable image, in catalog display order.
    ///
    /// Empty when the catalog resource is missing or unreadable — the wizard
    /// then offers no distributions, and the bring-your-own-ISO source still
    /// works.
    package let entries: [LinuxImageCatalogEntry]
    /// `yyyy-MM-dd` the catalog was generated, or `nil` when it did not load.
    package let generatedAt: String?

    init() {
        guard
            let url = Bundle.module.url(
                forResource: Self.resourceName, withExtension: Self.resourceExtension),
            let data = try? Data(contentsOf: url)
        else {
            Self.logger.log(
                .fault,
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
            Self.logger.log(
                .fault,
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
        case inadmissible(id: String, LinuxImageCatalogEntry.AdmissionError)
        case duplicateID(id: String)

        var description: String {
            switch self {
            case .undecodableDocument:
                "the document did not decode"
            case .undecodableEntry(let index):
                "entry at index \(index) did not decode"
            case .inadmissible(let id, .insecureDirectory(let url)):
                "\(id) has a non-HTTPS URL (\(url))"
            case .inadmissible(let id, .invalidISOPattern(let pattern)):
                "\(id) has an ISO pattern that is not a wildcard .iso filename ('\(pattern)')"
            case .inadmissible(let id, .invalidManifestName(let manifest)):
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
    /// Pure and non-asserting so the drop paths are testable; ``init()``
    /// is what turns a rejection into a fault, because a rejection in the
    /// *shipped* resource is a build-time mistake.
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
            do throws(LinuxImageCatalogEntry.AdmissionError) {
                try entry.admit()
            } catch {
                rejections.append(.inadmissible(id: entry.id, error))
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
