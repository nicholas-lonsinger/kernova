import Foundation
import Testing

@testable import Kernova

// MARK: - Manifest fixtures

/// Ubuntu's `SHA256SUMS`: GNU binary mode, one space and an asterisk.
///
/// The `+largemem` server variant sits in the real file beside the plain one,
/// which is what an anchored glob has to keep out.
private let ubuntuManifest = """
    93b805a2e39d472e51117ac4ac21b1110f05d4c5365ae4b90d23f5e4e44e53f9 *ubuntu-24.04.3-desktop-arm64.iso
    0be6df929cb47d4f188ab94d1fdedc75aa947d1fe7d4a17fb70f65c130699a44 *ubuntu-24.04.4-desktop-arm64.iso
    eeffbfb8009ede3f363606b38c2889ea4ba2f174d50b6c5bab555004336e2904 *ubuntu-24.04.4-live-server-arm64.iso
    416d362ba65a37644ca3f8ab7f920257d8c84d965dee0f0a56dea2ea5ec1ff2e *ubuntu-24.04.4-live-server-arm64+largemem.iso
    """

/// Debian's `SHA256SUMS`: GNU text mode, two spaces, with a SHA-512 line and a
/// comment for company.
private let debianManifest = """
    # SHA256 checksums for the arm64 netinst images
    9866e6b13a12f8dfdda382d414ccd90da60b898beeaa80cd87e55b25fdc11a06  debian-13.6.0-arm64-netinst.iso
    a4abd4448c49562d828115d13a1fccea927f52b4d5459297f8b43e42da89238bc13626e43dcb38ddb082488927ec904fb42057443983e88585179d50551afe62  debian-13.6.0-arm64-netinst.iso
    """

/// Fedora's `CHECKSUM`: BSD lines inside GPG clearsign armor, with the header
/// block, comments, a dash-escaped line and a SHA-512 line to step over.
private let fedoraManifest = """
    -----BEGIN PGP SIGNED MESSAGE-----
    Hash: sha256

    # Fedora-Workstation-Live-44-1.7.aarch64.iso: 2689781760 bytes
    SHA256 (Fedora-Workstation-Live-44-1.7.aarch64.iso) = 66c07e7355db5e92faef680599a1789184a31c4dbaa5e02a19d050cc4e9279d2
    SHA512 (Fedora-Workstation-Live-44-1.7.aarch64.iso) = a4abd4448c49562d828115d13a1fccea927f52b4d5459297f8b43e42da89238bc13626e43dcb38ddb082488927ec904fb42057443983e88585179d50551afe62
    - SHA256 (Fedora-Workstation-44-1.7.aarch64.raw.xz) = 6eae4262d9b0c1588fbc495a42dc5389d580b90026270e91a18c112d0cb5e740
    -----BEGIN PGP SIGNATURE-----

    iQIzBAEBCAAdFiEEcQ0F2wIhE0nEXeqoHqPGtqLGkoUFAmYxAAAKCRAeo8a2osaS
    hfF1D/9nYVYyRZ0xU2NwZXJmZWN0bHkgb3JkaW5hcnkgYmFzZTY0IHNpZ25hdHVy
    =Ab3d
    -----END PGP SIGNATURE-----
    """

