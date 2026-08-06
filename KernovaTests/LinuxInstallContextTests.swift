import Foundation
import Testing

@testable import Kernova

@Suite("LinuxInstallContext Tests")
struct LinuxInstallContextTests {
    private func roundTrip(_ context: LinuxInstallContext) throws
        -> LinuxInstallContext
    {
        let data = try VMConfiguration.makeJSONEncoder().encode(context)
        return try VMConfiguration.makeJSONDecoder().decode(
            LinuxInstallContext.self, from: data)
    }

    @Test("A fully populated catalog context survives a round trip")
    func fullRoundTrip() throws {
        let context = LinuxInstallContext(
            source: .catalogEntry(
                makeLinuxCatalogEntry(
                    id: "ubuntu-desktop-26.04", distribution: "Ubuntu Desktop",
                    version: "26.04 LTS")),
            downloadDestinationPath: "/Users/test/Downloads/ubuntu-26.04-desktop-arm64.iso",
            requestedFreshDownload: true
        )

        #expect(try roundTrip(context) == context)
    }

    @Test("A URL context survives a round trip with its checksum")
    func customURLRoundTrip() throws {
        let context = LinuxInstallContext(
            source: .customURL(
                CustomLinuxImage(
                    url: URL(string: "https://mirror.example/alpine-3.22-aarch64.iso")!,
                    sha256: String(repeating: "a", count: 64))),
            downloadDestinationPath: "/Users/test/Downloads/alpine-3.22-aarch64.iso"
        )

        #expect(try roundTrip(context) == context)
    }

    @Test("A URL context with no checksum round-trips as unverified")
    func customURLWithoutChecksumRoundTrip() throws {
        let context = LinuxInstallContext(
            source: .customURL(
                CustomLinuxImage(
                    url: URL(string: "https://mirror.example/alpine-3.22-aarch64.iso")!,
                    sha256: nil)))

        let decoded = try roundTrip(context)

        #expect(decoded == context)
        #expect(decoded.hasVerifyStep == false)
    }

    @Test("The whole catalog entry travels with the context")
    func entryIsEmbedded() throws {
        // Embedded rather than referenced by id: the bundled catalog is
        // rewritten whenever the mirrors move, and this VM must keep fetching
        // the distribution the user picked.
        let entry = makeLinuxCatalogEntry(
            id: "fedora-44", distribution: "Fedora Workstation", version: "44",
            isoPattern: "Fedora-Workstation-Live-44-*.aarch64.iso",
            checksumManifest: "Fedora-Workstation-44-1.7-aarch64-CHECKSUM")

        let decoded = try roundTrip(LinuxInstallContext(source: .catalogEntry(entry)))

        #expect(catalogEntry(of: decoded) == entry)
        #expect(catalogEntry(of: decoded)?.isoPattern == "Fedora-Workstation-Live-44-*.aarch64.iso")
        #expect(
            catalogEntry(of: decoded)?.checksumManifest
                == "Fedora-Workstation-44-1.7-aarch64-CHECKSUM")
    }

    @Test("A catalog pick always has something to verify against")
    func catalogAlwaysVerifies() {
        #expect(LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry())).hasVerifyStep)
    }

    @Test("The display name is the distribution for a catalog pick and the file for a URL")
    func displayName() {
        let catalog = LinuxInstallContext(
            source: .catalogEntry(
                makeLinuxCatalogEntry(distribution: "Ubuntu Desktop", version: "26.04 LTS")))
        #expect(catalog.imageDisplayName == "Ubuntu Desktop 26.04 LTS")

        let url = LinuxInstallContext(
            source: .customURL(
                CustomLinuxImage(
                    url: URL(string: "https://mirror.example/dl/alpine-3.22-aarch64.iso")!,
                    sha256: String(repeating: "b", count: 64))))
        #expect(url.imageDisplayName == "alpine-3.22-aarch64.iso")
    }

    @Test("A URL edited into a config.json past admission still names something showable")
    func displayNameForUnusableURL() {
        // The name is only read for display, so an edited URL degrades to a
        // phrase rather than failing the banner that shows it. Refusing the URL
        // itself is the download's job.
        let context = LinuxInstallContext(
            source: .customURL(
                CustomLinuxImage(url: URL(string: "https://mirror.example/")!, sha256: nil)))

        #expect(context.imageDisplayName == "the installer image")
    }

    @Test("downloadDestinationURL is nil until a resolution names the file")
    func destinationURL() {
        var context = LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry()))
        #expect(context.downloadDestinationURL == nil)

        context.downloadDestinationPath = "/Users/test/Downloads/debian-13.6.0-arm64-netinst.iso"
        #expect(
            context.downloadDestinationURL?.lastPathComponent == "debian-13.6.0-arm64-netinst.iso")
    }
}
