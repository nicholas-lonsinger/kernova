import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("ProbedRestoreImage Tests")
struct ProbedRestoreImageTests {
    private func host(_ major: Int, _ minor: Int, _ patch: Int) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
    }

    @Test("Apple's filename convention yields version and build")
    func parsesAppleFilename() {
        let parsed = ProbedRestoreImage.parseFilename("UniversalMac_15.6.1_24G90_Restore.ipsw")
        #expect(parsed.version == "15.6.1")
        #expect(parsed.build == "24G90")
    }

    @Test("A two-component version parses too")
    func parsesTwoComponentVersion() {
        let parsed = ProbedRestoreImage.parseFilename("UniversalMac_26.6_25G72_Restore.ipsw")
        #expect(parsed.version == "26.6")
        #expect(parsed.build == "25G72")
    }

    @Test("Anything off-convention yields no guess")
    func rejectsOffConventionFilenames() {
        for filename in [
            "restore.ipsw",
            "UniversalMac_15.6.1_Restore.ipsw",
            "UniversalMac_15.6.1_24G90_Restore.zip",
            "SomethingElse_15.6.1_24G90_Restore.ipsw",
            "UniversalMac_Sequoia_24G90_Restore.ipsw",
            "UniversalMac__24G90_Restore.ipsw",
            "UniversalMac_15.6.1_24-G90_Restore.ipsw",
        ] {
            let parsed = ProbedRestoreImage.parseFilename(filename)
            #expect(parsed.version == nil, "expected no version from '\(filename)'")
            #expect(parsed.build == nil, "expected no build from '\(filename)'")
        }
    }

    @Test("The destination is Apple's filename when the URL follows the convention")
    func suggestedFilename() {
        #expect(
            makeProbedImage().suggestedFilename == "UniversalMac_15.6.1_24G90_Restore.ipsw")
    }

    @Test("An off-convention URL gets a generated name, never the shared default")
    func suggestedFilenameForOffConventionURL() {
        for urlString in [
            "https://example.com/downloads/",
            "https://example.com/image.zip",
            "https://example.com/restore.ipsw",
        ] {
            let filename = makeProbedImage(urlString: urlString).suggestedFilename
            #expect(filename.hasSuffix(".ipsw"), "expected an .ipsw name from '\(urlString)'")
            // "Download Latest" owns that name; sharing it would let its image
            // satisfy this one's download.
            #expect(filename != RestoreImageFilename.fallback)
        }
    }

    @Test("Two different images never resolve to the same destination")
    func destinationsAreDistinct() {
        let first = makeProbedImage(
            urlString: "https://a.example.com/UniversalMac_15.6.1_24G90_Restore.ipsw")
        let second = makeProbedImage(
            urlString: "https://b.example.com/UniversalMac_26.6_25G72_Restore.ipsw")
        #expect(first.suggestedFilename != second.suggestedFilename)
    }

    @Test("Two URLs sharing a basename resolve to different destinations")
    func offConventionDestinationsAreDistinctPerURL() {
        let first = makeProbedImage(urlString: "https://a.example.com/restore.ipsw")
        let second = makeProbedImage(urlString: "https://b.example.com/restore.ipsw")
        #expect(first.suggestedFilename != second.suggestedFilename)
        // Stable, so the same URL resumes into the file it started.
        #expect(
            first.suggestedFilename
                == makeProbedImage(urlString: "https://a.example.com/restore.ipsw")
                .suggestedFilename)
    }

    @Test("A URL whose filename escapes its directory is never used as one")
    func suggestedFilenameRefusesTraversal() {
        // `lastPathComponent` percent-decodes, so this arrives as
        // `a/../../evil.ipsw` and would land two directories above Downloads.
        let image = makeProbedImage(urlString: "https://host/a%2F..%2F..%2Fevil.ipsw")
        #expect(image.url.lastPathComponent == "a/../../evil.ipsw")
        #expect(!image.suggestedFilename.contains("/"))
        #expect(!image.suggestedFilename.contains(".."))
    }

    @Test("Host support is unknown when the filename named no version")
    func hostSupportUnknownWithoutVersion() {
        let image = makeProbedImage(version: nil, build: nil)
        #expect(image.isSupported(onHost: host(26, 0, 0)) == nil)
    }

    @Test("An unparseable version is unknown too, not a refusal")
    func hostSupportUnknownForUnparseableVersion() {
        #expect(makeProbedImage(version: "Sequoia").isSupported(onHost: host(26, 0, 0)) == nil)
    }

    @Test("Host support compares numerically at the boundary")
    func hostSupportBoundary() {
        let image = makeProbedImage(version: "15.6.1")
        #expect(image.isSupported(onHost: host(15, 6, 1)) == true)
        #expect(image.isSupported(onHost: host(15, 6, 0)) == false)
        #expect(image.isSupported(onHost: host(26, 0, 0)) == true)
    }

    @Test("The version summary degrades to what is actually known")
    func versionSummaryDegrades() {
        #expect(makeProbedImage().versionSummary == "macOS 15.6.1 (24G90)")
        #expect(makeProbedImage(build: nil).versionSummary == "macOS 15.6.1")
        #expect(makeProbedImage(version: nil).versionSummary == "Build 24G90")
        #expect(
            makeProbedImage(version: nil, build: nil).versionSummary == "Unrecognized version")
    }
}

