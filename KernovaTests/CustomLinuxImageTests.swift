import Foundation
import Testing

@testable import Kernova

@Suite("CustomLinuxImage Tests")
struct CustomLinuxImageTests {
    private let digest = "9866e6b13a12f8dfdda382d414ccd90da60b898beeaa80cd87e55b25fdc11a06"

    // MARK: - Checksum

    @Test("An empty checksum is a deliberate 'don't verify', not a malformed one")
    func emptyChecksumIsNil() throws {
        #expect(try CustomLinuxImage.normalizedChecksum("") == nil)
        #expect(try CustomLinuxImage.normalizedChecksum("   \n ") == nil)
    }

    @Test("A checksum is accepted in either case and stored lowercase")
    func checksumNormalizesCase() throws {
        #expect(try CustomLinuxImage.normalizedChecksum("  \(digest.uppercased())  ") == digest)
    }

    @Test(
        "Anything that isn't 64 hex characters is refused",
        arguments: [
            "9866e6b13a12f8dfdda382d414ccd90da60b898beeaa80cd87e55b25fdc11a0",  // 63
            "9866e6b13a12f8dfdda382d414ccd90da60b898beeaa80cd87e55b25fdc11a066",  // 65
            "9866e6b13a12f8dfdda382d414ccd90da60b898beeaa80cd87e55b25fdc11ag6",  // not hex
            // SHA-512, which several mirrors publish beside the SHA-256.
            String(repeating: "a", count: 128),
        ])
    func malformedChecksumIsRefused(text: String) {
        #expect(throws: LinuxImageURLError.malformedChecksum) {
            try CustomLinuxImage.normalizedChecksum(text)
        }
    }

    // MARK: - Admission

    @Test("An HTTPS link to an .iso is accepted with or without a checksum")
    func acceptsHTTPS() throws {
        let verified = try CustomLinuxImage.make(
            urlText: "  https://mirror.example/alpine-3.22-aarch64.iso  ", checksumText: digest)
        #expect(verified.url.absoluteString == "https://mirror.example/alpine-3.22-aarch64.iso")
        #expect(verified.sha256 == digest)
        #expect(try verified.validatedFilename() == "alpine-3.22-aarch64.iso")

        let unverified = try CustomLinuxImage.make(
            urlText: "https://mirror.example/alpine-3.22-aarch64.iso", checksumText: "")
        #expect(unverified.sha256 == nil)
    }

    @Test("A plain-HTTP link is accepted only with a checksum behind it")
    func httpFollowsTheChecksum() throws {
        // The digest carries integrity independently of the transport, which is
        // the whole of why http is admissible here and nowhere else.
        let withDigest = try CustomLinuxImage.make(
            urlText: "http://mirror.example/alpine-3.22-aarch64.iso", checksumText: digest)
        #expect(withDigest.url.scheme == "http")

        #expect(throws: LinuxImageURLError.insecureURL) {
            try CustomLinuxImage.make(
                urlText: "http://mirror.example/alpine-3.22-aarch64.iso", checksumText: "")
        }
    }

    @Test("A scheme that isn't http or https is refused whatever the checksum says")
    func refusesOtherSchemes() {
        for text in ["file:///tmp/alpine.iso", "ftp://mirror.example/alpine.iso"] {
            #expect(throws: LinuxImageURLError.unsupportedScheme) {
                try CustomLinuxImage.make(urlText: text, checksumText: digest)
            }
        }
    }

    @Test("Text that names no host is not a URL")
    func refusesMalformedURL() {
        for text in ["", "   ", "not a url", "https:///alpine.iso"] {
            #expect(throws: LinuxImageURLError.malformedURL) {
                try CustomLinuxImage.make(urlText: text, checksumText: "")
            }
        }
    }

    @Test("A link that doesn't end in an .iso filename names no destination")
    func refusesNonISOLink() {
        for text in [
            "https://mirror.example/downloads/",
            "https://mirror.example/get?image=alpine",
            "https://mirror.example/alpine-3.22-aarch64.img",
        ] {
            #expect(throws: LinuxImageURLError.notAnISOLink) {
                try CustomLinuxImage.make(urlText: text, checksumText: "")
            }
        }
    }

    @Test("A query string doesn't stop the path from naming the file")
    func filenameIgnoresQuery() throws {
        let image = try CustomLinuxImage.make(
            urlText: "https://mirror.example/alpine-3.22-aarch64.iso?mirror=eu", checksumText: "")

        #expect(try image.validatedFilename() == "alpine-3.22-aarch64.iso")
    }

    @Test("A percent-encoded name that decodes to a path is refused")
    func refusesEscapingFilename() {
        // `URL.lastPathComponent` percent-decodes, so this arrives as
        // `../../evil.iso` — a value that walks out of Downloads.
        #expect(throws: LinuxImageURLError.notAnISOLink) {
            try CustomLinuxImage.make(
                urlText: "https://mirror.example/a%2F..%2F..%2Fevil.iso", checksumText: "")
        }
    }

    // MARK: - Re-admission at use time

    @Test("A hand-edited context is held to the same rules at use time")
    func validatesEditedValues() {
        // These bypass `make` the way an edited `config.json` does.
        #expect(throws: LinuxImageURLError.insecureURL) {
            try CustomLinuxImage(
                url: URL(string: "http://mirror.example/alpine.iso")!, sha256: nil
            ).validatedFilename()
        }
        #expect(throws: LinuxImageURLError.malformedChecksum) {
            try CustomLinuxImage(
                url: URL(string: "https://mirror.example/alpine.iso")!, sha256: "deadbeef"
            ).validatedFilename()
        }
        #expect(throws: LinuxImageURLError.notAnISOLink) {
            try CustomLinuxImage(
                url: URL(string: "https://mirror.example/alpine.img")!, sha256: nil
            ).validatedFilename()
        }
    }
}
