#if canImport(Darwin) || os(Linux)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import KernovaDigest
import KernovaPortableTestSupport
import Testing

@testable import KernovaAgentInstall

/// A service manager's files for a test: one definition naming the agent it runs, in `directory`.
struct TestDefinitions: ServiceDefinitions {
    let root: InstallRoot
    let directory: String

    var definition: String { directory + "/agent.service" }
    var text: String { "run " + root.current + "/" + TestLander.name + "\n" }

    var writes: [InstallPlan.Write] {
        [.directory(path: directory, mode: 0o755), .file(path: definition, mode: 0o644, text: text)]
    }
    var beforeInstall: [InstallPlan.Command] { [InstallPlan.Command(["stop-check"], onlyIfPresent: definition)] }
    var afterInstall: [InstallPlan.Command] { [InstallPlan.Command(["start"])] }
    var beforeUninstall: [InstallPlan.Command] { [InstallPlan.Command(["stop"], onlyIfPresent: definition)] }
    var afterUninstall: [InstallPlan.Command] { [InstallPlan.Command(["reload"])] }
    var afterRefresh: [InstallPlan.Command] { [InstallPlan.Command(["reload"])] }
}

/// An install's plan carried out in a scratch staging root, no command run: exactly the files the plan names,
/// with their modes and owners, and nothing else.
@Suite("The installer on disk")
struct InstallerTests {
    /// The account the system tests hand the agent's root to: one every Darwin and Linux system has.
    static let account = "nobody"
    /// Handing files to it needs root, which the Linux CI container runs as.
    static let runsAsRoot = geteuid() == 0

    /// A scratch staging root and a stand-in payload, removed at the end.
    final class Scratch {
        let directory: PortableScratchDirectory
        let root: String
        let payload: String
        let payloadBytes: [UInt8] = Array("stand-in payload".utf8) + Array(repeating: 0xA5, count: 70_000)

        init() throws {
            directory = try PortableScratchDirectory(prefix: "kernova-installer")
            root = directory.path + "/stage"
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
            payload = directory.path + "/payload"
            try Data(payloadBytes).write(to: URL(fileURLWithPath: payload))
        }

        func installer(account: String? = nil) -> Installer {
            Installer(
                stagingRoot: root, runsCommands: false, payloadSource: .file(payload), lander: TestLander(),
                versionLabel: "9.9 (99)", account: account)
        }

        /// Every path under the staging root: `d0755` for a directory, `f0644` for a file, `l<target>`
        /// for a link; each owned by `owner(path)`.
        func tree(owner: (String) -> uid_t = { _ in getuid() }) throws -> [String: String] {
            var entries: [String: String] = [:]
            // By hand, never following a link.
            var pending = try FileManager.default.contentsOfDirectory(atPath: root).map { "/" + $0 }
            while let path = pending.popLast() {
                var info = stat()
                guard lstat(root + path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
                #expect(info.st_uid == owner(path), "\(path) is owned by uid \(info.st_uid)")
                let mode = String(info.st_mode & 0o7777, radix: 8)
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    entries[path] = "d0" + mode
                    pending += try FileManager.default.contentsOfDirectory(atPath: root + path).map { path + "/" + $0 }
                case S_IFREG: entries[path] = "f0" + mode
                case S_IFLNK:
                    entries[path] = "l" + (try FileManager.default.destinationOfSymbolicLink(atPath: root + path))
                default: entries[path] = "?"
                }
            }
            return entries
        }

        func contents(_ path: String) -> String? {
            FileManager.default.contents(atPath: root + path).map { String(decoding: $0, as: UTF8.self) }
        }
    }

    static let userRoot = InstallRoot(path: "/home/pbear/.local/share/kernova-agent")
    static let user = TestDefinitions(root: userRoot, directory: "/home/pbear/.config/services")
    static let systemRoot = InstallRoot(path: "/opt/kernova-agent")
    static let system = TestDefinitions(root: systemRoot, directory: "/etc/services")