@Suite("LatestRestoreImage Tests")
struct LatestRestoreImageTests {
    @Test("The destination is Apple's filename for the URL the lookup returned")
    func suggestedFilename() {
        #expect(
            makeLatestImage(version: "26.5.2", build: "25F84").suggestedFilename
                == "UniversalMac_26.5.2_25F84_Restore.ipsw")
    }

    @Test("An off-convention URL gets a generated name, never the shared fallback")
    func suggestedFilenameForOffConventionURL() {
        let image = makeLatestImage(urlString: "https://example.com/restore.ipsw")
        #expect(image.suggestedFilename.hasSuffix(".ipsw"))
        #expect(image.suggestedFilename != RestoreImageFilename.fallback)
    }
}

@Suite("RestoreImageFilename Tests")
struct RestoreImageFilenameTests {
    @Test("A plain .ipsw filename passes through")
    func acceptsPlainFilename() {
        #expect(
            RestoreImageFilename.sanitized("UniversalMac_15.6.1_24G90_Restore.ipsw")
                == "UniversalMac_15.6.1_24G90_Restore.ipsw")
        #expect(RestoreImageFilename.sanitized("restore.IPSW") == "restore.IPSW")
    }

    @Test(
        "Anything that is not one visible .ipsw component is refused",
        arguments: [
            "",
            ".",
            "..",
            "/",
            "a/../../evil.ipsw",
            "../evil.ipsw",
            "sub/dir/image.ipsw",
            ".hidden.ipsw",
            ".ipsw",
            "image.zip",
            "a%2F..%2Fevil.ipsw",
        ])
    func refusesUnsafeCandidates(candidate: String) {
        #expect(RestoreImageFilename.sanitized(candidate) == nil)
    }

    @Test("A generated name is one visible .ipsw component, whatever the URL")
    func generatedNamesAreSafeComponents() throws {
        for urlString in [
            "https://host/a%2F..%2F..%2Fevil.ipsw",
            "https://host/",
            "https://host",
            "https://host/.hidden.ipsw",
            "https://host/\(String(repeating: "n", count: 400)).ipsw",
        ] {
            let url = try #require(URL(string: urlString))
            let generated = RestoreImageFilename.unique(for: url)
            #expect(RestoreImageFilename.sanitized(generated) == generated, "from '\(urlString)'")
            #expect(generated.utf8.count < 255)
        }
    }
}

@Suite("MacOSVersion Tests")
struct MacOSVersionTests {
    @Test("What KernovaOSVersion renders is what the catalog's own version strings parse as")
    func displayStringRoundTripsThroughTheParser() {
        let rendered = KernovaOSVersion.displayString(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 2))
        #expect(MacOSVersion(rendered)?.components == [26, 5, 2])
    }
}

