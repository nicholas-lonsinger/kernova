import Foundation
import Testing

@testable import Kernova

@Suite("RestoreImageCatalogEntry Tests")
struct RestoreImageCatalogEntryTests {
    private func host(_ major: Int, _ minor: Int, _ patch: Int) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
    }

    @Test("Identity is the build, so two spins of one version stay distinct")
    func buildIsIdentity() {
        // Apple shipped macOS 15.4 as both of these.
        let first = makeCatalogEntry(version: "15.4", build: "24E246")
        let second = makeCatalogEntry(version: "15.4", build: "24E248")
        #expect(first.id == "24E246")
        #expect(second.id == "24E248")
        #expect(first != second)
        #expect(Set([first.id, second.id]).count == 2)
    }

    @Test("suggestedFilename is Apple's own filename")
    func suggestedFilenameFromURL() {
        let entry = makeCatalogEntry(version: "15.6.1", build: "24G90")
        #expect(entry.suggestedFilename == "UniversalMac_15.6.1_24G90_Restore.ipsw")
    }

    @Test("A URL whose filename would escape Downloads yields a generated one")
    func suggestedFilenameRefusesTraversal() {
        let entry = makeCatalogEntry(
            urlString: "https://updates.cdn-apple.com/x/a%2F..%2F..%2Fevil.ipsw")
        #expect(!entry.suggestedFilename.contains("/"))
        #expect(entry.suggestedFilename.hasSuffix(".ipsw"))
    }

    @Test("A guest equal to the host is supported; one below is, one above is not")
    func hostSupportBoundary() {
        let entry = makeCatalogEntry(version: "15.6.1", build: "24G90")
        #expect(entry.isSupported(onHost: host(15, 6, 1)))
        #expect(entry.isSupported(onHost: host(15, 6, 2)))
        #expect(entry.isSupported(onHost: host(26, 0, 0)))
        #expect(!entry.isSupported(onHost: host(15, 6, 0)))
        #expect(!entry.isSupported(onHost: host(15, 5, 9)))
        #expect(!entry.isSupported(onHost: host(14, 9, 9)))
    }

    @Test("A two-component version compares as though padded with zeroes")
    func hostSupportPadsMissingComponents() {
        let entry = makeCatalogEntry(version: "26.6", build: "25G72")
        #expect(entry.isSupported(onHost: host(26, 6, 0)))
        #expect(entry.isSupported(onHost: host(26, 6, 1)))
        #expect(!entry.isSupported(onHost: host(26, 5, 9)))
    }

    @Test("A non-numeric version has no components and cannot be host-checked")
    func unparseableVersion() {
        let entry = makeCatalogEntry(version: "Sequoia", build: "24G90")
        #expect(entry.versionComponents == nil)
        #expect(!entry.isSupported(onHost: host(26, 0, 0)))
    }

    @Test("Sorting is newest first and numeric per component")
    func sortsNumericallyDescending() {
        let entries = [
            makeCatalogEntry(version: "26.9", build: "B"),
            makeCatalogEntry(version: "12.0.1", build: "D"),
            makeCatalogEntry(version: "26.10", build: "A"),
            makeCatalogEntry(version: "15.6.1", build: "C"),
        ]
        let sorted = entries.sorted(by: RestoreImageCatalogEntry.isDescending)
        // 26.10 above 26.9 — a lexicographic sort would invert these.
        #expect(sorted.map(\.build) == ["A", "B", "C", "D"])
    }

    @Test("Equal versions sort by build so the order is total")
    func sortIsTotalForEqualVersions() {
        let first = makeCatalogEntry(version: "15.4", build: "24E248")
        let second = makeCatalogEntry(version: "15.4", build: "24E246")
        let sorted = [second, first].sorted(by: RestoreImageCatalogEntry.isDescending)
        #expect(sorted.map(\.build) == ["24E248", "24E246"])
    }

    @Test("Search matches version and build, case-insensitively")
    func searchMatchesVersionAndBuild() {
        let entry = makeCatalogEntry(version: "15.6.1", build: "24G90")
        #expect(entry.matches(searchTerm: "15.6"))
        #expect(entry.matches(searchTerm: "24g90"))
        #expect(entry.matches(searchTerm: "  "))
        #expect(entry.matches(searchTerm: ""))
        #expect(!entry.matches(searchTerm: "14.0"))
        #expect(!entry.matches(searchTerm: "23A344"))
    }

    @Test("releaseDate parses Apple's RFC 1123 Last-Modified header")
    func releaseDateParses() throws {
        let entry = makeCatalogEntry(lastModified: "Fri, 24 Jul 2026 02:16:52 GMT")
        let date = try #require(entry.releaseDate)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        #expect(parts.year == 2026)
        #expect(parts.month == 7)
        #expect(parts.day == 24)
    }

    @Test("An unparseable Last-Modified yields no date rather than a wrong one")
    func releaseDateRejectsGarbage() {
        #expect(makeCatalogEntry(lastModified: "not a date").releaseDate == nil)
    }
}

@Suite("RestoreImageCatalogService Tests")
struct RestoreImageCatalogServiceTests {
    private func json(images: String) -> Data {
        Data(
            """
            {
              "device": "VirtualMac2,1",
              "generatedAt": "2026-07-28",
              "imageCount": 1,
              "images": [\(images)]
            }
            """.utf8)
    }

    private let goodEntry = """
        {
          "build": "24G90",
          "version": "15.6.1",
          "url": "https://updates.cdn-apple.com/x/UniversalMac_15.6.1_24G90_Restore.ipsw",
          "sizeBytes": 16808427372,
          "lastModified": "Mon, 18 Aug 2025 12:00:00 GMT",
          "source": "apple-live"
        }
        """

