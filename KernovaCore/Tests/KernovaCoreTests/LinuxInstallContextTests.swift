import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("LinuxInstallContext Tests", .caseScoped)
struct LinuxInstallContextTests {
    private func roundTrip(_ context: LinuxInstallContext) throws
        -> LinuxInstallContext
    {
        let data = try VMConfiguration.makeJSONEncoder().encode(context)
        return try VMConfiguration.makeJSONDecoder().decode(
            LinuxInstallContext.self, from: data)
    }

    @Test("A URL pick with a checksum is checked against what the user entered")
    func customURLChecksAgainstEnteredChecksum() async throws {
        let source = LinuxInstallContext.Source.customURL(
            CustomLinuxImage(
                url: URL(string: "https://mirror.example/alpine-3.22-aarch64.iso")!,
                sha256: String(repeating: "a", count: 64)))

        let (_, expected) = try await source.resolve(using: MockLinuxImageResolveService())

        #expect(
            expected == ExpectedDigest(sha256: String(repeating: "a", count: 64), source: .enteredByUser))
        #expect(source.digestSource == .enteredByUser)
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
}
