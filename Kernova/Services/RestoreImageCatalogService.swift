import Foundation
import os

/// Reads the catalog of macOS restore images bundled with the app.
///
/// The shipped app fetches nothing to build this list: the resource is a
/// generation-time snapshot, so the picker opens instantly and offline. Only the
/// chosen image's bytes come off the network, from Apple.
struct RestoreImageCatalogService: RestoreImageCatalogProviding {
    private static let logger = Logger(
        subsystem: "app.kernova", category: "RestoreImageCatalogService")

    private static let resourceName = "RestoreImageCatalog"
    private static let resourceExtension = "json"

    let entries: [RestoreImageCatalogEntry]
    let generatedAt: String?

    init(bundle: Bundle = .main) {
        guard
            let url = bundle.url(
                forResource: Self.resourceName, withExtension: Self.resourceExtension),
            let data = try? Data(contentsOf: url)
        else {
            Self.logger.fault(
                "Bundled restore image catalog '\(Self.resourceName, privacy: .public).\(Self.resourceExtension, privacy: .public)' is missing or unreadable"
            )
            assertionFailure(
                "Bundled restore image catalog is missing or unreadable: \(Self.resourceName).\(Self.resourceExtension)"
            )
            self.entries = []
            self.generatedAt = nil
            return
        }

        let result = Self.parse(data)
        for rejection in result.rejections {
            Self.logger.fault(
                "Dropping restore image catalog entry: \(rejection.description, privacy: .public)")
            assertionFailure("Dropping restore image catalog entry: \(rejection.description)")
        }
        self.entries = result.catalog?.images ?? []
        self.generatedAt = result.catalog?.generatedAt
    }

    // MARK: - Parsing

    /// Why one entry, or the whole document, did not survive parsing.
    enum Rejection: Equatable, CustomStringConvertible {
        case undecodableDocument
        case undecodableEntry(index: Int)
        case insecureURL(build: String, url: URL)
        case foreignHost(build: String, url: URL)
        case unparseableVersion(build: String, version: String)
        case duplicateBuild(build: String)

        var description: String {
            switch self {
            case .undecodableDocument:
                "the document did not decode"
            case .undecodableEntry(let index):
                "entry at index \(index) did not decode"
            case .insecureURL(let build, let url):
                "\(build) has a non-HTTPS URL (\(url))"
            case .foreignHost(let build, let url):
                "\(build) is hosted off Apple (\(url))"
            case .unparseableVersion(let build, let version):
                "\(build) has a non-numeric version ('\(version)')"
            case .duplicateBuild(let build):
                "\(build) appears more than once"
            }
        }
    }

    struct ParseResult: Equatable {
        /// `nil` only when the document itself failed to decode.
        var catalog: RestoreImageCatalog?
        var rejections: [Rejection]
    }

    /// Decodes and validates catalog JSON, dropping unusable entries rather than
    /// failing the whole document.
    ///
    /// Pure and non-asserting so the drop paths are testable; ``init(bundle:)``
    /// is what turns a rejection into a fault, because a rejection in the
    /// *shipped* resource is a build-time mistake.
    static func parse(_ data: Data) -> ParseResult {
        guard let document = try? JSONDecoder().decode(LenientCatalog.self, from: data) else {
            return ParseResult(catalog: nil, rejections: [.undecodableDocument])
        }

        var rejections: [Rejection] = document.undecodableIndices.map { .undecodableEntry(index: $0) }
        var kept: [RestoreImageCatalogEntry] = []
        var seenBuilds: Set<String> = []

        for entry in document.decodedImages {
            guard entry.url.scheme?.lowercased() == "https" else {
                rejections.append(.insecureURL(build: entry.build, url: entry.url))
                continue
            }
            guard let host = entry.url.host(), isAppleHost(host) else {
                rejections.append(.foreignHost(build: entry.build, url: entry.url))
                continue
            }
            guard entry.versionComponents != nil else {
                rejections.append(
                    .unparseableVersion(build: entry.build, version: entry.version))
                continue
            }
            guard seenBuilds.insert(entry.build).inserted else {
                rejections.append(.duplicateBuild(build: entry.build))
                continue
            }
            kept.append(entry)
        }

        let catalog = RestoreImageCatalog(
            device: document.device,
            generatedAt: document.generatedAt,
            images: kept.sorted(by: RestoreImageCatalogEntry.isDescending)
        )
        return ParseResult(catalog: catalog, rejections: rejections)
    }

    /// Whether a URL host belongs to Apple.
    ///
    /// Both domains are matched on a leading dot so a lookalike registered
    /// elsewhere cannot pass. Restore images are served from
    /// `updates.cdn-apple.com`, which is *not* a subdomain of `apple.com` —
    /// the separator before `apple.com` there is a hyphen.
    static func isAppleHost(_ host: String) -> Bool {
        let lowered = host.lowercased()
        for domain in ["apple.com", "cdn-apple.com"]
        where
            lowered == domain || lowered.hasSuffix("." + domain)
        {
            return true
        }
        return false
    }

    /// Catalog document whose `images` array tolerates a bad element.
    ///
    /// Each element decodes through a wrapper that never throws, so one
    /// malformed entry costs that entry rather than the document.
    private struct LenientCatalog: Decodable {
        let device: String
        let generatedAt: String
        let decodedImages: [RestoreImageCatalogEntry]
        let undecodableIndices: [Int]

        private enum CodingKeys: String, CodingKey {
            case device, generatedAt, images
        }

        private struct LenientEntry: Decodable {
            let entry: RestoreImageCatalogEntry?

            init(from decoder: any Decoder) throws {
                entry = try? RestoreImageCatalogEntry(from: decoder)
            }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            device = try container.decode(String.self, forKey: .device)
            generatedAt = try container.decode(String.self, forKey: .generatedAt)
            let lenient = try container.decode([LenientEntry].self, forKey: .images)
            decodedImages = lenient.compactMap(\.entry)
            undecodableIndices = lenient.enumerated().compactMap { $0.element.entry == nil ? $0.offset : nil }
        }
    }
}
