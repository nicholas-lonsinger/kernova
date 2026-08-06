import Foundation
import Testing

@testable import Kernova

@Suite("LinuxImageDownloadContext Tests")
struct LinuxImageDownloadContextTests {
    private func roundTrip(_ context: LinuxImageDownloadContext) throws
        -> LinuxImageDownloadContext
    {
        let data = try VMConfiguration.makeJSONEncoder().encode(context)
        return try VMConfiguration.makeJSONDecoder().decode(
            LinuxImageDownloadContext.self, from: data)
    }

    @Test("A fully populated context survives a round trip")
    func fullRoundTrip() throws {
        let context = LinuxImageDownloadContext(
            entry: makeLinuxCatalogEntry(
                id: "ubuntu-desktop-26.04", distribution: "Ubuntu Desktop", version: "26.04 LTS"),
            downloadDestinationPath: "/Users/test/Downloads/ubuntu-26.04-desktop-arm64.iso",
            requestedFreshDownload: true
        )

        #expect(try roundTrip(context) == context)
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

        let decoded = try roundTrip(LinuxImageDownloadContext(entry: entry))

        #expect(decoded.entry == entry)
        #expect(decoded.entry.isoPattern == "Fedora-Workstation-Live-44-*.aarch64.iso")
        #expect(decoded.entry.checksumManifest == "Fedora-Workstation-44-1.7-aarch64-CHECKSUM")
    }

    @Test("A context with only its entry decodes with the documented defaults")
    func absentKeysTakeDefaults() throws {
        let entry = makeLinuxCatalogEntry()
        let entryJSON = String(
            decoding: try VMConfiguration.makeJSONEncoder().encode(entry), as: UTF8.self)
        let json = Data("{\"entry\":\(entryJSON)}".utf8)

        let decoded = try VMConfiguration.makeJSONDecoder().decode(
            LinuxImageDownloadContext.self, from: json)

        #expect(decoded.entry == entry)
        #expect(decoded.downloadDestinationPath == nil)
        #expect(decoded.requestedFreshDownload == false)
    }

    @Test("downloadDestinationURL is nil until a resolution names the file")
    func destinationURL() {
        var context = LinuxImageDownloadContext(entry: makeLinuxCatalogEntry())
        #expect(context.downloadDestinationURL == nil)

        context.downloadDestinationPath = "/Users/test/Downloads/debian-13.6.0-arm64-netinst.iso"
        #expect(
            context.downloadDestinationURL?.lastPathComponent == "debian-13.6.0-arm64-netinst.iso")
    }
}