/// Stub for the probe's requests.
///
/// Deliberately its own class rather than `StubURLProtocol`: that one's handler
/// is a global, and Swift Testing runs suites in parallel, so sharing it lets
/// this suite and `IPSWServiceDownloadTests` clobber each other's handler.
/// `.serialized` orders tests *within* a suite and does not prevent that.
final class ProbeStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var statusCode: Int
        var body: Data
        var headers: [String: String]
        /// Delivers `bodyPrimerBytes` and holds the rest back until the client
        /// cancels, separating a client that read only the status from one that
        /// consumed the response.
        ///
        /// The primer is not optional: CFNetwork surfaces a response only once
        /// its body starts arriving, so a wholly withheld body means the client
        /// never sees a status to react to. A client that never cancels gets the
        /// rest once `testWaitBackstop` elapses, and `deliveredBodyBytes`
        /// records every byte handed over either way.
        var withholdsBodyUntilCancelled = false
    }

    /// How much of a withheld body is delivered to surface the response.
    static let bodyPrimerBytes = 1024

    nonisolated(unsafe) static var handler: ((URLRequest) -> Reply)?

    private static let recordLock = NSLock()
    nonisolated(unsafe) private static var deliveredBodyBytesStorage = 0
    nonisolated(unsafe) private static var requestedRangesStorage: [String] = []

    /// Body bytes handed to a client since the last `reset()`.
    static var deliveredBodyBytes: Int { recordLock.withLock { deliveredBodyBytesStorage } }

    /// Every `Range` header value the stub was asked for since the last `reset()`.
    static var requestedRanges: [String] { recordLock.withLock { requestedRangesStorage } }

    /// Clears the handler and everything recorded about the requests it served.
    static func reset() {
        handler = nil
        recordLock.withLock {
            deliveredBodyBytesStorage = 0
            requestedRangesStorage = []
        }
    }

    private let cancelled = DispatchSemaphore(value: 0)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: "ProbeStubURLProtocol", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No handler set"]))
            return
        }
        if let range = request.value(forHTTPHeaderField: "Range") {
            Self.recordLock.withLock { Self.requestedRangesStorage.append(range) }
        }
        let reply = handler(request)
        var headers = reply.headers
        if headers["Content-Length"] == nil { headers["Content-Length"] = "\(reply.body.count)" }
        guard
            let response = HTTPURLResponse(
                url: url, statusCode: reply.statusCode, httpVersion: "HTTP/1.1",
                headerFields: headers)
        else {
            preconditionFailure("ProbeStubURLProtocol: could not build a response")
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard reply.withholdsBodyUntilCancelled else {
            deliver(reply.body)
            return
        }
        // On a GCD thread, never the cooperative pool: this parks until the
        // client cancels, and `stopLoading` has to be free to run meanwhile.
        // The primer belongs here rather than above because nothing handed to
        // the client reaches it until `startLoading` has returned.
        DispatchQueue.global().async { [self] in
            deliver(reply.body.prefix(Self.bodyPrimerBytes), finishing: false)
            let backstop =
                DispatchTime.now() + .seconds(Int(testWaitBackstop.components.seconds))
            guard cancelled.wait(timeout: backstop) == .timedOut else { return }
            deliver(reply.body.dropFirst(Self.bodyPrimerBytes))
        }
    }

    override func stopLoading() {
        cancelled.signal()
    }

    private func deliver(_ body: Data, finishing: Bool = true) {
        if !body.isEmpty {
            Self.recordLock.withLock { Self.deliveredBodyBytesStorage += body.count }
            client?.urlProtocol(self, didLoad: body)
        }
        if finishing { client?.urlProtocolDidFinishLoading(self) }
    }
}

/// Which remote-controlled zip64 value a test poisons.
enum PoisonedZip64Field: Sendable {
    case locatorOffset
    case unrepresentableSize
    case unrepresentableOffset
    case sizeBeyondEndOfFile
}

