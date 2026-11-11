import CryptoKit
import Foundation
import KernovaCommandModel
import Security
import KernovaTestSupport
import Testing

@testable import KernovaCore

/// What a built Kernova.app carries, found through the `AppBundleProducts`
/// lookups `KernovaApp` reads its own bundle with. The app is only read, never
/// run.
@Suite("The built app's bundle products", .caseScoped)
struct AppBundleProductsTests {
    private let products: AppBundleProducts

    init() throws {
        products = AppBundleProducts(bundle: try BuiltProducts.bundle(named: "Kernova.app"))
    }

    @Test("The built app carries the macOS agent's payload for both scopes, labelled as the host's build")
    func builtAppCarriesTheMacOSPayload() throws {
        let agents = products.guestAgents
        let user = try #require(agents.entry(.macOS, .arm64, .user))
        #expect(agents.entry(.macOS, .arm64, .system) == user)
        #expect(user.format == .containerTree)
        #expect(user.versionLabel == products.versionLabel)
        let path = user.fileURL.path(percentEncoded: false)
        #expect(path.hasSuffix("Contents/Resources/GuestAgents/macos-arm64/agent.payload"))
        #expect(FileManager.default.fileExists(atPath: path))
    }

    /// The installer disk carries the app alone, and its install packs that
    /// app as it lands it: the identity it records is the bundled payload's
    /// only while packing the built app reproduces it.
    @Test("Packing the built agent app reproduces the bundled macOS payload's SHA-256")
    func packingTheBuiltAgentReproducesThePayload() async throws {
        let bundled = try #require(products.guestAgents.entry(.macOS, .arm64, .user)).fileURL
        let agent = try BuiltProducts.url(named: "Kernova Guest Agent.app")
        let scratch = TestScratchDirectory.forCase(prefix: "AgentPayload")
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let packed = scratch.url.appending(path: "agent.payload")

        let pack = Process()
        pack.executableURL = agent.appending(path: "Contents/MacOS/KernovaMacOSAgent")
        pack.arguments = ["pack-payload", agent.path(percentEncoded: false), packed.path(percentEncoded: false)]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            pack.terminationHandler = { _ in continuation.resume() }
            do { try pack.run() } catch { continuation.resume(throwing: error) }
        }
        #expect(pack.terminationStatus == 0)

        #expect(
            SHA256.hash(data: try Data(contentsOf: packed, options: .mappedIfSafe))
                == SHA256.hash(data: try Data(contentsOf: bundled, options: .mappedIfSafe)))
    }

    @Test("The built app offers its macOS agent in band exactly when the built agent carries a signing team")
    func macOSPayloadUpdatesInBandWhenTeamSigned() throws {
        let agent = try BuiltProducts.url(named: "Kernova Guest Agent.app")
        var code: SecStaticCode?
        try #require(SecStaticCodeCreateWithPath(agent as CFURL, [], &code) == errSecSuccess)
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        try #require(SecCodeCopySigningInformation(try #require(code), flags, &information) == errSecSuccess)
        let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
        let entry = try #require(products.guestAgents.entry(.macOS, .arm64, .user))
        #expect(entry.updatesInBand == (team != nil), "agent team: \(team ?? "none")")
    }

    @Test("isInstallerDisk(path:) matches the app's bundled installer image path only")
    func installerImageMatchesThePathOnly() throws {
        let agents = products.guestAgents
        let path = try #require(agents.macOSInstallerDiskImageURL).path(percentEncoded: false)
        #expect(path.hasSuffix("Contents/Resources/KernovaMacOSAgent.dmg"))
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(agents.isInstallerDisk(path: path))
        #expect(!agents.isInstallerDisk(path: "/tmp/other.iso"))
    }

    @Test("The built app carries the Linux agent for both scopes, readable and not executable")
    func builtAppCarriesTheLinuxAgent() throws {
        let entries = products.guestAgents.entries.values.filter { $0.fileURL.lastPathComponent == "kernova-agent" }
        #expect(entries.count == 2)
        let url = try #require(entries.first?.fileURL)
        #expect(url.path(percentEncoded: false).hasSuffix("Contents/Resources/GuestAgents/linux-arm64/kernova-agent"))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o644)
    }

    @Test("The built app carries the tool the installer links to")
    func builtAppCarriesTheTool() {
        let tool = products.commandLineTool.bundledToolURL
        #expect(FileManager.default.isExecutableFile(atPath: tool.path(percentEncoded: false)))
    }

    /// A sandboxed tool's launch asks for its containers before `main`, which
    /// on a Mac that ran a team-signed build raises a dialog for a team-less
    /// one.
    @Test("The built tool claims the sandbox and its team's app group exactly when it carries a signing team")
    func toolIsSandboxedOnlyWhenTeamSigned() throws {
        let tool = products.commandLineTool.bundledToolURL
        var code: SecStaticCode?
        try #require(SecStaticCodeCreateWithPath(tool as CFURL, [], &code) == errSecSuccess)
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        try #require(SecCodeCopySigningInformation(try #require(code), flags, &information) == errSecSuccess)
        let signing = information as? [String: Any]
        let team = signing?[kSecCodeInfoTeamIdentifier as String] as? String
        let entitlements = signing?[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        let sandboxed = entitlements["com.apple.security.app-sandbox"] as? Bool == true
        let groups = entitlements["com.apple.security.application-groups"] as? [String]
        if let team {
            #expect(sandboxed)
            #expect(groups == ["\(team).app.kernova"])
        } else {
            #expect(!sandboxed)
            #expect(groups == nil)
        }
    }

    @Test("The built app carries the relaunch helper")
    func builtAppCarriesTheRelaunchHelper() throws {
        let helper = try #require(products.relaunchHelperURL)
        #expect(FileManager.default.isExecutableFile(atPath: helper.path(percentEncoded: false)))
    }

    @Test("Every disk size offered has a blank-disk template in the built app")
    func everyOfferedSizeHasATemplate() {
        for size in VMGuestOS.allDiskSizes {
            #expect(products.diskTemplateURL(sizeInGB: size) != nil, "no \(size) GB template")
        }
    }
}

/// The products the build wrote beside this test bundle, which the target's
/// dependency on the app builds first.
private enum BuiltProducts {
    static func bundle(named name: String) throws -> Bundle {
        try #require(Bundle(url: try url(named: name)))
    }

    /// The product `name`, which the build wrote beside this test bundle.
    static func url(named name: String) throws -> URL {
        let directory = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent()
        let url = directory.appendingPathComponent(name, isDirectory: true)
        try #require(
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
            "\(name) is not in \(directory.path(percentEncoded: false))")
        return url
    }

    private final class Anchor {}
}
