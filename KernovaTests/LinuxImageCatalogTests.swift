import Foundation
import Testing

@testable import Kernova

@Suite("LinuxImageCatalogEntry Tests")
struct LinuxImageCatalogEntryTests {
    @Test("Identity is the slug, so two editions of one version stay distinct")
    func slugIsIdentity() {
        let desktop = makeLinuxCatalogEntry(
            id: "ubuntu-desktop-26.04", distribution: "Ubuntu Desktop", version: "26.04 LTS")
        let server = makeLinuxCatalogEntry(
            id: "ubuntu-server-26.04", distribution: "Ubuntu Server", version: "26.04 LTS")
        #expect(desktop.id == "ubuntu-desktop-26.04")
        #expect(desktop != server)
        #expect(Set([desktop.id, server.id]).count == 2)
    }

    @Test("A version's numeric components stop at the first non-numeric part")
    func versionComponentsParse() {
        #expect(makeLinuxCatalogEntry(version: "26.04 LTS").versionComponents == [26, 4])
        #expect(makeLinuxCatalogEntry(version: "2026.2").versionComponents == [2026, 2])
        #expect(makeLinuxCatalogEntry(version: "13").versionComponents == [13])
        #expect(makeLinuxCatalogEntry(version: "rolling").versionComponents == [])
    }

    @Test("Sorting follows the fixed distribution order, then newest version first")
    func sortsByDistributionThenVersion() {
        let entries = [
            makeLinuxCatalogEntry(id: "kali", distribution: "Kali Linux", version: "2026.2"),
            makeLinuxCatalogEntry(id: "debian-12", distribution: "Debian", version: "12"),
            makeLinuxCatalogEntry(
                id: "ubuntu-server-24.04", distribution: "Ubuntu Server", version: "24.04 LTS"),
            makeLinuxCatalogEntry(id: "debian-13", distribution: "Debian", version: "13"),
            makeLinuxCatalogEntry(
                id: "ubuntu-desktop-26.04", distribution: "Ubuntu Desktop", version: "26.04 LTS"),
        ]
        let sorted = entries.sorted(by: LinuxImageCatalogEntry.isOrderedBefore)
        #expect(
            sorted.map(\.id) == [
                "ubuntu-desktop-26.04", "ubuntu-server-24.04", "debian-13", "debian-12", "kali",
            ])
    }

    @Test("Versions compare numerically per component, not lexicographically")
    func sortsVersionsNumerically() {
        let entries = [
            makeLinuxCatalogEntry(id: "b", distribution: "Debian", version: "9"),
            makeLinuxCatalogEntry(id: "a", distribution: "Debian", version: "10"),
            makeLinuxCatalogEntry(id: "c", distribution: "Debian", version: "8.11"),
        ]
        let sorted = entries.sorted(by: LinuxImageCatalogEntry.isOrderedBefore)
        #expect(sorted.map(\.id) == ["a", "b", "c"])
    }

    @Test("A distribution outside the fixed order sorts after every one in it")
    func unlistedDistributionSortsLast() {
        let known = makeLinuxCatalogEntry(id: "kali", distribution: "Kali Linux", version: "2026.2")
        let unknown = makeLinuxCatalogEntry(id: "arch", distribution: "Arch Linux", version: "1")
        let sorted = [unknown, known].sorted(by: LinuxImageCatalogEntry.isOrderedBefore)
        #expect(sorted.map(\.id) == ["kali", "arch"])
    }

    @Test("Equal distribution and version sort by id so the order is total")
    func sortIsTotalForEqualVersions() {
        let first = makeLinuxCatalogEntry(id: "debian-13-a", distribution: "Debian", version: "13")
        let second = makeLinuxCatalogEntry(id: "debian-13-b", distribution: "Debian", version: "13")
        let sorted = [second, first].sorted(by: LinuxImageCatalogEntry.isOrderedBefore)
        #expect(sorted.map(\.id) == ["debian-13-a", "debian-13-b"])
    }

    @Test("Search matches distribution and version, case-insensitively")
    func searchMatchesDistributionAndVersion() {
        let entry = makeLinuxCatalogEntry(
            id: "ubuntu-desktop-26.04", distribution: "Ubuntu Desktop", version: "26.04 LTS")
        #expect(entry.matches(searchTerm: "ubuntu"))
        #expect(entry.matches(searchTerm: "DESKTOP"))
        #expect(entry.matches(searchTerm: "26.04"))
        #expect(entry.matches(searchTerm: "lts"))
        #expect(entry.matches(searchTerm: "  "))
        #expect(entry.matches(searchTerm: ""))
        #expect(!entry.matches(searchTerm: "fedora"))
        #expect(!entry.matches(searchTerm: "24.04"))
    }

    @Test("The ISO glob takes every point release of its version and nothing else")
    func isoGlobMatchesPointReleases() {
        let entry = makeLinuxCatalogEntry(isoPattern: "debian-13.*-arm64-netinst.iso")
        #expect(entry.matchesISOFilename("debian-13.1.0-arm64-netinst.iso"))
        #expect(entry.matchesISOFilename("debian-13.12.0-arm64-netinst.iso"))
        #expect(!entry.matchesISOFilename("debian-12.15.0-arm64-netinst.iso"))
        #expect(!entry.matchesISOFilename("debian-13.1.0-amd64-netinst.iso"))
    }

    @Test("The glob is anchored at both ends, so a longer name is not a match")
    func isoGlobIsAnchored() {
        let entry = makeLinuxCatalogEntry(isoPattern: "ubuntu-26.04*-desktop-arm64.iso")
        #expect(entry.matchesISOFilename("ubuntu-26.04.1-desktop-arm64.iso"))
        // A partial download's bundle sits beside the image under a name this
        // must not take for the image itself.
        #expect(!entry.matchesISOFilename("ubuntu-26.04.1-desktop-arm64.iso.kernovadownload"))
        #expect(!entry.matchesISOFilename("old-ubuntu-26.04.1-desktop-arm64.iso"))
    }

    @Test("A variant the glob doesn't name is excluded")
    func isoGlobExcludesOtherVariants() {
        let entry = makeLinuxCatalogEntry(isoPattern: "ubuntu-26.04*-live-server-arm64.iso")
        #expect(entry.matchesISOFilename("ubuntu-26.04.1-live-server-arm64.iso"))
        #expect(!entry.matchesISOFilename("ubuntu-26.04.1-live-server-arm64+largemem.iso"))
    }
}

