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

    /// A bundle at a path of its own holding `files`, keyed by their path under `Contents/Resources`.
    private func bundle(_ files: [String: Data]) throws -> Bundle {
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
    private static let payload = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })

    private static func manifest(of payload: Data, label: String = "1.2 (34)") -> UpdateManifestValue {
        UpdateManifestValue(
            payloadHash: Data(SHA256.hash(data: payload)), payloadSize: UInt64(payload.count), format: .executable,
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

    @Test("A bundle without the Linux agent has no Linux entry and offers no payload")
    func linuxMissing() async throws {
        let entries = BundledGuestAgents.entries(in: try bundle([:]), versionLabel: "1.2 (34)")
        #expect(entries.isEmpty)
        #expect(await BundledGuestAgents(entries: entries, linuxDisk: .testing).payloads(for: .linux).isEmpty)
    }

    @Test("The macOS agent is its installer DMG and version, and offers no in-band payload")
    func macOS() async throws {
        let agents = BundledGuestAgents(
            bundle: try bundle([
                "KernovaMacOSAgent.dmg": Data([0]), "KernovaMacOSAgentVersion.txt": Data("3.1\n".utf8),
                Self.linuxAgent: Data([1]),
            ]),
            versionLabel: "1.2 (34)")
        #expect(agents.macOSVersion == "3.1")
        let dmg = try #require(agents.macOSInstallerDiskImageURL)
        #expect(dmg.lastPathComponent == "KernovaMacOSAgent.dmg")
        #expect(agents.entry(.macOS, .arm64, .user)?.kind == .installerDisk(version: "3.1"))
        #expect(await agents.payloads(for: .macOS).isEmpty)
        #expect(RemovableMediaItem(path: dmg.path(percentEncoded: false), readOnly: true).isInstaller(of: agents))
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
