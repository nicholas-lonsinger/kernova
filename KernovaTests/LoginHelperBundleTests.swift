import Foundation
import Testing

@testable import Kernova

/// Verifies the bootstrap helper the app embeds at `Contents/Library/LoginItems`,
/// where `SMAppService.loginItem(identifier:)` resolves it.
///
/// Asserts the built bundle rather than the project file: a build phase places
/// the helper, and a missing or misidentified one surfaces at runtime only as a
/// `.notFound` registration status.
@Suite("Login item helper bundle")
struct LoginHelperBundleTests {
    private static let helperURL = Bundle.main.bundleURL.appending(
        path: "Contents/Library/LoginItems/KernovaLoginHelper.app")

    private func loadInfo() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.helperURL.appending(path: "Contents/Info.plist"))
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(object as? [String: Any])
    }

    @Test("the helper ships at the path SMAppService reads")
    func helperIsEmbeddedInTheBundle() {
        #expect(FileManager.default.fileExists(atPath: Self.helperURL.path(percentEncoded: false)))
    }

    @Test("the shipped bundle identifier is the one the registration asks for")
    func bundleIdentifierMatchesTheRegistration() throws {
        let info = try loadInfo()
        #expect(
            info["CFBundleIdentifier"] as? String
                == LoginHelperRegistration.helperBundleIdentifier)
    }

    @Test("the helper is an agent, so login shows no Dock icon")
    func helperIsAnAgent() throws {
        #expect(try loadInfo()["LSUIElement"] as? Bool == true)
    }

    @Test("the helper's versions match the host app's")
    func versionsMatchTheHostApp() throws {
        // App Store Connect validates a nested bundle's versions against the
        // enclosing app's, so the two must move together — which is why the
        // helper runs `set-build-number.sh` in the app's own mode.
        let info = try loadInfo()
        let host = try #require(Bundle.main.infoDictionary)
        #expect(info["CFBundleVersion"] as? String == host["CFBundleVersion"] as? String)
        #expect(
            info["CFBundleShortVersionString"] as? String
                == host["CFBundleShortVersionString"] as? String)
    }

    @Test("the helper carries a runnable executable")
    func helperExecutableIsRunnable() throws {
        let info = try loadInfo()
        let name = try #require(info["CFBundleExecutable"] as? String)
        let executable = Self.helperURL.appending(path: "Contents/MacOS/\(name)")
        #expect(FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false)))
    }
}
