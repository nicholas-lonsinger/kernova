#if os(macOS)
import Foundation
import KernovaAgentInstall
import KernovaTestSupport
import Security
import Testing

@testable import KernovaPlatformDarwin

@Suite("The launch requirement an update is held to", .caseScoped)
struct LaunchRequirementTests {
    /// An app bundle around a copy of `/usr/bin/true`, signed ad-hoc by `codesign`: its designated requirement is
    /// its own cdhash, which the bundle's `CFBundleVersion` changes.
    static func adHocBundle(in directory: URL, version: String) throws -> String {
        let bundle = directory.appending(path: "Agent-\(version).app")
        let executables = bundle.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: executables.appending(path: "agent").path)
        let info: [String: String] = [
            "CFBundleIdentifier": "app.kernova.tests.launch-requirement", "CFBundleExecutable": "agent",
            "CFBundleVersion": version,
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: bundle.appending(path: "Contents/Info.plist"))
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", bundle.path]
        codesign.standardOutput = FileHandle.nullDevice
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()
        try #require(codesign.terminationStatus == 0, "codesign \(bundle.path)")
        return bundle.path
    }

    static func scratch() throws -> URL {
        let url = TestScratchDirectory(prefix: "kernova-launch").url
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A bundle meets its own designated requirement; one signed ad-hoc from other content is refused")
    func adHocBundles() throws {
        let directory = try Self.scratch()
        let installed = try Self.adHocBundle(in: directory, version: "1")
        let update = try Self.adHocBundle(in: directory, version: "2")
        let requirement = try LaunchRequirement.designatedRequirement(ofCodeAt: installed).get()

        #expect(LaunchRequirement.refusal(ofBundleAt: installed, against: requirement) == nil)
        let refusal = try #require(LaunchRequirement.refusal(ofBundleAt: update, against: requirement))
        #expect(refusal.code == .updateLaunchRefused)
        #expect(refusal.rejectsPayload)
        #expect(refusal.detail.contains("\(errSecCSReqFailed)"))
    }

    @Test("A path that holds no signed code is refused as one the OS would not launch")
    func unsigned() throws {
        let directory = try Self.scratch()
        let requirement = try LaunchRequirement.designatedRequirement(
            ofCodeAt: try Self.adHocBundle(in: directory, version: "1")
        ).get()
        let empty = directory.appending(path: "Empty.app")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(LaunchRequirement.refusal(ofBundleAt: empty.path, against: requirement)?.code == .updateLaunchRefused)
    }

    @Test("The running code meets its own designated requirement, and another ad-hoc bundle does not")
    func runningCode() throws {
        var running: SecCode?
        try #require(SecCodeCopySelf(SecCSFlags(), &running) == errSecSuccess)
        var code: SecStaticCode?
        try #require(SecCodeCopyStaticCode(try #require(running), SecCSFlags(), &code) == errSecSuccess)
        var url: CFURL?
        try #require(SecCodeCopyPath(try #require(code), SecCSFlags(), &url) == errSecSuccess)
        let path = (try #require(url) as URL).path

        #expect(LaunchRequirement.refusal(ofBundleAt: path) == nil)
        let adHoc = try Self.adHocBundle(in: try Self.scratch(), version: "1")
        #expect(LaunchRequirement.refusal(ofBundleAt: adHoc)?.code == .updateLaunchRefused)
    }
}
#endif
