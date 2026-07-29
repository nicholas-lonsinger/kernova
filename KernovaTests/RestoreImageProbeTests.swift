import Foundation
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

    @Test("The destination is Apple's filename, and falls back when the URL has none")
    func suggestedFilename() {
        #expect(
            makeProbedImage().suggestedFilename == "UniversalMac_15.6.1_24G90_Restore.ipsw")
        #expect(
            makeProbedImage(urlString: "https://example.com/downloads/")
                .suggestedFilename == "RestoreImage.ipsw")
        #expect(
            makeProbedImage(urlString: "https://example.com/image.zip")
                .suggestedFilename == "RestoreImage.ipsw")
    }

    @Test("Two different images never resolve to the same destination")
    func destinationsAreDistinct() {
        let first = makeProbedImage(
            urlString: "https://a.example.com/UniversalMac_15.6.1_24G90_Restore.ipsw")
        let second = makeProbedImage(
            urlString: "https://b.example.com/UniversalMac_26.6_25G72_Restore.ipsw")
        #expect(first.suggestedFilename != second.suggestedFilename)
    }

    @Test("Host support is unknown when the filename named no version")
    func hostSupportUnknownWithoutVersion() {
        let image = makeProbedImage(version: nil, build: nil)
        #expect(image.isSupported(onHost: host(26, 0, 0)) == nil)
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
    }

    nonisolated(unsafe) static var handler: ((URLRequest) -> Reply)?

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
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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

    /// Builds the tail of a zip whose central directory does or doesn't name a
    /// `vma2` member — the only thing the probe reads.
    ///
    /// Laid out so the directory sits immediately before the end-of-directory
    /// record, and the whole thing is served as one blob: the probe's tail read
    /// covers it, and the zip64 locator is deliberately absent so the 32-bit
    /// fields are authoritative.
    private func makeZipTail(containsVMA2: Bool) -> Data {
        var directory = Data()
        directory.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])  // central file header
        let name = containsVMA2 ? "kernelcache.release.vma2" : "kernelcache.release.im4p"
        directory.append(contentsOf: Array(name.utf8))

        var blob = Data()
        blob.append(directory)

        var eocd = Data()
        eocd.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])  // EOCD signature
        eocd.append(contentsOf: [0, 0, 0, 0])  // disk numbers
        eocd.append(contentsOf: [1, 0, 1, 0])  // entry counts
        withUnsafeBytes(of: UInt32(directory.count).littleEndian) { eocd.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(0).littleEndian) { eocd.append(contentsOf: $0) }  // offset
        eocd.append(contentsOf: [0, 0])  // comment length
        blob.append(eocd)
        return blob
    }

    /// Serves `body` for every request, answering HEAD with the declared total
    /// and range requests out of the same bytes.
    private func serve(total: Int, body: Data, headStatus: Int = 200) {
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
        defer { ProbeStubURLProtocol.handler = nil }

        let image = try await makeService().probe(imageURL)

        #expect(image.sizeBytes == UInt64(tail.count))
        #expect(image.version == "15.6.1")
        #expect(image.build == "24G90")
        #expect(image.url == imageURL)
    }

    @Test("An image with no VM hardware model is refused")
    func refusesImageWithoutVirtualMachineModel() async {
        let tail = makeZipTail(containsVMA2: false)
        serve(total: tail.count, body: tail)
        defer { ProbeStubURLProtocol.handler = nil }

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
        defer { ProbeStubURLProtocol.handler = nil }

        await #expect(throws: RestoreImageProbeError.insecureURL) {
            _ = try await makeService().probe(http)
        }
    }

    @Test("A URL that 404s is refused with its status")
    func refusesMissingImage() async {
        serve(total: 0, body: Data(), headStatus: 404)
        defer { ProbeStubURLProtocol.handler = nil }

        await #expect(throws: RestoreImageProbeError.unreachable(statusCode: 404)) {
            _ = try await makeService().probe(imageURL)
        }
    }

    @Test("A file with no zip structure is refused as unreadable")
    func refusesUnreadableStructure() async {
        let junk = Data(repeating: 0x41, count: 4096)
        serve(total: junk.count, body: junk)
        defer { ProbeStubURLProtocol.handler = nil }

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
