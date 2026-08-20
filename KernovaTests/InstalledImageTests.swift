import Foundation
import Testing

@testable import Kernova

@Suite("InstalledImage Tests", .admissionGated)
struct InstalledImageTests {
    private func roundTrip(_ image: InstalledImage) throws -> InstalledImage {
        let data = try VMConfiguration.makeJSONEncoder().encode(image)
        return try VMConfiguration.makeJSONDecoder().decode(InstalledImage.self, from: data)
    }

    @Test("A macOS restore image survives a round trip")
    func macOSRoundTrip() throws {
        let image = InstalledImage.macOSRestoreImage(version: "26.5.2", build: "25F84")

        #expect(try roundTrip(image) == image)
    }

    @Test("A Linux catalog image survives a round trip")
    func linuxRoundTrip() throws {
        let image = InstalledImage.linuxCatalogImage(
            distribution: "Ubuntu Desktop", version: "26.04 LTS")

        #expect(try roundTrip(image) == image)
    }

    @Test("The payload keys sit flat beside the case name")
    func encodesFlat() throws {
        let data = try VMConfiguration.makeJSONEncoder().encode(
            InstalledImage.macOSRestoreImage(version: "26.5.2", build: "25F84"))
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: String])

        #expect(json == ["kind": "macOSRestoreImage", "version": "26.5.2", "build": "25F84"])
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
            InstalledImage.linuxCatalogImage(distribution: "Ubuntu Desktop", version: "26.04 LTS")
                .displayName == "Ubuntu Desktop 26.04 LTS")
    }

    @Test("A catalog source records the distribution and version it publishes")
    func recordsCatalogSource() {
        let source = LinuxInstallContext.Source.catalogEntry(
            makeLinuxCatalogEntry(distribution: "Fedora Workstation", version: "44"))

        #expect(
            InstalledImage(linuxSource: source)
                == .linuxCatalogImage(distribution: "Fedora Workstation", version: "44"))
    }

    @Test("A user-supplied URL records nothing")
    func recordsNothingForURLSource() {
        let source = LinuxInstallContext.Source.customURL(
            CustomLinuxImage(
                url: URL(string: "https://mirror.example/alpine-3.22-aarch64.iso")!,
                sha256: String(repeating: "a", count: 64)))

        #expect(InstalledImage(linuxSource: source) == nil)
    }
}
