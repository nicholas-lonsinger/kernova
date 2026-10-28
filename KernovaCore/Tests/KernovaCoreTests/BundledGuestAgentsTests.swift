import CryptoKit
import Foundation
import KernovaAgentCore
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaCore

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

    private static let linuxAgent = "GuestAgents/linux-arm64/kernova-agent"

    @Test("The Linux agent serves both scopes from one file, with one manifest of its hash, size and label")
    func linuxPayloads() async throws {
        let payload = Data("kernova-agent payload".utf8)
        let agents = BundledGuestAgents(bundle: try bundle([Self.linuxAgent: payload]), versionLabel: "1.2 (34)")
        let user = try #require(agents.entry(.linux, .arm64, .user))
        let system = try #require(agents.entry(.linux, .arm64, .system))
        #expect(user.fileURL == system.fileURL)
        #expect(user.fileURL.path(percentEncoded: false).hasSuffix("Contents/Resources/\(Self.linuxAgent)"))
        #expect(agents.entry(.linux, .x86_64, .user) == nil)

        let payloads = await agents.payloads(for: .linux)
        let manifest = UpdateManifestValue(
            payloadHash: Data(SHA256.hash(data: payload)), payloadSize: UInt64(payload.count), format: .executable,
            versionLabel: "1.2 (34)")
        #expect(payloads.map(\.scope).sorted { $0.rawValue < $1.rawValue } == [.user, .system])
        #expect(payloads.allSatisfy { $0.os == .linux && $0.architecture == .arm64 && $0.manifest == manifest })
        #expect(await agents.payloads(for: .linux) == payloads)

        let session = PeerClaim(role: .sessionPeer, scope: .user, os: .linux, architecture: .arm64)
        let service = PeerClaim(role: .systemPeer, scope: .system, os: .linux, architecture: .arm64)
        #expect(BundledPayload.offer(from: payloads, for: session) == manifest)
        #expect(BundledPayload.offer(from: payloads, for: service) == manifest)
    }

    @Test("A bundle without the Linux agent has no Linux entry and offers no payload")
    func linuxMissing() async throws {
        let agents = BundledGuestAgents(bundle: try bundle([:]), versionLabel: "1.2 (34)")
        #expect(agents.entries.isEmpty)
        #expect(await agents.payloads(for: .linux).isEmpty)
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
}