@Suite("RestoreImageProbeService Tests", .serialized)
struct RestoreImageProbeServiceTests {
    private func makeService() -> RestoreImageProbeService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses =
            [ProbeStubURLProtocol.self] + (configuration.protocolClasses ?? [])
        return RestoreImageProbeService(sessionConfiguration: configuration)
    }

    private var imageURL: URL {
        URL(string: "https://updates.cdn-apple.com/x/UniversalMac_15.6.1_24G90_Restore.ipsw")
            ?? URL(fileURLWithPath: "/")
    }

    private func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    /// A central directory naming one member, `vma2` or not — the only thing the
    /// probe reads out of it.
    private func makeCentralDirectory(containsVMA2: Bool) -> Data {
        var directory = Data()
        directory.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])  // central file header
        let name = containsVMA2 ? "kernelcache.release.vma2" : "kernelcache.release.im4p"
        directory.append(contentsOf: Array(name.utf8))
        return directory
    }

    /// Builds the tail of a zip whose central directory does or doesn't name a
    /// `vma2` member.
    ///
    /// Laid out so the directory sits immediately before the end-of-directory
    /// record, and the whole thing is served as one blob: the probe's tail read
    /// covers it, and the zip64 locator is deliberately absent so the 32-bit
    /// fields are authoritative.
    private func makeZipTail(containsVMA2: Bool) -> Data {
        let directory = makeCentralDirectory(containsVMA2: containsVMA2)
        var blob = directory

        var eocd = Data()
        eocd.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])  // EOCD signature
        eocd.append(contentsOf: [0, 0, 0, 0])  // disk numbers
        eocd.append(contentsOf: [1, 0, 1, 0])  // entry counts
        appendLE(UInt32(directory.count), to: &eocd)
        appendLE(UInt32(0), to: &eocd)  // offset
        eocd.append(contentsOf: [0, 0])  // comment length
        blob.append(eocd)
        return blob
    }

    /// Builds the tail of a zip64, where the locator and the record it points at
    /// carry the authoritative central-directory bounds.
    ///
    /// Every parameter overriding a value the record would otherwise state
    /// honestly stands in for a hostile or broken server. `totalBytes` is the
    /// length of the file the tail belongs to, which is what the recorded
    /// offsets are relative to; it defaults to the tail standing alone.
    private func makeZip64Tail(
        containsVMA2: Bool = true,
        totalBytes: Int? = nil,
        directorySize: UInt64? = nil,
        directoryOffset: UInt64? = nil,
        locatorOffset: UInt64? = nil
    ) -> Data {
        let directory = makeCentralDirectory(containsVMA2: containsVMA2)
        // Fixed lengths: zip64 EOCD record, zip64 locator, EOCD.
        let blobLength = directory.count + 56 + 20 + 22
        let blobStart = UInt64((totalBytes ?? blobLength) - blobLength)
        let recordStart = blobStart + UInt64(directory.count)

        var record = Data()
        record.append(contentsOf: [0x50, 0x4B, 0x06, 0x06])  // zip64 EOCD signature
        appendLE(UInt64(44), to: &record)  // record size, excluding these 12 bytes
        appendLE(UInt16(45), to: &record)  // version made by
        appendLE(UInt16(45), to: &record)  // version needed
        appendLE(UInt32(0), to: &record)  // this disk
        appendLE(UInt32(0), to: &record)  // disk with the directory
        appendLE(UInt64(1), to: &record)  // entries on this disk
        appendLE(UInt64(1), to: &record)  // entries total
        appendLE(directorySize ?? UInt64(directory.count), to: &record)
        appendLE(directoryOffset ?? blobStart, to: &record)

        var locator = Data()
        locator.append(contentsOf: [0x50, 0x4B, 0x06, 0x07])  // zip64 locator signature
        appendLE(UInt32(0), to: &locator)  // disk with the zip64 EOCD
        appendLE(locatorOffset ?? recordStart, to: &locator)
        appendLE(UInt32(1), to: &locator)  // disks total

        var eocd = Data()
        eocd.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])  // EOCD signature
        eocd.append(contentsOf: [0, 0, 0, 0])  // disk numbers
        eocd.append(contentsOf: [1, 0, 1, 0])  // entry counts
        appendLE(UInt32.max, to: &eocd)  // size: zip64 sentinel
        appendLE(UInt32.max, to: &eocd)  // offset: zip64 sentinel
        eocd.append(contentsOf: [0, 0])  // comment length

        let blob = directory + record + locator + eocd
        #expect(blob.count == blobLength, "zip64 tail layout drifted from its declared lengths")
        return blob
    }

    /// The number of bytes a `bytes=first-last` header asks for.
    private func rangeLength(_ header: String) -> Int? {
        guard let spec = header.split(separator: "=").last else { return nil }
        let bounds = spec.split(separator: "-")
        guard bounds.count == 2, let first = Int(bounds[0]), let last = Int(bounds[1]) else {
            return nil
        }
        return last - first + 1
    }

    /// Serves `body` for every request, answering HEAD with the declared total
    /// and range requests out of the same bytes.
    private func serve(total: Int, body: Data, headStatus: Int = 200) {
        ProbeStubURLProtocol.reset()
        ProbeStubURLProtocol.handler = { request in
            if request.httpMethod == "HEAD" {
                return ProbeStubURLProtocol.Reply(
                    statusCode: headStatus, body: Data(),
                    headers: ["Content-Length": "\(total)"])
            }
            guard let header = request.value(forHTTPHeaderField: "Range"),
                let spec = header.split(separator: "=").last
            else {
                return ProbeStubURLProtocol.Reply(statusCode: 200, body: body, headers: [:])
            }
            let bounds = spec.split(separator: "-")
            let start = Int(bounds.first ?? "0") ?? 0
            let end = bounds.count > 1 ? (Int(bounds[1]) ?? total - 1) : total - 1
            // The stub's body represents the file's tail, so a range that starts
            // inside it is served from the corresponding offset.
            let bodyStart = total - body.count
            let lower = max(0, start - bodyStart)
            let upper = min(body.count, end - bodyStart + 1)
            let slice = lower < upper ? body.subdata(in: lower..<upper) : Data()
            return ProbeStubURLProtocol.Reply(
                statusCode: 206, body: slice,
                headers: ["Content-Range": "bytes \(start)-\(end)/\(total)"])
        }
    }

    @Test("An image carrying the VM hardware model is accepted")
    func acceptsVirtualMachineImage() async throws {
        let tail = makeZipTail(containsVMA2: true)
        serve(total: tail.count, body: tail)
        defer { ProbeStubURLProtocol.reset() }

        let image = try await makeService().probe(imageURL)

        #expect(image.sizeBytes == UInt64(tail.count))
        #expect(image.version == "15.6.1")
        #expect(image.build == "24G90")
        #expect(image.url == imageURL)
    }

    @Test("The size alone is read without touching the image's structure")
    func sizeReadsOnlyTheLength() async throws {
        // No zip structure at all: a size read must not depend on one, which is
        // what lets it serve an image Virtualization already vouched for.
        serve(total: 19_772_077_142, body: Data())
        defer { ProbeStubURLProtocol.reset() }

        #expect(try await makeService().size(of: imageURL) == 19_772_077_142)
    }

    @Test("An image with no VM hardware model is refused")
    func refusesImageWithoutVirtualMachineModel() async {
        let tail = makeZipTail(containsVMA2: false)
        serve(total: tail.count, body: tail)
        defer { ProbeStubURLProtocol.reset() }

        await #expect(throws: RestoreImageProbeError.notAVirtualMachineImage) {
            _ = try await makeService().probe(imageURL)
        }
    }

    @Test("A non-HTTPS URL is refused before any request")
    func refusesInsecureURL() async throws {
        let http = try #require(URL(string: "http://updates.cdn-apple.com/x/R.ipsw"))
        ProbeStubURLProtocol.handler = { _ in
            Issue.record("The probe issued a request for a non-HTTPS URL")
            return ProbeStubURLProtocol.Reply(statusCode: 200, body: Data(), headers: [:])
        }
        defer { ProbeStubURLProtocol.reset() }

        await #expect(throws: RestoreImageProbeError.insecureURL) {
            _ = try await makeService().probe(http)
        }
    }

    @Test("The size read refuses a non-HTTPS URL before any request too")
    func sizeRefusesInsecureURL() async throws {
        let http = try #require(URL(string: "http://updates.cdn-apple.com/x/R.ipsw"))
        ProbeStubURLProtocol.reset()
        ProbeStubURLProtocol.handler = { _ in
            Issue.record("The size read issued a request for a non-HTTPS URL")
            return ProbeStubURLProtocol.Reply(statusCode: 200, body: Data(), headers: [:])
        }
        defer { ProbeStubURLProtocol.reset() }

        await #expect(throws: RestoreImageProbeError.insecureURL) {
            _ = try await makeService().size(of: http)
        }
    }

    @Test("A server stating a length of zero is refused, not reported as a size")
    func refusesZeroLength() async {
        ProbeStubURLProtocol.reset()
        ProbeStubURLProtocol.handler = { request in
            if request.httpMethod == "HEAD" {
                return ProbeStubURLProtocol.Reply(
                    statusCode: 200, body: Data(), headers: ["Content-Length": "0"])
            }
            return ProbeStubURLProtocol.Reply(
                statusCode: 206, body: Data([0x00]),
                headers: ["Content-Range": "bytes 0-0/0"])
        }
        defer { ProbeStubURLProtocol.reset() }

        // Both entry points, since a zero reaching either one would be formatted
        // as a download size.
        await #expect(throws: RestoreImageProbeError.unknownSize) {
            _ = try await makeService().size(of: imageURL)
        }
        await #expect(throws: RestoreImageProbeError.unknownSize) {
            _ = try await makeService().probe(imageURL)
        }
    }

    @Test("A URL that answers nothing but 404 is refused with its status")
    func refusesMissingImage() async {
        ProbeStubURLProtocol.reset()
        ProbeStubURLProtocol.handler = { _ in
            ProbeStubURLProtocol.Reply(statusCode: 404, body: Data(), headers: [:])
        }
        defer { ProbeStubURLProtocol.reset() }

        await #expect(throws: RestoreImageProbeError.unreachable(statusCode: 404)) {
            _ = try await makeService().probe(imageURL)
        }
    }

    @Test(
        "A server that refuses HEAD is probed with ranged GETs instead",
        arguments: [403, 405, 501])
    func fallsBackToRangedGetWhenHeadIsRefused(headStatus: Int) async throws {
        let tail = makeZipTail(containsVMA2: true)
        serve(total: tail.count, body: tail, headStatus: headStatus)
        defer { ProbeStubURLProtocol.reset() }

        let image = try await makeService().probe(imageURL)

        #expect(image.sizeBytes == UInt64(tail.count))
        #expect(image.version == "15.6.1")
    }

    @Test("A server that answers a ranged read with the whole file is abandoned unread")
    func abandonsRangeIgnoringServer() async {
        ProbeStubURLProtocol.reset()
        ProbeStubURLProtocol.handler = { request in
            if request.httpMethod == "HEAD" {
                return ProbeStubURLProtocol.Reply(
                    statusCode: 200, body: Data(),
                    headers: ["Content-Length": "\(16 * 1024 * 1024 * 1024)"])
            }
            // The Range header is ignored: 200, and the body is the whole image.
            return ProbeStubURLProtocol.Reply(
                statusCode: 200, body: Data(repeating: 0x41, count: 1 << 20), headers: [:],
                withholdsBodyUntilCancelled: true)
        }
        defer { ProbeStubURLProtocol.reset() }

        await #expect(throws: RestoreImageProbeError.rangeRequestsUnsupported) {
            _ = try await makeService().probe(imageURL)
        }
        #expect(ProbeStubURLProtocol.deliveredBodyBytes == ProbeStubURLProtocol.bodyPrimerBytes)
    }

    @Test("A range-ignoring server is refused while its size is still being read")
    func abandonsRangeIgnoringServerWithoutHead() async {
        ProbeStubURLProtocol.reset()
        ProbeStubURLProtocol.handler = { request in
            if request.httpMethod == "HEAD" {
                return ProbeStubURLProtocol.Reply(statusCode: 405, body: Data(), headers: [:])
            }
            return ProbeStubURLProtocol.Reply(
                statusCode: 200, body: Data(repeating: 0x41, count: 1 << 20), headers: [:],
                withholdsBodyUntilCancelled: true)
        }
        defer { ProbeStubURLProtocol.reset() }

        await #expect(throws: RestoreImageProbeError.rangeRequestsUnsupported) {
            _ = try await makeService().probe(imageURL)
        }
        #expect(ProbeStubURLProtocol.deliveredBodyBytes == ProbeStubURLProtocol.bodyPrimerBytes)
    }

    @Test("A zip64 image is accepted through the record its locator points at")
    func acceptsZip64Image() async throws {
        let tail = makeZip64Tail(containsVMA2: true)
        serve(total: tail.count, body: tail)
        defer { ProbeStubURLProtocol.reset() }

        let image = try await makeService().probe(imageURL)

        #expect(image.sizeBytes == UInt64(tail.count))
    }

    @Test(
        "Hostile zip64 metadata is refused, not trapped",
        arguments: [
            PoisonedZip64Field.locatorOffset, .unrepresentableSize, .unrepresentableOffset,
            .sizeBeyondEndOfFile,
        ])
    func refusesHostileZip64Metadata(field: PoisonedZip64Field) async {
        let tail =
            switch field {
            case .locatorOffset: makeZip64Tail(locatorOffset: 1 << 40)
            case .unrepresentableSize: makeZip64Tail(directorySize: .max)
            case .unrepresentableOffset: makeZip64Tail(directoryOffset: .max)
            case .sizeBeyondEndOfFile: makeZip64Tail(directorySize: 1 << 30)
            }
        serve(total: tail.count, body: tail)
        defer { ProbeStubURLProtocol.reset() }

        await #expect(throws: RestoreImageProbeError.unreadableStructure) {
            _ = try await makeService().probe(imageURL)
        }
    }

    @Test("A central directory larger than the cap is read only up to the cap")
    func clampsOversizedCentralDirectory() async {
        // A 64 GiB file, so a claimed 1 GiB directory sits inside it and nothing
        // but the cap keeps the read down.
        let total = 64 * 1024 * 1024 * 1024
        let tail = makeZip64Tail(
            containsVMA2: false, totalBytes: total, directorySize: 1 << 30, directoryOffset: 0)
        serve(total: total, body: tail)
        defer { ProbeStubURLProtocol.reset() }

        await #expect(throws: RestoreImageProbeError.notAVirtualMachineImage) {
            _ = try await makeService().probe(imageURL)
        }
        let lengths = ProbeStubURLProtocol.requestedRanges.compactMap(rangeLength)
        #expect(lengths.count == ProbeStubURLProtocol.requestedRanges.count)
        #expect(lengths.allSatisfy { $0 <= 16 * 1024 * 1024 })
        #expect(lengths.contains(16 * 1024 * 1024))
    }

    @Test("A file with no zip structure is refused as unreadable")
    func refusesUnreadableStructure() async {
        let junk = Data(repeating: 0x41, count: 4096)
        serve(total: junk.count, body: junk)
        defer { ProbeStubURLProtocol.reset() }

        await #expect(throws: RestoreImageProbeError.unreadableStructure) {
            _ = try await makeService().probe(imageURL)
        }
    }

    @Test("Byte-order and search helpers behave at the edges")
    func binaryHelpers() {
        #expect(RestoreImageProbeService.readLE([0x01, 0x00, 0x00, 0x00], 0, UInt32.self) == 1)
        #expect(RestoreImageProbeService.readLE([0xFF, 0xFF], 0, UInt32.self) == nil)
        #expect(RestoreImageProbeService.readLE([0x01, 0x02], -1, UInt16.self) == nil)
        #expect(RestoreImageProbeService.lastIndex(of: [0x02], in: [0x02, 0x01, 0x02]) == 2)
        #expect(RestoreImageProbeService.lastIndex(of: [0x03], in: [0x02, 0x01]) == nil)
        #expect(RestoreImageProbeService.lastIndex(of: [], in: [0x01]) == nil)
    }
}
