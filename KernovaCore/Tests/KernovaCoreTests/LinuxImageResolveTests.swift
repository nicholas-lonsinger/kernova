import Foundation
import KernovaTestSupport
import Synchronization
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

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

/// Stub for the resolve service's requests.
///
/// Its own class rather than `StubURLProtocol` or `ProbeStubURLProtocol`, for
/// the reason spelled out on the latter: the handler is a global, and Swift
/// Testing runs suites in parallel, so sharing one lets two suites clobber each
/// other's handler.
final class ResolveStubURLProtocol: URLProtocol {
    struct Reply {
        var statusCode: Int
        var body: Data
        var headers: [String: String] = [:]
    }

    private struct State {
        var handler: (@Sendable (URLRequest) -> Reply)?
        var requestedURLs: [URL] = []
    }

    private static let state = Mutex(State())

    /// Sets what every later request is answered with.
    static func setHandler(_ handler: (@Sendable (URLRequest) -> Reply)?) {
        state.withLock { $0.handler = handler }
    }

    /// Every URL the stub was asked for since the last `reset()`.
    static var requestedURLs: [URL] { state.withLock { $0.requestedURLs } }

    /// Clears the handler and everything recorded about the requests it served.
    static func reset() {
        state.withLock { $0 = State() }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url
        let handler = Self.state.withLock { state -> (@Sendable (URLRequest) -> Reply)? in
            guard let handler = state.handler, let url else { return nil }
            state.requestedURLs.append(url)
            return handler
        }
        guard let handler, let url else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: "ResolveStubURLProtocol", code: -1,
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

@Suite("LinuxImageResolveService Tests", .serialized, .caseScoped)
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

    /// Serves `manifest` for anything that is not an ISO, and answers a HEAD for
    /// the ISO with `isoSize`.
    private func serve(manifest: String, manifestStatus: Int = 200, isoSize: Int = 3_540_299_776) {
        ResolveStubURLProtocol.reset()
        ResolveStubURLProtocol.setHandler { request in
            guard request.url?.lastPathComponent.hasSuffix(".iso") == true else {
                return ResolveStubURLProtocol.Reply(
                    statusCode: manifestStatus, body: Data(manifest.utf8))
            }
            return ResolveStubURLProtocol.Reply(
                statusCode: 200, body: Data(), headers: ["Content-Length": "\(isoSize)"])
        }
    }

    @Test("A redirect off the manifest's host is refused, and its target never requested")
    func refusesOffHostManifestRedirect() async {
        ResolveStubURLProtocol.reset()
        ResolveStubURLProtocol.setHandler { request in
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

    @Test("A manifest that keeps arriving past the cap is dropped, not parsed")
    func refusesOversizedManifest() async {
        // A valid line first, so what fails is the size and not the parse.
        serve(manifest: ubuntuManifest + "\n" + String(repeating: "A", count: 1024 * 1024))
        defer { ResolveStubURLProtocol.reset() }

        await #expect(throws: LinuxImageResolveError.manifestTooLarge(manifest: "SHA256SUMS")) {
            _ = try await makeService().resolve(ubuntuEntry)
        }
    }
}