@Suite("LinuxImageCatalogService Tests")
struct LinuxImageCatalogServiceTests {
    private func json(images: String) -> Data {
        Data(
            """
            {
              "generatedAt": "2026-08-05",
              "images": [\(images)]
            }
            """.utf8)
    }

    private let goodEntry = """
        {
          "id": "debian-13",
          "distribution": "Debian",
          "version": "13",
          "directoryURL": "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/",
          "isoPattern": "debian-13.*-arm64-netinst.iso",
          "checksumManifest": "SHA256SUMS",
          "approxSizeBytes": 735358976
        }
        """

    @Test("A well-formed catalog decodes with no rejections")
    func decodesCleanCatalog() throws {
        let result = LinuxImageCatalogService.parse(json(images: goodEntry))
        let catalog = try #require(result.catalog)
        #expect(result.rejections.isEmpty)
        #expect(catalog.generatedAt == "2026-08-05")
        #expect(catalog.images.map(\.id) == ["debian-13"])
        #expect(catalog.images.first?.approxSizeBytes == 735_358_976)
    }

    @Test("A malformed entry is dropped rather than failing the whole decode")
    func dropsMalformedEntry() throws {
        let malformed = """
            { "id": "BAD" }
            """
        let result = LinuxImageCatalogService.parse(json(images: "\(malformed), \(goodEntry)"))
        let catalog = try #require(result.catalog)
        #expect(catalog.images.map(\.id) == ["debian-13"])
        #expect(result.rejections == [.undecodableEntry(index: 0)])
    }

    @Test("An undecodable document yields no catalog")
    func rejectsUndecodableDocument() {
        let result = LinuxImageCatalogService.parse(Data("not json".utf8))
        #expect(result.catalog == nil)
        #expect(result.rejections == [.undecodableDocument])
    }

