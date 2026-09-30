import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("InstalledImage Tests", .caseScoped)
struct InstalledImageTests {
    private static let digest = String(repeating: "ab", count: 32)
    private static let manifestURL = URL(
        string: "https://cdimage.ubuntu.com/ubuntu/releases/resolute/release/SHA256SUMS")!
    private static let isoURL = URL(string: "https://mirror.example/alpine-3.22-aarch64.iso")!

    private func roundTrip(_ image: InstalledImage) throws -> InstalledImage {
        let data = try VMConfiguration.makeJSONEncoder().encode(image)
        return try VMConfiguration.makeJSONDecoder().decode(InstalledImage.self, from: data)
    }

    private func decode(_ json: [String: String]) throws -> InstalledImage {
        try VMConfiguration.makeJSONDecoder().decode(
            InstalledImage.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func encodedObject(_ image: InstalledImage) throws -> [String: String] {
        let data = try VMConfiguration.makeJSONEncoder().encode(image)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    private func matched(_ source: DigestSource, filename: String) throws -> InstallerImageDigest {
        try #require(
            ExpectedDigest(sha256: Self.digest, source: source)
                .match(Self.digest, filename: filename))
    }

    @Test("A macOS restore image survives a round trip")
    func macOSRoundTrip() throws {
        let image = InstalledImage.macOSRestoreImage(version: "26.5.2", build: "25F84")

        #expect(try roundTrip(image) == image)
    }

    @Test("A Linux catalog image survives a round trip with its digest")
    func linuxRoundTrip() throws {
        let image = InstalledImage.linuxCatalogImage(
            distribution: "Ubuntu Desktop", version: "26.04 LTS",
            digest: try matched(
                .checksumList(Self.manifestURL), filename: "ubuntu-26.04-desktop-arm64.iso"))

        #expect(try roundTrip(image) == image)
    }

    @Test("A checked URL image survives a round trip")
    func checkedURLRoundTrip() throws {
        let image = InstalledImage.linuxURLImage(
            url: Self.isoURL,
            digest: try matched(.enteredByUser, filename: "alpine-3.22-aarch64.iso"))

        #expect(try roundTrip(image) == image)
    }

    @Test("An unchecked URL image survives a round trip")
    func uncheckedURLRoundTrip() throws {
        let image = InstalledImage.linuxURLImage(
            url: Self.isoURL,
            digest: .unchecked(filename: "alpine-3.22-aarch64.iso", sha256: Self.digest))

        #expect(try roundTrip(image) == image)
    }

    @Test("The payload keys sit flat beside the case name")
    func encodesFlat() throws {
        #expect(
            try encodedObject(.macOSRestoreImage(version: "26.5.2", build: "25F84"))
                == ["kind": "macOSRestoreImage", "version": "26.5.2", "build": "25F84"])
        #expect(
            try encodedObject(
                .linuxCatalogImage(
                    distribution: "Ubuntu Desktop", version: "26.04 LTS",
                    digest: try matched(.checksumList(Self.manifestURL), filename: "u.iso")))
                == [
                    "kind": "linuxCatalogImage", "distribution": "Ubuntu Desktop",
                    "version": "26.04 LTS", "filename": "u.iso", "sha256": Self.digest,
                    "checkedAgainst": "checksumList",
                    "checksumListURL": Self.manifestURL.absoluteString,
                ])
        #expect(
            try encodedObject(
                .linuxURLImage(
                    url: Self.isoURL, digest: try matched(.enteredByUser, filename: "a.iso")))
                == [
                    "kind": "linuxURLImage", "url": Self.isoURL.absoluteString,
                    "filename": "a.iso", "sha256": Self.digest,
                    "checkedAgainst": "enteredChecksum",
                ])
        #expect(
            try encodedObject(
                .linuxURLImage(
                    url: Self.isoURL, digest: .unchecked(filename: "a.iso", sha256: Self.digest)))
                == [
                    "kind": "linuxURLImage", "url": Self.isoURL.absoluteString,
                    "filename": "a.iso", "sha256": Self.digest, "checkedAgainst": "nothing",
                ])
    }

    @Test("A catalog record with no digest keys decodes with no digest")
    func decodesCatalogRecordWithoutDigest() throws {
        #expect(
            try decode(
                ["kind": "linuxCatalogImage", "distribution": "Debian", "version": "13"])
                == .linuxCatalogImage(distribution: "Debian", version: "13", digest: nil))
    }

    @Test("A record whose sha256 is not a SHA-256 is refused")
    func refusesMalformedDigest() {
        #expect(throws: DecodingError.self) {
            try decode([
                "kind": "linuxURLImage", "url": Self.isoURL.absoluteString,
                "filename": "a.iso", "sha256": "deadbeef", "checkedAgainst": "enteredChecksum",
            ])
        }
    }

    @Test("A stored uppercase digest reads back lowercase")
    func lowercasesDecodedDigest() throws {
        let image = try decode([
            "kind": "linuxURLImage", "url": Self.isoURL.absoluteString,
            "filename": "a.iso", "sha256": Self.digest.uppercased(), "checkedAgainst": "nothing",
        ])

        #expect(
            image
                == .linuxURLImage(
                    url: Self.isoURL, digest: .unchecked(filename: "a.iso", sha256: Self.digest)))
    }

    @Test("A macOS record reads as the restore image's version and build")
    func macOSDisplayName() {
        #expect(
            InstalledImage.macOSRestoreImage(version: "26.5.2", build: "25F84").displayName
                == "macOS 26.5.2 (25F84)")
    }

    @Test("A Linux record reads as the distribution and version the catalog names")
    func linuxDisplayName() {
        #expect(
            InstalledImage.linuxCatalogImage(
                distribution: "Ubuntu Desktop", version: "26.04 LTS", digest: nil
            ).displayName == "Ubuntu Desktop 26.04 LTS")
    }

    @Test("A URL record reads as the filename its digest belongs to")
    func urlDisplayName() {
        #expect(
            InstalledImage.linuxURLImage(
                url: Self.isoURL,
                digest: .unchecked(filename: "alpine-3.22-aarch64.iso", sha256: Self.digest)
            ).displayName == "alpine-3.22-aarch64.iso")
    }

    @Test("A catalog source records the distribution and version it publishes, and the digest")
    func recordsCatalogSource() throws {
        let source = LinuxInstallContext.Source.catalogEntry(
            makeLinuxCatalogEntry(distribution: "Fedora Workstation", version: "44"))
        let digest = try matched(.checksumList(Self.manifestURL), filename: "Fedora-44.iso")

        #expect(
            InstalledImage(linuxSource: source, digest: digest)
                == .linuxCatalogImage(distribution: "Fedora Workstation", version: "44", digest: digest))
    }

    @Test("A user-supplied URL records the URL and the digest")
    func recordsURLSource() {
        let source = LinuxInstallContext.Source.customURL(
            CustomLinuxImage(url: Self.isoURL, sha256: nil))
        let digest = InstallerImageDigest.unchecked(
            filename: "alpine-3.22-aarch64.iso", sha256: Self.digest)

        #expect(
            InstalledImage(linuxSource: source, digest: digest)
                == .linuxURLImage(url: Self.isoURL, digest: digest))
    }
}
