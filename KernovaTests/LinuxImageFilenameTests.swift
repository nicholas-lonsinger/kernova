import Foundation
import Testing

@testable import Kernova

@Suite("LinuxImageFilename Tests", .admissionGated)
struct LinuxImageFilenameTests {
    private func url(_ text: String) throws -> URL {
        try #require(URL(string: text))
    }

    @Test("The destination is unique to the URL, not the name the URL gives")
    func destinationIsUniquePerURL() throws {
        // A source naming its ISO after a file the user already has in
        // Downloads would otherwise resolve to their file, which the download
        // adopts in place of fetching — installing an image they never chose
        // when nothing is verified, and trashing their file when something is.
        let first = LinuxImageFilename.destination(for: try url("https://one.example/alpine.iso"))
        let second = LinuxImageFilename.destination(for: try url("https://two.example/alpine.iso"))

        #expect(first != second)
        #expect(first != "alpine.iso")
        #expect(first.hasPrefix("alpine-"))
        #expect(first.hasSuffix(".iso"))
    }

    @Test("A path a source could name is never reproduced in the destination")
    func destinationIsOneComponent() throws {
        // `URL.lastPathComponent` percent-decodes, so this arrives as
        // `../../evil.iso` — a stem the generator refuses in favor of its
        // default.
        let escaping = LinuxImageFilename.destination(
            for: try url("https://mirror.example/a%2F..%2F..%2Fevil.iso"))

        #expect(!escaping.contains("/"))
        #expect(escaping.hasPrefix("LinuxImage-"))
    }

    @Test("One URL always names the same destination, so a download stays resumable")
    func destinationIsStableForOneURL() throws {
        let iso = try url("https://mirror.example/alpine-3.22-aarch64.iso")

        #expect(LinuxImageFilename.destination(for: iso) == LinuxImageFilename.destination(for: iso))
    }

    @Test("A URL that names no usable stem still yields an .iso destination")
    func destinationFallsBackToADefaultStem() throws {
        let name = LinuxImageFilename.destination(for: try url("https://mirror.example/"))

        #expect(name.hasPrefix("LinuxImage-"))
        #expect(name.hasSuffix(".iso"))
    }

    // MARK: - Reading a destination back

    @Test("A destination this app generated names the image the source published")
    func sourceFilenameRecoversTheSourceName() throws {
        let iso = try url(
            "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/debian-13.6.0-arm64-netinst.iso"
        )

        #expect(
            LinuxImageFilename.sourceFilename(of: LinuxImageFilename.destination(for: iso))
                == "debian-13.6.0-arm64-netinst.iso")
    }

    @Test(
        "A name this app did not generate belongs to no source",
        arguments: [
            // The mirror's own name, as a user's own fetch would leave it.
            "debian-13.6.0-arm64-netinst.iso",
            // A discriminator that is not eight lowercase hex characters.
            "debian-1a2b3c4.iso",
            "debian-1a2b3c4de.iso",
            "debian-1A2B3C4D.iso",
            "debian-nothexes.iso",
            // Nothing in front of the discriminator to name a source.
            "-1a2b3c4d.iso",
            // Not an ISO, so not an image at all — a resume bundle among them.
            "debian-13.6.0-arm64-netinst-1a2b3c4d.kernovadownload",
            "debian-1a2b3c4d.img",
        ])
    func sourceFilenameRefusesForeignNames(candidate: String) {
        #expect(LinuxImageFilename.sourceFilename(of: candidate) == nil)
    }
}