@Suite("ChecksumManifest Tests", .admissionGated)
struct ChecksumManifestTests {
    @Test("GNU binary mode reads the filename past its asterisk")
    func parsesUbuntuBinaryMode() {
        let rows = ChecksumManifest.parse(ubuntuManifest)

        #expect(rows.count == 4)
        #expect(rows.first?.filename == "ubuntu-24.04.3-desktop-arm64.iso")
        #expect(
            rows.first?.sha256
                == "93b805a2e39d472e51117ac4ac21b1110f05d4c5365ae4b90d23f5e4e44e53f9")
        #expect(rows.allSatisfy { !$0.filename.hasPrefix("*") })
    }

    @Test("GNU text mode reads the filename past two spaces, and only the SHA-256 line")
    func parsesDebianTextMode() {
        let rows = ChecksumManifest.parse(debianManifest)

        #expect(rows.count == 1)
        #expect(rows.first?.filename == "debian-13.6.0-arm64-netinst.iso")
        #expect(
            rows.first?.sha256
                == "9866e6b13a12f8dfdda382d414ccd90da60b898beeaa80cd87e55b25fdc11a06")
    }

    @Test("Clearsign armor, headers, comments and SHA-512 are stepped over")
    func parsesFedoraClearsignedBSD() {
        let rows = ChecksumManifest.parse(fedoraManifest)

        #expect(rows.count == 2)
        #expect(rows.first?.filename == "Fedora-Workstation-Live-44-1.7.aarch64.iso")
        #expect(
            rows.first?.sha256
                == "66c07e7355db5e92faef680599a1789184a31c4dbaa5e02a19d050cc4e9279d2")
        // The dash-escaped line is a manifest line, not armor.
        #expect(rows.last?.filename == "Fedora-Workstation-44-1.7.aarch64.raw.xz")
    }

    @Test("An uppercase digest comes back lowercase, so it compares against a computed one")
    func normalizesDigestCase() {
        let digest = "93B805A2E39D472E51117AC4AC21B1110F05D4C5365AE4B90D23F5E4E44E53F9"
        let rows = ChecksumManifest.parse("\(digest)  ubuntu-24.04.3-desktop-arm64.iso")

        #expect(rows.first?.sha256 == digest.lowercased())
    }

    @Test(
        "A line whose hash is not 64 hex digits states no pair",
        arguments: [
            // 63 digits, and 65.
            "93b805a2e39d472e51117ac4ac21b1110f05d4c5365ae4b90d23f5e4e44e53f  image.iso",
            "93b805a2e39d472e51117ac4ac21b1110f05d4c5365ae4b90d23f5e4e44e53f99  image.iso",
            // Not hex at all.
            "zzb805a2e39d472e51117ac4ac21b1110f05d4c5365ae4b90d23f5e4e44e53f9  image.iso",
            // No separator between hash and filename.
            "93b805a2e39d472e51117ac4ac21b1110f05d4c5365ae4b90d23f5e4e44e53f9image.iso",
            // A hash with no filename after it.
            "93b805a2e39d472e51117ac4ac21b1110f05d4c5365ae4b90d23f5e4e44e53f9  ",
            // BSD form naming another algorithm.
            "SHA1 (image.iso) = 93b805a2e39d472e51117ac4ac21b1110f05d4c5365ae4b90d23f5e4e44e53f9",
        ])
    func rejectsMalformedLines(line: String) {
        #expect(ChecksumManifest.parse(line).isEmpty)
    }

    @Test("A body that is not a manifest at all states no pairs")
    func parsesNothingOutOfAnErrorPage() {
        let page = """
            <!DOCTYPE html>
            <html><head><title>404 Not Found</title></head>
            <body><h1>Not Found</h1></body></html>
            """

        #expect(ChecksumManifest.parse(page).isEmpty)
        #expect(ChecksumManifest.parse("").isEmpty)
    }
}

@Suite("ISOFilenameGlob Tests", .admissionGated)
struct ISOFilenameGlobTests {
    private func glob(_ pattern: String) throws -> ISOFilenameGlob {
        try #require(ISOFilenameGlob(pattern))
    }

    @Test("A wildcard absorbs a point release, and the pattern's ends are anchored")
    func matchesWithinOneFilename() throws {
        let desktop = try glob("ubuntu-24.04*-desktop-arm64.iso")

        #expect(desktop.matches("ubuntu-24.04.4-desktop-arm64.iso"))
        #expect(desktop.matches("ubuntu-24.04-desktop-arm64.iso"))
        #expect(!desktop.matches("ubuntu-24.04.4-live-server-arm64.iso"))
        #expect(!desktop.matches("xubuntu-24.04.4-desktop-arm64.iso"))
        #expect(!desktop.matches("ubuntu-24.04.4-desktop-arm64.iso.torrent"))
    }

    @Test("The `+largemem` variant is outside the anchored server pattern")
    func excludesLargememVariant() throws {
        let server = try glob("ubuntu-24.04*-live-server-arm64.iso")

        #expect(server.matches("ubuntu-24.04.4-live-server-arm64.iso"))
        #expect(!server.matches("ubuntu-24.04.4-live-server-arm64+largemem.iso"))
    }

    @Test("A wildcard stays inside one path component")
    func wildcardNeverCrossesASeparator() throws {
        let anyISO = try glob("*.iso")

        #expect(anyISO.matches("image.iso"))
        #expect(!anyISO.matches("dists/stable/image.iso"))
    }

