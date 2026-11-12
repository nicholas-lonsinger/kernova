import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore

@Suite("CustomLinuxImage Tests", .caseScoped)
struct CustomLinuxImageTests {
    private let digest = "9866e6b13a12f8dfdda382d414ccd90da60b898beeaa80cd87e55b25fdc11a06"

    // MARK: - Checksum

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
}