    @Test("A non-HTTPS directory URL is rejected")
    func rejectsInsecureURL() throws {
        let insecure = goodEntry.replacingOccurrences(of: "https://", with: "http://")
        let result = LinuxImageCatalogService.parse(json(images: insecure))
        let catalog = try #require(result.catalog)
        #expect(catalog.images.isEmpty)
        #expect(result.rejections.count == 1)
        if case .insecureURL(let id, _) = result.rejections[0] {
            #expect(id == "debian-13")
        } else {
            Issue.record("Expected an insecureURL rejection, got \(result.rejections[0])")
        }
    }

    @Test("An ISO pattern with no wildcard, no .iso, or a path separator is rejected")
    func rejectsBadPattern() throws {
        let patterns = [
            "debian-13.9.0-arm64-netinst.iso",  // no wildcard: cannot survive a point release
            "debian-13.*-arm64-netinst.img",  // not an ISO
            "iso-cd/debian-13.*-arm64-netinst.iso",  // not a filename
            "",
        ]
        for pattern in patterns {
            let bad = goodEntry.replacingOccurrences(
                of: "\"debian-13.*-arm64-netinst.iso\"", with: "\"\(pattern)\"")
            let result = LinuxImageCatalogService.parse(json(images: bad))
            let catalog = try #require(result.catalog)
            #expect(catalog.images.isEmpty)
            #expect(result.rejections == [.invalidPattern(id: "debian-13", pattern: pattern)])
        }
    }

    @Test("A checksum manifest that is not a plain filename is rejected")
    func rejectsManifestWithSeparator() throws {
        for manifest in ["../SHA256SUMS", "sums/SHA256SUMS", ""] {
            let bad = goodEntry.replacingOccurrences(
                of: "\"SHA256SUMS\"", with: "\"\(manifest)\"")
            let result = LinuxImageCatalogService.parse(json(images: bad))
            let catalog = try #require(result.catalog)
            #expect(catalog.images.isEmpty)
            #expect(
                result.rejections == [.invalidManifestName(id: "debian-13", manifest: manifest)])
        }
    }

    @Test("A repeated id is kept once")
    func rejectsDuplicateID() throws {
        let result = LinuxImageCatalogService.parse(json(images: "\(goodEntry), \(goodEntry)"))
        let catalog = try #require(result.catalog)
        #expect(catalog.images.count == 1)
        #expect(result.rejections == [.duplicateID(id: "debian-13")])
    }

    @Test("Parsed entries come back in display order regardless of input order")
    func sortsParsedEntries() throws {
        let ubuntu =
            goodEntry
            .replacingOccurrences(of: "\"debian-13\"", with: "\"ubuntu-desktop-26.04\"")
            .replacingOccurrences(of: "\"Debian\"", with: "\"Ubuntu Desktop\"")
            .replacingOccurrences(of: "\"13\"", with: "\"26.04 LTS\"")
        let result = LinuxImageCatalogService.parse(json(images: "\(goodEntry), \(ubuntu)"))
        let catalog = try #require(result.catalog)
        #expect(catalog.images.map(\.id) == ["ubuntu-desktop-26.04", "debian-13"])
    }

    @Test("The catalog shipped in the app bundle parses clean")
    func bundledCatalogIsValid() throws {
        let url = try #require(
            Bundle.main.url(forResource: "LinuxImageCatalog", withExtension: "json"))
        let result = LinuxImageCatalogService.parse(try Data(contentsOf: url))
        #expect(result.rejections.isEmpty)

        let service = LinuxImageCatalogService()
        #expect(!service.entries.isEmpty)
        #expect(service.generatedAt != nil)

        // Every shipped invariant the parser enforces, asserted against the real
        // resource rather than a fixture. Counts are deliberately absent: the
        // catalog is regenerated whenever a distribution ships.
        #expect(Set(service.entries.map(\.id)).count == service.entries.count)
        for entry in service.entries {
            #expect(entry.directoryURL.scheme == "https")
            // A filename resolves against the directory only when it ends in a
            // separator; without one the last segment is replaced instead.
            #expect(entry.directoryURL.absoluteString.hasSuffix("/"))
            #expect(LinuxImageCatalogService.isFilenameGlob(entry.isoPattern))
            #expect(LinuxImageCatalogService.isFilename(entry.checksumManifest))
            #expect(entry.approxSizeBytes > 0)
        }
        let sorted = service.entries.sorted(by: LinuxImageCatalogEntry.isOrderedBefore)
        #expect(sorted.map(\.id) == service.entries.map(\.id))
    }
}