    @Test("The newest point release wins, not the first listed")
    func picksHighestPointRelease() throws {
        let desktop = try glob("ubuntu-24.04*-desktop-arm64.iso")

        #expect(
            desktop.newest(among: [
                "ubuntu-24.04.4-desktop-arm64.iso",
                "ubuntu-24.04.3-desktop-arm64.iso",
            ]) == "ubuntu-24.04.4-desktop-arm64.iso")
        #expect(
            desktop.newest(among: [
                "ubuntu-24.04.3-desktop-arm64.iso",
                "ubuntu-24.04.4-desktop-arm64.iso",
            ]) == "ubuntu-24.04.4-desktop-arm64.iso")
        // Numeric, not lexicographic: .10 is newer than .9.
        #expect(
            desktop.newest(among: [
                "ubuntu-24.04.9-desktop-arm64.iso",
                "ubuntu-24.04.10-desktop-arm64.iso",
            ]) == "ubuntu-24.04.10-desktop-arm64.iso")
    }

    @Test("A point release outranks the release it followed, extra component and all")
    func pointReleaseOutranksGA() throws {
        let desktop = try glob("ubuntu-26.04*-desktop-arm64.iso")

        // Only the wildcard text ("" and ".1") is compared: reading the whole
        // filename would weigh the `arm64` in the literal tail against the `1`.
        #expect(
            desktop.newest(among: [
                "ubuntu-26.04-desktop-arm64.iso",
                "ubuntu-26.04.1-desktop-arm64.iso",
            ]) == "ubuntu-26.04.1-desktop-arm64.iso")
    }

    @Test("Fedora's respin is a wildcard too, and the newest one wins")
    func picksHighestFedoraRespin() throws {
        let workstation = try glob("Fedora-Workstation-Live-44-*.aarch64.iso")

        #expect(workstation.matches("Fedora-Workstation-Live-44-1.7.aarch64.iso"))
        #expect(!workstation.matches("Fedora-Workstation-Live-43-1.6.aarch64.iso"))
        #expect(
            workstation.newest(among: [
                "Fedora-Workstation-Live-44-1.7.aarch64.iso",
                "Fedora-Workstation-Live-44-1.10.aarch64.iso",
            ]) == "Fedora-Workstation-Live-44-1.10.aarch64.iso")
    }

    @Test("Nothing matching is nothing picked")
    func picksNothingWithoutAMatch() throws {
        let desktop = try glob("ubuntu-24.04*-desktop-arm64.iso")

        #expect(desktop.newest(among: ["ubuntu-24.04.4-live-server-arm64.iso"]) == nil)
        #expect(desktop.newest(among: [String]()) == nil)
    }

    @Test("A pattern with no wildcard matches only itself")
    func matchesLiteralPattern() throws {
        let literal = try glob("kali-linux-2026.2-installer-arm64.iso")

        #expect(literal.matches("kali-linux-2026.2-installer-arm64.iso"))
        #expect(!literal.matches("kali-linux-2026.3-installer-arm64.iso"))
    }
}

@Suite("SafeFilename Tests", .admissionGated)
struct SafeFilenameTests {
    @Test("One visible component with the required extension passes through")
    func acceptsPlainFilename() {
        #expect(
            SafeFilename.sanitized("debian-13.6.0-arm64-netinst.iso", requiring: "iso")
                == "debian-13.6.0-arm64-netinst.iso")
        #expect(SafeFilename.sanitized("image.ISO", requiring: "iso") == "image.ISO")
    }

    @Test(
        "Anything that is not one visible .iso component is refused",
        arguments: [
            "",
            ".",
            "..",
            "/",
            "a/../../evil.iso",
            "../evil.iso",
            "sub/dir/image.iso",
            ".hidden.iso",
            ".iso",
            "image.img",
            "a%2F..%2Fevil.iso",
        ])
    func refusesUnsafeCandidates(candidate: String) {
        #expect(SafeFilename.sanitized(candidate, requiring: "iso") == nil)
    }

    @Test("The required extension is what is asked for, not whatever the name carries")
    func refusesAnotherExtension() {
        #expect(SafeFilename.sanitized("image.iso", requiring: "ipsw") == nil)
        #expect(SafeFilename.sanitized("image.ipsw", requiring: "iso") == nil)
    }

    @Test("A name is accepted right up to the byte bound and refused past it")
    func refusesAnOverlongName() {
        let atBound =
            String(repeating: "a", count: SafeFilename.maximumByteCount - ".iso".utf8.count)
            + ".iso"
        #expect(atBound.utf8.count == SafeFilename.maximumByteCount)
        #expect(SafeFilename.sanitized(atBound, requiring: "iso") == atBound)
        #expect(SafeFilename.sanitized("a" + atBound, requiring: "iso") == nil)

        // Bounded in UTF-8 bytes, which is what the filesystem counts: this one
        // is barely half the bound in characters and past it on disk.
        let multibyte = String(repeating: "é", count: 101) + ".iso"
        #expect(multibyte.count < SafeFilename.maximumByteCount)
        #expect(SafeFilename.sanitized(multibyte, requiring: "iso") == nil)
    }
}

