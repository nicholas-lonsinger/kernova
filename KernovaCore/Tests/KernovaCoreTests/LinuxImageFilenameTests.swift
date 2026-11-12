import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore

@Suite("LinuxImageFilename Tests", .caseScoped)
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
}
