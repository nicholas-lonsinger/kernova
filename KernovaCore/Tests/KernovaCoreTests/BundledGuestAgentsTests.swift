import CryptoKit
import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaCommandModel
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("The bundled guest agents of an app bundle", .caseScoped)
struct BundledGuestAgentsTests {
    private let scratch = TestScratchDirectory(prefix: "kernova-bundled-agents-test")

    /// A bundle at a path of its own holding every file a build packs — with `files`, keyed by their path
    /// under `Contents/Resources`, in place of the stand-ins.
    private func bundle(_ files: [String: Data]) throws -> Bundle {
        try bundle(exactly: Self.packed.merging(files) { $1 })
    }

    /// A bundle at a path of its own holding `files` and nothing else.
    private func bundle(exactly files: [String: Data]) throws -> Bundle {
        let app = scratch.url.appendingPathComponent("Fixture.app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>app.kernova.fixture</string></dict></plist>
            """.utf8
        ).write(to: app.appendingPathComponent("Contents/Info.plist"))
        for (path, contents) in files {
            let url = resources.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url)
        }
        return try #require(Bundle(url: app))
    }

    private static let linuxAgent = BundledGuestAgents.linuxAgentPath
    private static let macOSAgent = BundledGuestAgents.macOSAgentPath
    private static let macOSDisk = BundledGuestAgents.macOSInstallerDiskPath
    private static let payload = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
    private static let macOSPayload = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ 5) })

    /// Every file a build packs, as stand-ins.
    private static let packed = [linuxAgent: payload, macOSAgent: macOSPayload, macOSDisk: Data([0])]

    private static func manifest(
        of payload: Data, format: PayloadFormat = .executable, label: String = "1.2 (34)"
    ) -> UpdateManifestValue {
        UpdateManifestValue(
            payloadHash: Data(SHA256.hash(data: payload)), payloadSize: UInt64(payload.count), format: format,
            versionLabel: label)
    }

    @Test("The Linux agent serves both scopes from one file, with one manifest of its hash, size and label")
    func linuxPayloads() async throws {
        let agents = BundledGuestAgents(bundle: try bundle([Self.linuxAgent: Self.payload]), versionLabel: "1.2 (34)")
        let user = try #require(agents.entry(.linux, .arm64, .user))
        let system = try #require(agents.entry(.linux, .arm64, .system))
        #expect(user.fileURL == system.fileURL)
        #expect(user.fileURL.path(percentEncoded: false).hasSuffix("Contents/Resources/\(Self.linuxAgent)"))
        #expect(agents.entry(.linux, .x86_64, .user) == nil)

        let payloads = await agents.payloads(for: .linux)
        let manifest = Self.manifest(of: Self.payload)
        #expect(payloads.map(\.scope) == [.user, .system])
        #expect(payloads.allSatisfy { $0.os == .linux && $0.architecture == .arm64 && $0.manifest == manifest })

        let session = PeerClaim(role: .sessionPeer, scope: .user, os: .linux, architecture: .arm64)
        let service = PeerClaim(role: .systemPeer, scope: .system, os: .linux, architecture: .arm64)
        #expect(BundledPayload.offer(from: payloads, for: session) == manifest)
        #expect(BundledPayload.offer(from: payloads, for: service) == manifest)
    }

    @Test("A payload file is hashed once per process: rewriting it after the first ask changes no manifest")
    func hashedOnce() async throws {
        let agents = BundledGuestAgents(bundle: try bundle([Self.linuxAgent: Self.payload]), versionLabel: "1.2 (34)")
        let first = await agents.payloads(for: .linux)
        let url = try #require(agents.entry(.linux, .arm64, .user)).fileURL
        try Data("rewritten".utf8).write(to: url)
        #expect(await agents.payloads(for: .linux) == first)
        #expect(first.first?.manifest == Self.manifest(of: Self.payload))
    }

    @Test("A bundle without an agent's payload has no entry for it and offers no payload")
    func payloadsMissing() async throws {
        let entries = BundledGuestAgents.entries(
            in: try bundle(exactly: [Self.macOSDisk: Data([0])]), versionLabel: "1.2 (34)")
        #expect(entries.isEmpty)
        let agents = BundledGuestAgents(entries: entries, macOSInstallerDiskImageURL: nil, linuxDisk: .testing)
        #expect(await agents.payloads(for: .linux).isEmpty)
        #expect(await agents.payloads(for: .macOS).isEmpty)
        #expect(await agents.payloadHashes().isEmpty)
    }

    @Test("The macOS agent serves both scopes from one container-tree payload, offered with its hash, beside the DMG")
    func macOS() async throws {
        let agents = BundledGuestAgents(bundle: try bundle([:]), versionLabel: "1.2 (34)")
        let user = try #require(agents.entry(.macOS, .arm64, .user))
        let system = try #require(agents.entry(.macOS, .arm64, .system))
        #expect(user == system)
        #expect(user.format == .containerTree)
        #expect(user.versionLabel == "1.2 (34)")
        #expect(user.fileURL.path(percentEncoded: false).hasSuffix("Contents/Resources/\(Self.macOSAgent)"))

        let payloads = await agents.payloads(for: .macOS)
        let manifest = Self.manifest(of: Self.macOSPayload, format: .containerTree)
        #expect(
            await agents.payloadHashes() == [
                .macOS: manifest.payloadHash, .linux: Self.manifest(of: Self.payload).payloadHash,
            ])
        #expect(payloads.map(\.scope) == [.user, .system])
        #expect(payloads.allSatisfy { $0.os == .macOS && $0.architecture == .arm64 && $0.manifest == manifest })
        let session = PeerClaim(role: .sessionPeer, scope: .user, os: .macOS, architecture: .arm64)
        let service = PeerClaim(role: .systemPeer, scope: .system, os: .macOS, architecture: .arm64)
        #expect(BundledPayload.offer(from: payloads, for: session) == manifest)
        #expect(BundledPayload.offer(from: payloads, for: service) == manifest)
        #expect(await agents.payloadFile(for: manifest, os: .macOS) == user.fileURL)

        let dmg = try #require(agents.macOSInstallerDiskImageURL)
        #expect(dmg.lastPathComponent == Self.macOSDisk)
        #expect(agents.bundlesInstallerDisk(for: .macOS))
        #expect(try await agents.installerDisk(for: .macOS) == dmg)
        #expect(agents.isInstallerDisk(path: dmg.path(percentEncoded: false)))
        #expect(!agents.isInstallerDisk(path: user.fileURL.path(percentEncoded: false)))
    }

    // MARK: The hub's provider

    @Test("The hub's provider reads the bundled file's bytes at an offset, and refuses a manifest it did not make")
    func providerReads() async throws {
        let agents = BundledGuestAgents(bundle: try bundle([Self.linuxAgent: Self.payload]), versionLabel: "1.2 (34)")
        let provider = BundledGuestAgentPayloads(agents, guestOS: .linux)
        let manifest = Self.manifest(of: Self.payload)
        let read = await withCheckedContinuation { continuation in
            provider.read(manifest: manifest, offset: 1000, count: 300) { continuation.resume(returning: $0) }
        }
        #expect(try read.get() == Self.payload[1000..<1300])
        let tail = await withCheckedContinuation { continuation in
            provider.read(manifest: manifest, offset: 4000, count: 300) { continuation.resume(returning: $0) }
        }
        #expect(try tail.get() == Self.payload[4000...])

        let other = Self.manifest(of: Data("other".utf8))
        let refused = await withCheckedContinuation { continuation in
            provider.read(manifest: other, offset: 0, count: 10) { continuation.resume(returning: $0) }
        }
        #expect(throws: WireError.self) { try refused.get() }
    }

    @Test(
        "Read as a pull reads it, a grant at a time from offset 0 to payload_size, the provider serves the exact file")
    func providerServesExactBytes() async throws {
        let payload = Data(
            (0..<(2 * WireConstants.maxRawDataPayload + 1234)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let agents = BundledGuestAgents(bundle: try bundle([Self.linuxAgent: payload]), versionLabel: "1.2 (34)")
        let provider = BundledGuestAgentPayloads(agents, guestOS: .linux)
        let manifest = Self.manifest(of: payload)
        var served = Data()
        while UInt64(served.count) < manifest.payloadSize {
            let count = min(WireConstants.maxRawDataPayload, Int(manifest.payloadSize) - served.count)
            let read = await withCheckedContinuation { continuation in
                provider.read(manifest: manifest, offset: UInt64(served.count), count: count) {
                    continuation.resume(returning: $0)
                }
            }
            let bytes = try read.get()
            try #require(!bytes.isEmpty)
            served += bytes
        }
        #expect(served == payload)
        #expect(Data(SHA256.hash(data: served)) == manifest.payloadHash)
    }

    @Test("A Linux VM's hub offers the bundled payload, and a peer running it stands current")
    @MainActor
    func hubOffersTheBundle() async throws {
        let agents = BundledGuestAgents(bundle: try bundle([Self.linuxAgent: Self.payload]), versionLabel: "1.2 (34)")
        let products = AppBundleProducts(
            bundleURL: URL(filePath: "/var/empty/Kernova.app", directoryHint: .isDirectory), hostVersion: "1.2",
            buildNumber: "34", guestAgents: agents)
        let probe = AgentHubProbe()
        let instance = VMInstanceFixture.make(
            guestOS: .linux, phase: .running(sessionID: UUID()), bundleProducts: products, agentConnector: probe)
        instance.beginSessionContextForTesting()
        instance.attachAgentTransport(probe)
        try await probe.changed.wait { probe.isStarted }
        #expect(probe.connect())

        let claim = PeerClaim(
            role: .sessionPeer, scope: .user, os: .linux, architecture: .arm64,
            payloadHash: Self.manifest(of: Self.payload).payloadHash, versionLabel: "1.2 (34)",
            instanceID: Data(repeating: 1, count: 16))
        probe.deliver(.helloReceived(claim, PeerSessionState(console: .on, sessionID: "2")), fromConnection: 0)
        probe.deliver(.featuresChanged(FeatureStatusTable()), fromConnection: 0)
        try await waitForChange { instance.agentHubSnapshot.peers.first?.standing == .current }

        #expect(probe.connect())
        try await probe.changed.wait { probe.bundles.count == 2 }
        #expect(probe.bundles[1] == (await agents.payloads(for: .linux)))
    }
}