/// Stub for the resolve service's requests.
///
/// Its own class rather than `StubURLProtocol` or `ProbeStubURLProtocol`, for
/// the reason spelled out on the latter: the handler is a global, and Swift
/// Testing runs suites in parallel, so sharing one lets two suites clobber each
/// other's handler.
final class ResolveStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var statusCode: Int
        var body: Data
        var headers: [String: String] = [:]
    }

    nonisolated(unsafe) static var handler: ((URLRequest) -> Reply)?

    private static let recordLock = NSLock()
    nonisolated(unsafe) private static var requestedURLsStorage: [URL] = []

    /// Every URL the stub was asked for since the last `reset()`.
    static var requestedURLs: [URL] { recordLock.withLock { requestedURLsStorage } }

    /// Clears the handler and everything recorded about the requests it served.
    static func reset() {
        handler = nil
        recordLock.withLock { requestedURLsStorage = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: "ResolveStubURLProtocol", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No handler set"]))
            return
        }
        Self.recordLock.withLock { Self.requestedURLsStorage.append(url) }
        let reply = handler(request)
        var headers = reply.headers
        if headers["Content-Length"] == nil { headers["Content-Length"] = "\(reply.body.count)" }
        guard
            let response = HTTPURLResponse(
                url: url, statusCode: reply.statusCode, httpVersion: "HTTP/1.1",
                headerFields: headers)
        else {
            preconditionFailure("ResolveStubURLProtocol: could not build a response")
        }
        // A 3xx carrying a `Location` goes back as a redirect rather than as a
        // body, which is what puts the session's redirect policy in the loop.
        if (300..<400).contains(reply.statusCode), let location = headers["Location"],
            let target = URL(string: location, relativeTo: url)?.absoluteURL
        {
            client?.urlProtocol(
                self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("LinuxImageResolveService Tests", .serialized, .admissionGated)
struct LinuxImageResolveServiceTests {
    private func makeService() -> LinuxImageResolveService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses =
            [ResolveStubURLProtocol.self] + (configuration.protocolClasses ?? [])
        return LinuxImageResolveService(sessionConfiguration: configuration)
    }

    private var ubuntuEntry: LinuxImageCatalogEntry {
        makeLinuxCatalogEntry(
            id: "ubuntu-desktop-24.04",
            distribution: "Ubuntu Desktop",
            version: "24.04 LTS",
            directoryURLString: "https://cdimage.ubuntu.com/ubuntu/releases/noble/release/",
            isoPattern: "ubuntu-24.04*-desktop-arm64.iso"
        )
    }

    private var fedoraEntry: LinuxImageCatalogEntry {
        makeLinuxCatalogEntry(
            id: "fedora-workstation-44",
            distribution: "Fedora Workstation",
            version: "44",
            directoryURLString:
                "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Workstation/aarch64/iso/",
            isoPattern: "Fedora-Workstation-Live-44-*.aarch64.iso",
            manifestDirectoryURLString:
                "https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Workstation/aarch64/iso/",
            checksumManifest: "Fedora-Workstation-44-1.7-aarch64-CHECKSUM"
        )
    }

    /// Serves `manifest` for anything that is not an ISO, and answers a HEAD for
    /// the ISO with `isoSize`.
    private func serve(manifest: String, manifestStatus: Int = 200, isoSize: Int = 3_540_299_776) {
        ResolveStubURLProtocol.reset()
        ResolveStubURLProtocol.handler = { request in
            guard request.url?.lastPathComponent.hasSuffix(".iso") == true else {
                return ResolveStubURLProtocol.Reply(
                    statusCode: manifestStatus, body: Data(manifest.utf8))
            }
            return ResolveStubURLProtocol.Reply(
                statusCode: 200, body: Data(), headers: ["Content-Length": "\(isoSize)"])
        }
    }

    /// A hand-built entry the catalog would have refused, standing in for one
    /// edited into a VM's `config.json` after the picker wrote it.
    private func editedEntry(
        directoryURLString: String = "https://cdimage.ubuntu.com/ubuntu/releases/noble/release/",
        isoPattern: String = "ubuntu-24.04*-desktop-arm64.iso",
        manifestDirectoryURLString: String? = nil,
        checksumManifest: String = "SHA256SUMS"
    ) -> LinuxImageCatalogEntry {
        makeLinuxCatalogEntry(
            id: "ubuntu-desktop-24.04",
            directoryURLString: directoryURLString,
            isoPattern: isoPattern,
            manifestDirectoryURLString: manifestDirectoryURLString,
            checksumManifest: checksumManifest
        )
    }

    @Test("A directory that is not HTTPS is refused before anything is requested")
    func refusesInsecureDirectory() async throws {
        serve(manifest: ubuntuManifest)
        defer { ResolveStubURLProtocol.reset() }
        let entry = editedEntry(
            directoryURLString: "http://cdimage.ubuntu.com/ubuntu/releases/noble/release/")

        await #expect(throws: LinuxImageResolveError.insecureDirectory(url: entry.directoryURL)) {
            _ = try await makeService().resolve(entry)
        }
        #expect(ResolveStubURLProtocol.requestedURLs.isEmpty)
    }

    @Test("An ISO pattern that is not a wildcard .iso filename is refused before any request")
    func refusesInvalidISOPattern() async throws {
        serve(manifest: ubuntuManifest)
        defer { ResolveStubURLProtocol.reset() }

        await #expect(
            throws: LinuxImageResolveError.invalidISOPattern(pattern: "../*.iso")
        ) {
            _ = try await makeService().resolve(editedEntry(isoPattern: "../*.iso"))
        }
        #expect(ResolveStubURLProtocol.requestedURLs.isEmpty)
    }

    @Test("A manifest directory that is not HTTPS is refused before anything is requested")
    func refusesInsecureManifestDirectory() async throws {
        serve(manifest: ubuntuManifest)
        defer { ResolveStubURLProtocol.reset() }
        let entry = editedEntry(
            manifestDirectoryURLString: "http://dl.fedoraproject.org/pub/fedora/")

        await #expect(
            throws: LinuxImageResolveError.insecureDirectory(url: entry.manifestDirectory)
        ) {
            _ = try await makeService().resolve(entry)
        }
        #expect(ResolveStubURLProtocol.requestedURLs.isEmpty)
    }

    @Test("A checksum manifest that is not a filename is refused before any request")
    func refusesInvalidManifestName() async throws {
        serve(manifest: ubuntuManifest)
        defer { ResolveStubURLProtocol.reset() }

        await #expect(
            throws: LinuxImageResolveError.invalidManifestName(manifest: "../../etc/passwd")
        ) {
            _ = try await makeService().resolve(editedEntry(checksumManifest: "../../etc/passwd"))
        }
        #expect(ResolveStubURLProtocol.requestedURLs.isEmpty)
    }

    @Test("The newest match in the manifest becomes the image, with its digest and size")
    func resolvesUbuntuManifest() async throws {
        serve(manifest: ubuntuManifest)
        defer { ResolveStubURLProtocol.reset() }

        let image = try await makeService().resolve(ubuntuEntry)

        #expect(image.filename == "ubuntu-24.04.4-desktop-arm64.iso")
        // The mirror names the image; it does not name the file that image is
        // written to, which carries a suffix unique to the URL resolved.
        #expect(image.destinationFilename != image.filename)
        #expect(image.destinationFilename.hasPrefix("ubuntu-24.04.4-desktop-arm64-"))
        #expect(image.destinationFilename.hasSuffix(".iso"))
        #expect(
            image.sha256 == "0be6df929cb47d4f188ab94d1fdedc75aa947d1fe7d4a17fb70f65c130699a44")
        #expect(
            image.isoURL.absoluteString
                == "https://cdimage.ubuntu.com/ubuntu/releases/noble/release/ubuntu-24.04.4-desktop-arm64.iso"
        )
        #expect(image.sizeBytes == 3_540_299_776)
        // The manifest is fetched by name from the entry's own directory — no
        // directory listing is read on the way there.
        #expect(
            ResolveStubURLProtocol.requestedURLs.first?.absoluteString
                == "https://cdimage.ubuntu.com/ubuntu/releases/noble/release/SHA256SUMS")
    }

    @Test("A clearsigned BSD manifest resolves the same way")
    func resolvesFedoraManifest() async throws {
        serve(manifest: fedoraManifest, isoSize: 2_689_781_760)
        defer { ResolveStubURLProtocol.reset() }

        let image = try await makeService().resolve(fedoraEntry)

        #expect(image.filename == "Fedora-Workstation-Live-44-1.7.aarch64.iso")
        #expect(
            image.sha256 == "66c07e7355db5e92faef680599a1789184a31c4dbaa5e02a19d050cc4e9279d2")
        #expect(image.sizeBytes == 2_689_781_760)
    }

    @Test("The manifest is read from the entry's manifest host, the ISO from its download host")
    func readsManifestFromItsPinnedHost() async throws {
        serve(manifest: fedoraManifest, isoSize: 2_689_781_760)
        defer { ResolveStubURLProtocol.reset() }

        let image = try await makeService().resolve(fedoraEntry)

        #expect(
            ResolveStubURLProtocol.requestedURLs.first?.absoluteString
                == "https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Workstation/aarch64/iso/Fedora-Workstation-44-1.7-aarch64-CHECKSUM"
        )
        #expect(image.isoURL.host() == "download.fedoraproject.org")
    }

    @Test("A redirect off the manifest's host is refused, and its target never requested")
    func refusesOffHostManifestRedirect() async {
        ResolveStubURLProtocol.reset()
        ResolveStubURLProtocol.handler = { request in
            guard request.url?.host() == "cdimage.ubuntu.com" else {
                return ResolveStubURLProtocol.Reply(
                    statusCode: 200, body: Data(ubuntuManifest.utf8))
            }
            return ResolveStubURLProtocol.Reply(
                statusCode: 302, body: Data(),
                headers: ["Location": "https://mirror.example/noble/SHA256SUMS"])
        }
        defer { ResolveStubURLProtocol.reset() }

        await #expect(
            throws: LinuxImageResolveError.manifestRedirected(
                manifest: "SHA256SUMS", host: "mirror.example")
        ) {
            _ = try await makeService().resolve(ubuntuEntry)
        }
        // The digest would have come from whatever answered, so the mirror is
        // not asked at all rather than asked and disbelieved.
        #expect(
            ResolveStubURLProtocol.requestedURLs.allSatisfy { $0.host() == "cdimage.ubuntu.com" })
    }

    @Test("A redirect staying on the manifest's host is followed")
    func followsSameHostManifestRedirect() async throws {
        let moved = "https://cdimage.ubuntu.com/ubuntu/releases/noble/release/SHA256SUMS.txt"
        ResolveStubURLProtocol.reset()
        ResolveStubURLProtocol.handler = { request in
            guard let url = request.url else {
                return ResolveStubURLProtocol.Reply(statusCode: 500, body: Data())
            }
            guard !url.lastPathComponent.hasSuffix(".iso") else {
                return ResolveStubURLProtocol.Reply(
                    statusCode: 200, body: Data(), headers: ["Content-Length": "3540299776"])
            }
            guard url.lastPathComponent == "SHA256SUMS" else {
                return ResolveStubURLProtocol.Reply(
                    statusCode: 200, body: Data(ubuntuManifest.utf8))
            }
            return ResolveStubURLProtocol.Reply(
                statusCode: 302, body: Data(), headers: ["Location": moved])
        }
        defer { ResolveStubURLProtocol.reset() }

        let image = try await makeService().resolve(ubuntuEntry)

        #expect(image.filename == "ubuntu-24.04.4-desktop-arm64.iso")
        #expect(ResolveStubURLProtocol.requestedURLs.map(\.absoluteString).contains(moved))
    }

    @Test("A manifest the mirror does not serve is reported with its status")
    func refusesUnservedManifest() async {
        serve(manifest: "Not Found", manifestStatus: 404)
        defer { ResolveStubURLProtocol.reset() }

        await #expect(
            throws: LinuxImageResolveError.manifestUnreachable(
                manifest: "SHA256SUMS", statusCode: 404)
        ) {
            _ = try await makeService().resolve(ubuntuEntry)
        }
    }

    @Test("A body carrying no checksum at all is refused rather than searched")
    func refusesUnparseableManifest() async {
        serve(manifest: "<html><body>Index of /ubuntu/releases/noble/release/</body></html>")
        defer { ResolveStubURLProtocol.reset() }

        await #expect(
            throws: LinuxImageResolveError.manifestUnparseable(manifest: "SHA256SUMS")
        ) {
            _ = try await makeService().resolve(ubuntuEntry)
        }
    }

    @Test("A manifest that keeps arriving past the cap is dropped, not parsed")
    func refusesOversizedManifest() async {
        // A valid line first, so what fails is the size and not the parse.
        serve(manifest: ubuntuManifest + "\n" + String(repeating: "A", count: 1024 * 1024))
        defer { ResolveStubURLProtocol.reset() }

        await #expect(throws: LinuxImageResolveError.manifestTooLarge(manifest: "SHA256SUMS")) {
            _ = try await makeService().resolve(ubuntuEntry)
        }
    }

    @Test("A manifest listing nothing the pattern matches resolves to no image")
    func refusesWhenNothingMatches() async {
        serve(
            manifest: """
                416d362ba65a37644ca3f8ab7f920257d8c84d965dee0f0a56dea2ea5ec1ff2e *ubuntu-24.04.4-live-server-arm64+largemem.iso
                eeffbfb8009ede3f363606b38c2889ea4ba2f174d50b6c5bab555004336e2904 *ubuntu-24.04.4-live-server-arm64.iso
                """)
        defer { ResolveStubURLProtocol.reset() }

        await #expect(
            throws: LinuxImageResolveError.noMatchingImage(
                pattern: "ubuntu-24.04*-desktop-arm64.iso")
        ) {
            _ = try await makeService().resolve(ubuntuEntry)
        }
    }

    @Test("A filename that could not be saved is refused before it reaches a path")
    func refusesUnusableFilename() async {
        serve(
            manifest:
                "93b805a2e39d472e51117ac4ac21b1110f05d4c5365ae4b90d23f5e4e44e53f9  .hidden.iso")
        defer { ResolveStubURLProtocol.reset() }

        var entry = ubuntuEntry
        entry.isoPattern = "*.iso"

        await #expect(throws: LinuxImageResolveError.unusableFilename(".hidden.iso")) {
            _ = try await makeService().resolve(entry)
        }
    }

    @Test("A mirror that will not state the ISO's size resolves to nothing")
    func refusesWhenSizeIsUnavailable() async {
        ResolveStubURLProtocol.reset()
        ResolveStubURLProtocol.handler = { request in
            guard request.url?.lastPathComponent.hasSuffix(".iso") == true else {
                return ResolveStubURLProtocol.Reply(
                    statusCode: 200, body: Data(ubuntuManifest.utf8))
            }
            // HEAD refused, and the ranged GET fallback fails too.
            return ResolveStubURLProtocol.Reply(
                statusCode: request.httpMethod == "HEAD" ? 405 : 500, body: Data())
        }
        defer { ResolveStubURLProtocol.reset() }

        await #expect(
            throws: LinuxImageResolveError.sizeUnavailable(
                filename: "ubuntu-24.04.4-desktop-arm64.iso")
        ) {
            _ = try await makeService().resolve(ubuntuEntry)
        }
    }

    @Test("The size is read off the resolved ISO, falling back to a ranged GET")
    func readsSizeThroughRangedGetWhenHeadIsRefused() async throws {
        ResolveStubURLProtocol.reset()
        ResolveStubURLProtocol.handler = { request in
            guard request.url?.lastPathComponent.hasSuffix(".iso") == true else {
                return ResolveStubURLProtocol.Reply(
                    statusCode: 200, body: Data(ubuntuManifest.utf8))
            }
            guard request.httpMethod != "HEAD" else {
                return ResolveStubURLProtocol.Reply(statusCode: 403, body: Data())
            }
            return ResolveStubURLProtocol.Reply(
                statusCode: 206, body: Data([0x00]),
                headers: ["Content-Range": "bytes 0-0/3540299776"])
        }
        defer { ResolveStubURLProtocol.reset() }

        let image = try await makeService().resolve(ubuntuEntry)

        #expect(image.sizeBytes == 3_540_299_776)
        #expect(
            ResolveStubURLProtocol.requestedURLs.last?.lastPathComponent
                == "ubuntu-24.04.4-desktop-arm64.iso")
    }

    // MARK: - A user-supplied URL

    /// Answers every request with `statusCode` and a stated `size`.
    private func serveISO(statusCode: Int = 200, size: Int = 1_073_741_824) {
        ResolveStubURLProtocol.reset()
        ResolveStubURLProtocol.handler = { _ in
            ResolveStubURLProtocol.Reply(
                statusCode: statusCode, body: Data(), headers: ["Content-Length": "\(size)"])
        }
    }

    @Test("A pasted URL resolves to itself, its filename and the size the server states")
    func resolvesPastedURL() async throws {
        serveISO()
        defer { ResolveStubURLProtocol.reset() }
        let digest = String(repeating: "a", count: 64)
        let pasted = try CustomLinuxImage.make(
            urlText: "https://mirror.example/alpine-3.22-aarch64.iso", checksumText: digest)

        let image = try await makeService().resolve(pasted)

        #expect(image.isoURL == pasted.url)
        #expect(image.filename == "alpine-3.22-aarch64.iso")
        // The destination is unique to the URL, so it can never land on a file
        // the user happens to already have under the link's own name.
        #expect(image.destinationFilename != image.filename)
        #expect(image.destinationFilename.hasPrefix("alpine-3.22-aarch64-"))
        #expect(image.destinationFilename.hasSuffix(".iso"))
        #expect(image.sha256 == digest)
        #expect(image.sizeBytes == 1_073_741_824)
        // No manifest is read: the URL names the file outright.
        #expect(ResolveStubURLProtocol.requestedURLs.allSatisfy { $0 == pasted.url })
    }

    @Test("A pasted URL with no checksum resolves with nothing to verify against")
    func resolvesUnverifiedPastedURL() async throws {
        serveISO()
        defer { ResolveStubURLProtocol.reset() }

        let image = try await makeService().resolve(
            try CustomLinuxImage.make(
                urlText: "https://mirror.example/alpine-3.22-aarch64.iso", checksumText: ""))

        #expect(image.sha256 == nil)
    }

    @Test("A plain-HTTP URL is refused before anything is requested")
    func refusesHTTPPastedURL() async {
        serveISO()
        defer { ResolveStubURLProtocol.reset() }
        let url = URL(string: "http://mirror.example/alpine-3.22-aarch64.iso")!

        // A checksum buys no admission: ATS would refuse the load anyway, and
        // the stub here would otherwise hide that.
        await #expect(throws: LinuxImageURLError.insecureURL) {
            _ = try await makeService().resolve(
                CustomLinuxImage(url: url, sha256: String(repeating: "b", count: 64)))
        }
        await #expect(throws: LinuxImageURLError.insecureURL) {
            _ = try await makeService().resolve(CustomLinuxImage(url: url, sha256: nil))
        }
        #expect(ResolveStubURLProtocol.requestedURLs.isEmpty)
    }

    @Test("A URL nothing is hosted at is reported with its status")
    func reportsUnreachablePastedURL() async {
        serveISO(statusCode: 404)
        defer { ResolveStubURLProtocol.reset() }

        await #expect(throws: LinuxImageURLError.unreachable(statusCode: 404)) {
            _ = try await makeService().resolve(
                CustomLinuxImage(
                    url: URL(string: "https://mirror.example/alpine-3.22-aarch64.iso")!,
                    sha256: nil))
        }
    }

    @Test("A server that states no size leaves the transfer unbounded, so it is refused")
    func refusesPastedURLWithoutSize() async {
        ResolveStubURLProtocol.reset()
        ResolveStubURLProtocol.handler = { request in
            // HEAD refused, and the ranged GET answers 200 — the whole file,
            // which is neither a size nor something to read.
            ResolveStubURLProtocol.Reply(
                statusCode: request.httpMethod == "HEAD" ? 405 : 200, body: Data())
        }
        defer { ResolveStubURLProtocol.reset() }

        await #expect(throws: LinuxImageURLError.sizeUnavailable) {
            _ = try await makeService().resolve(
                CustomLinuxImage(
                    url: URL(string: "https://mirror.example/alpine-3.22-aarch64.iso")!,
                    sha256: nil))
        }
    }
}