    static func install(_ definitions: TestDefinitions) -> InstallPlan {
        .install(root: definitions.root, payloadName: TestLander.name, definitions: definitions)
    }

    static func uninstall(_ definitions: TestDefinitions) -> InstallPlan {
        .uninstall(root: definitions.root, definitions: definitions)
    }

    static let userDirectories = [
        "/home", "/home/pbear", "/home/pbear/.local", "/home/pbear/.local/share", "/home/pbear/.config",
        "/home/pbear/.config/services",
    ]

    @Test(
        "A link the account planted where a slot belongs is refused, never followed",
        .enabled(if: runsAsRoot, "handing files to another account needs root"))
    func plantedLink() throws {
        let scratch = try Scratch()
        try scratch.installer(account: Self.account).run(Self.install(Self.system))
        // A directory the account could never write, as /etc is.
        let outside = scratch.directory.path + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: false)
        // The slot the next install fills: the one `current` does not name.
        let slot = scratch.root + Self.systemRoot.slot("b")
        try FileManager.default.createSymbolicLink(atPath: slot, withDestinationPath: outside)
        let planted = try #require(getpwnam(Self.account)?.pointee)
        #expect(lchown(slot, planted.pw_uid, planted.pw_gid) == 0)

        #expect(throws: Installer.Failure.self) {
            try scratch.installer(account: Self.account).run(Self.install(Self.system))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside) == [])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: slot) == outside)
    }

    @Test(
        "An uninstall removes a link the account planted in its root without following it",
        .enabled(if: runsAsRoot, "handing files to another account needs root"))
    func uninstallPlantedLink() throws {
        let scratch = try Scratch()
        try scratch.installer(account: Self.account).run(Self.install(Self.system))
        let outside = scratch.directory.path + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: false)
        #expect(FileManager.default.createFile(atPath: outside + "/precious", contents: Data("keep".utf8)))
        try FileManager.default.createSymbolicLink(
            atPath: scratch.root + Self.systemRoot.slot("b"), withDestinationPath: outside)
        try FileManager.default.createSymbolicLink(
            atPath: scratch.root + Self.systemRoot.switchPending, withDestinationPath: outside + "/precious")

        try scratch.installer(account: Self.account).run(Self.uninstall(Self.system))
        #expect(!FileManager.default.fileExists(atPath: scratch.root + Self.systemRoot.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside) == ["precious"])
    }

    @Test(
        "A reinstall over a planted switch-pending link removes the link and leaves its target",
        .enabled(if: runsAsRoot, "handing files to another account needs root"))
    func reinstallPlantedSwitchLink() throws {
        let scratch = try Scratch()
        try scratch.installer(account: Self.account).run(Self.install(Self.system))
        let precious = scratch.directory.path + "/precious"
        #expect(FileManager.default.createFile(atPath: precious, contents: Data("keep".utf8)))
        try FileManager.default.createSymbolicLink(
            atPath: scratch.root + Self.systemRoot.switchPending, withDestinationPath: precious)

        try scratch.installer(account: Self.account).run(Self.install(Self.system))
        #expect(FileManager.default.contents(atPath: precious) == Data("keep".utf8))
        #expect(
            (try? FileManager.default.destinationOfSymbolicLink(atPath: scratch.root + Self.systemRoot.switchPending))
                == nil)
    }

    @Test("An uninstall removes every file the install wrote, leaving only the shared directories")
    func uninstallUser() throws {
        let scratch = try Scratch()
        try scratch.installer().run(Self.install(Self.user))
        try scratch.installer().run(Self.uninstall(Self.user))
        #expect(try scratch.tree() == Dictionary(uniqueKeysWithValues: Self.userDirectories.map { ($0, "d0755") }))
        // Nothing left to remove is not a failure.
        try scratch.installer().run(Self.uninstall(Self.user))
    }
}
#endif