    @Test("A well-formed catalog decodes with no rejections")
    func decodesCleanCatalog() throws {
        let result = RestoreImageCatalogService.parse(json(images: goodEntry))
        let catalog = try #require(result.catalog)
        #expect(result.rejections.isEmpty)
        #expect(catalog.generatedAt == "2026-07-28")
        #expect(catalog.images.map(\.build) == ["24G90"])
    }

    @Test("A malformed entry is dropped rather than failing the whole decode")
    func dropsMalformedEntry() throws {
        let malformed = """
            { "build": "BAD" }
            """
        let result = RestoreImageCatalogService.parse(
            json(images: "\(malformed), \(goodEntry)"))
        let catalog = try #require(result.catalog)
        #expect(catalog.images.map(\.build) == ["24G90"])
        #expect(result.rejections == [.undecodableEntry(index: 0)])
    }

    @Test("An undecodable document yields no catalog")
    func rejectsUndecodableDocument() {
        let result = RestoreImageCatalogService.parse(Data("not json".utf8))
        #expect(result.catalog == nil)
        #expect(result.rejections == [.undecodableDocument])
    }

    @Test("A non-HTTPS URL is rejected")
    func rejectsInsecureURL() throws {
        let insecure = goodEntry.replacingOccurrences(of: "https://", with: "http://")
        let result = RestoreImageCatalogService.parse(json(images: insecure))
        let catalog = try #require(result.catalog)
        #expect(catalog.images.isEmpty)
        #expect(result.rejections.count == 1)
        if case .insecureURL(let build, _) = result.rejections[0] {
            #expect(build == "24G90")
        } else {
            Issue.record("Expected an insecureURL rejection, got \(result.rejections[0])")
        }
    }

    @Test("A non-Apple host is rejected")
    func rejectsForeignHost() throws {
        let foreign = goodEntry.replacingOccurrences(
            of: "updates.cdn-apple.com", with: "mirrors.example.com")
        let result = RestoreImageCatalogService.parse(json(images: foreign))
        let catalog = try #require(result.catalog)
        #expect(catalog.images.isEmpty)
        #expect(result.rejections.count == 1)
        if case .foreignHost(let build, _) = result.rejections[0] {
            #expect(build == "24G90")
        } else {
            Issue.record("Expected a foreignHost rejection, got \(result.rejections[0])")
        }
    }

    @Test("A non-numeric version is rejected")
    func rejectsUnparseableVersion() throws {
        let bad = goodEntry.replacingOccurrences(of: "\"15.6.1\"", with: "\"Sequoia\"")
        let result = RestoreImageCatalogService.parse(json(images: bad))
        let catalog = try #require(result.catalog)
        #expect(catalog.images.isEmpty)
        #expect(result.rejections == [.unparseableVersion(build: "24G90", version: "Sequoia")])
    }

    @Test("A repeated build is kept once")
    func rejectsDuplicateBuild() throws {
        let result = RestoreImageCatalogService.parse(json(images: "\(goodEntry), \(goodEntry)"))
        let catalog = try #require(result.catalog)
        #expect(catalog.images.count == 1)
        #expect(result.rejections == [.duplicateBuild(build: "24G90")])
    }

    @Test("Parsed entries come back newest first regardless of input order")
    func sortsParsedEntries() throws {
        let older =
            goodEntry
            .replacingOccurrences(of: "\"15.6.1\"", with: "\"12.0.1\"")
            .replacingOccurrences(of: "\"24G90\"", with: "\"21A559\"")
        let result = RestoreImageCatalogService.parse(json(images: "\(older), \(goodEntry)"))
        let catalog = try #require(result.catalog)
        #expect(catalog.images.map(\.build) == ["24G90", "21A559"])
    }

    @Test("Apple hosts are matched on a dot boundary, hyphenated CDN included")
    func appleHostMatching() {
        #expect(RestoreImageCatalogService.isAppleHost("apple.com"))
        #expect(RestoreImageCatalogService.isAppleHost("swcdn.apple.com"))
        #expect(RestoreImageCatalogService.isAppleHost("UPDATES.CDN-APPLE.COM"))
        // `updates.cdn-apple.com` is not a subdomain of `apple.com`.
        #expect(RestoreImageCatalogService.isAppleHost("updates.cdn-apple.com"))
        #expect(!RestoreImageCatalogService.isAppleHost("notapple.com"))
        #expect(!RestoreImageCatalogService.isAppleHost("apple.com.example.net"))
        #expect(!RestoreImageCatalogService.isAppleHost("evilcdn-apple.com"))
    }

    @Test("The catalog shipped in the app bundle parses clean")
    func bundledCatalogIsValid() throws {
        let service = RestoreImageCatalogService()
        #expect(!service.entries.isEmpty)
        #expect(service.generatedAt != nil)

        // Every shipped invariant the parser enforces, asserted against the real
        // resource rather than a fixture. Counts are deliberately absent: the
        // catalog is regenerated on Apple's schedule.
        #expect(Set(service.entries.map(\.build)).count == service.entries.count)
        for entry in service.entries {
            #expect(entry.url.scheme == "https")
            #expect(entry.suggestedFilename.hasSuffix(".ipsw"))
            #expect(entry.versionComponents != nil)
        }
        let sorted = service.entries.sorted(by: RestoreImageCatalogEntry.isDescending)
        #expect(sorted.map(\.build) == service.entries.map(\.build))
    }
}
