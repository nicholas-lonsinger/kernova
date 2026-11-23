import Foundation
import KernovaKit
import KernovaTestSupport
import Synchronization
import Testing

@testable import KernovaCore

/// Stub for the probe's requests.
///
/// Its own class rather than `StubURLProtocol`: that one's handler is a
/// global, and Swift Testing runs suites in parallel, so sharing it lets this
/// suite and `DownloadServiceTests` clobber each other's handler.
/// `.serialized` orders tests *within* a suite and does not prevent that.
final class ProbeStubURLProtocol: URLProtocol {
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

    private struct State {
        var handler: (@Sendable (URLRequest) -> Reply)?
        var deliveredBodyBytes = 0
        var requestedRanges: [String] = []
    }

    private static let state = Mutex(State())

    /// Sets what every later request is answered with.
    static func setHandler(_ handler: (@Sendable (URLRequest) -> Reply)?) {
        state.withLock { $0.handler = handler }
    }

    /// Body bytes handed to a client since the last `reset()`.
    static var deliveredBodyBytes: Int { state.withLock { $0.deliveredBodyBytes } }

    /// Every `Range` header value the stub was asked for since the last `reset()`.
    static var requestedRanges: [String] { state.withLock { $0.requestedRanges } }

    /// Clears the handler and everything recorded about the requests it served.
    static func reset() {
        state.withLock { $0 = State() }
    }

    /// A withheld reply's body, for the deliveries `startLoading` schedules.
    private var withheldBody = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let range = request.value(forHTTPHeaderField: "Range")
        let handler = Self.state.withLock { state -> (@Sendable (URLRequest) -> Reply)? in
            guard let handler = state.handler, request.url != nil else { return nil }
            if let range { state.requestedRanges.append(range) }
            return handler
        }
        guard let handler, let url = request.url else {
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
        guard reply.withholdsBodyUntilCancelled else {
            deliver(reply.body)
            return
        }
        // Both deliveries run on this loading thread's run loop, where
        // `stopLoading` cancels them. The primer is scheduled rather than
        // delivered here because nothing handed to the client reaches it until
        // `startLoading` has returned. A run-loop timer arms no `Backstop`, so
        // the session activity is armed here.
        armTestSessionActivity()
        withheldBody = reply.body
        let modes = [RunLoop.Mode.default] + (RunLoop.current.currentMode.map { [$0] } ?? [])
        perform(#selector(deliverPrimer), with: nil, afterDelay: 0, inModes: modes)
        perform(#selector(deliverRemainder), with: nil, afterDelay: testWaitBackstop, inModes: modes)
    }

    override func stopLoading() {
        NSObject.cancelPreviousPerformRequests(withTarget: self)
    }

    @objc private func deliverPrimer() {
        deliver(withheldBody.prefix(Self.bodyPrimerBytes), finishing: false)
    }

    @objc private func deliverRemainder() {
        deliver(withheldBody.dropFirst(Self.bodyPrimerBytes))
    }

    private func deliver(_ body: Data, finishing: Bool = true) {
        if !body.isEmpty {
            Self.state.withLock { $0.deliveredBodyBytes += body.count }
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

@Suite("RestoreImageProbeService Tests", .serialized, .caseScoped)
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
        ProbeStubURLProtocol.setHandler { request in
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

    @Test("A server that answers a ranged read with the whole file is abandoned unread")
    func abandonsRangeIgnoringServer() async {
        ProbeStubURLProtocol.reset()
        ProbeStubURLProtocol.setHandler { request in
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
        ProbeStubURLProtocol.setHandler { request in
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
