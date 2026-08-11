import Foundation
import Testing

@testable import Kernova

/// Verifies the LaunchAgent the app ships to `Contents/Library/LaunchAgents`,
/// where `SMAppService.agent(plistName:)` reads it (#796).
///
/// Asserts the built bundle rather than the source file: a build phase places
/// the plist, and a missing one surfaces at runtime only as a `.notFound`
/// registration status.
@Suite("Login LaunchAgent plist")
struct LoginLaunchAgentPlistTests {
    private static let plistURL = Bundle.main.bundleURL.appending(
        path: "Contents/Library/LaunchAgents/\(LoginAgentRegistration.plistName)")

    private func loadJob() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.plistURL)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(object as? [String: Any])
    }

    @Test("the plist ships at the path SMAppService reads")
    func plistIsEmbeddedInTheBundle() {
        #expect(FileManager.default.fileExists(atPath: Self.plistURL.path(percentEncoded: false)))
    }

    @Test("the label matches the plist's own name")
    func labelMatchesPlistName() throws {
        let job = try loadJob()
        let expected = (LoginAgentRegistration.plistName as NSString).deletingPathExtension
        #expect(job["Label"] as? String == expected)
    }

    @Test("BundleProgram resolves to an executable inside the app bundle")
    func bundleProgramResolvesInsideTheBundle() throws {
        let job = try loadJob()
        let program = try #require(job["BundleProgram"] as? String)
        let executable = Bundle.main.bundleURL.appending(path: program)
        #expect(FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false)))
    }

    @Test("ProgramArguments start with the program and carry the login-launch flag")
    func programArgumentsCarryTheLoginLaunchFlag() throws {
        let job = try loadJob()
        let arguments = try #require(job["ProgramArguments"] as? [String])
        #expect(arguments.first == job["BundleProgram"] as? String)
        #expect(LaunchPosture(arguments: arguments) == .loginLaunch)
    }

    @Test("the job runs at load, in the Aqua session only")
    func jobRunsAtLoadInAquaOnly() throws {
        let job = try loadJob()
        #expect(job["RunAtLoad"] as? Bool == true)
        #expect(job["LimitLoadToSessionType"] as? String == "Aqua")
    }

    @Test("the job is attributed to the app in System Settings")
    func jobIsAttributedToTheApp() throws {
        let job = try loadJob()
        let identifiers = try #require(job["AssociatedBundleIdentifiers"] as? [String])
        #expect(identifiers == [try #require(Bundle.main.bundleIdentifier)])
    }
}
