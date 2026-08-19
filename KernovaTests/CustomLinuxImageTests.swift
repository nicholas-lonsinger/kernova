import Foundation
import Testing

@testable import Kernova

@Suite("CustomLinuxImage Tests", .admissionGated)
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
        #expect(verified.displayName == "alpine-3.22-aarch64.iso")

        let unverified = try CustomLinuxImage.make(
            urlText: "https://mirror.example/alpine-3.22-aarch64.iso", checksumText: "")
        #expect(unverified.sha256 == nil)
    }

    @Test("A non-HTTPS link is refused whatever the checksum says")
    func refusesNonHTTPS() {
        // App Transport Security refuses a cleartext load to a public host
        // before the request is issued, so a checksum cannot buy admission for
        // one here — the refusal would only arrive later and less legibly.
        for text in [
            "http://mirror.example/alpine-3.22-aarch64.iso",
            "file:///tmp/alpine.iso",
            "ftp://mirror.example/alpine.iso",
        ] {
            #expect(throws: LinuxImageURLError.insecureURL) {
                try CustomLinuxImage.make(urlText: text, checksumText: digest)
            }
            #expect(throws: LinuxImageURLError.insecureURL) {
                try CustomLinuxImage.make(urlText: text, checksumText: "")
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

    @Test("A link that doesn't end in an .iso filename is not admitted")
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

        #expect(image.displayName == "alpine-3.22-aarch64.iso")
        #expect(try image.admittedFilename() == "alpine-3.22-aarch64.iso")
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
            ).admittedFilename()
        }
        #expect(throws: LinuxImageURLError.malformedChecksum) {
            try CustomLinuxImage(
                url: URL(string: "https://mirror.example/alpine.iso")!, sha256: "deadbeef"
            ).admittedFilename()
        }
        #expect(throws: LinuxImageURLError.notAnISOLink) {
            try CustomLinuxImage(
                url: URL(string: "https://mirror.example/alpine.img")!, sha256: nil
            ).admittedFilename()
        }
    }
}
