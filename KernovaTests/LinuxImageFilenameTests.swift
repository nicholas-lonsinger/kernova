import Foundation
import Testing

@testable import Kernova

@Suite("LinuxImageFilename Tests")
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
}
