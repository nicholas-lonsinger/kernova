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

    /// The account's uid for a directory or file in the system root, the invoker's for every other path. The
    /// `current` link stays the invoker's: the installer gives a link no owner, since that could only be done by
    /// name, and a link's owner grants nothing.
    static func systemOwner(_ path: String) -> uid_t {
        let account = getpwnam(Self.account)?.pointee.pw_uid ?? 0
        guard path != systemRoot.current else { return getuid() }
        return path == systemRoot.path || path.hasPrefix(systemRoot.path + "/") ? account : getuid()
    }

    static let userDirectories = [
        "/home", "/home/pbear", "/home/pbear/.local", "/home/pbear/.local/share", "/home/pbear/.config",
        "/home/pbear/.config/services",
    ]

    static let userInstall: [String: String] = Dictionary(uniqueKeysWithValues: userDirectories.map { ($0, "d0755") })
        .merging([
            "/home/pbear/.local/share/kernova-agent": "d0755",
            "/home/pbear/.local/share/kernova-agent/slots": "d0755",
            "/home/pbear/.local/share/kernova-agent/slots/a": "d0755",
            "/home/pbear/.local/share/kernova-agent/slots/a/agent": "f0755",
            "/home/pbear/.local/share/kernova-agent/state.json": "f0644",
            "/home/pbear/.local/share/kernova-agent/current": "lslots/a",
            "/home/pbear/.config/services/agent.service": "f0644",
        ]) { $1 }

    static let systemDirectories = ["/opt", "/etc", "/etc/services"]

    static let systemInstall: [String: String] = Dictionary(
        uniqueKeysWithValues: systemDirectories.map { ($0, "d0755") }
    ).merging([
        "/opt/kernova-agent": "d0755",
        "/opt/kernova-agent/slots": "d0755",
        "/opt/kernova-agent/slots/a": "d0755",
        "/opt/kernova-agent/slots/a/agent": "f0755",
        "/opt/kernova-agent/state.json": "f0644",
        "/opt/kernova-agent/current": "lslots/a",
        "/etc/services/agent.service": "f0644",
    ]) { $1 }

    private static func checkFiles(_ scratch: Scratch, _ definitions: TestDefinitions) throws {
        let root = definitions.root
        let payload = FileManager.default.contents(atPath: scratch.root + root.installSlot + "/" + TestLander.name)
        #expect(payload.map(Array.init) == scratch.payloadBytes)
        let state = try InstallState.decoded(Array(try #require(scratch.contents(root.state)).utf8))
        #expect(state.active == "a")
        #expect(state.slots["a"]?.versionLabel == "9.9 (99)")
        #expect(state.slots["a"]?.payloadSHA256 == lowercaseHex(SHA256.hash(scratch.payloadBytes)))
        #expect(scratch.contents(definitions.definition) == definitions.text)
    }

    @Test("An install writes exactly the planned files with their modes, and the payload and state they name")
    func userInstall() throws {
        let scratch = try Scratch()
        try scratch.installer().run(Self.install(Self.user))
        #expect(try scratch.tree() == Self.userInstall)
        try Self.checkFiles(scratch, Self.user)
    }

    @Test(
        "An install and an uninstall report each step as they take it, in their dry run's words and order",
        arguments: [false, true])
    func reportsTheDryRun(uninstalling: Bool) throws {
        let scratch = try Scratch()
        if uninstalling { try scratch.installer().run(Self.install(Self.user)) }
        let plan = uninstalling ? Self.uninstall(Self.user) : Self.install(Self.user)
        var reported: [String] = []
        try scratch.installer().run(plan) { reported.append($0) }
        // With no command run, every step but the commands is taken.
        let taken = plan.steps.filter { if case .run = $0 { false } else { true } }
        #expect(reported == taken.map(\.description))
        #expect(InstallPlan.dryRun(plan, heading: "h") == ["h"] + plan.steps.map { "  " + $0.description })
    }

    @Test("An install clears a switch an update left pending, or reverted, before it writes anything")
    func clearsPendingSwitch() {
        let plan = Self.install(Self.user)
        #expect(plan.treeRemovals == [Self.userRoot.switchPending, Self.userRoot.switchRejected])
        #expect(plan.before == Self.user.beforeInstall)
        #expect(plan.after == Self.user.afterInstall)
    }

    @Test("An uninstall runs its definitions' commands and removes every file they write, then the root")
    func uninstallUndoesInstall() {
        let plan = Self.uninstall(Self.user)
        #expect(plan.removals == [Self.user.definition])
        #expect(plan.removesRoot)
        #expect(plan.before == Self.user.beforeUninstall)
        #expect(plan.after == Self.user.afterUninstall)
    }

    @Test("A refresh rewrites exactly its definitions' files, then reloads")
    func refresh() {
        let plan = InstallPlan.refresh(root: Self.userRoot, definitions: Self.user)
        #expect(plan.writes == Self.user.writes)
        #expect(plan.treeWrites.isEmpty && plan.treeRemovals.isEmpty && plan.before.isEmpty && !plan.removesRoot)
        #expect(plan.after == Self.user.afterRefresh)
    }

    @Test(
        "A system install writes the same, through descriptors, every directory and file in the agent's root handed to its account",
        .enabled(if: runsAsRoot, "handing files to another account needs root"))
    func systemInstall() throws {
        let scratch = try Scratch()
        try scratch.installer(account: Self.account).run(Self.install(Self.system))
        #expect(try scratch.tree(owner: Self.systemOwner) == Self.systemInstall)
        try Self.checkFiles(scratch, Self.system)
    }

    @Test(
        "A link the account planted where a slot belongs is refused, never followed",
        .enabled(if: runsAsRoot, "handing files to another account needs root"))
    func plantedLink() throws {
        let scratch = try Scratch()
        try scratch.installer(account: Self.account).run(Self.install(Self.system))
        // A directory the account could never write, as /etc is.
        let outside = scratch.directory.path + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: false)
        let slot = scratch.root + Self.systemRoot.installSlot
        try FileManager.default.removeItem(atPath: slot)
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

    @Test("Above the agent's root, a symlinked directory is a directory, as mkdir -p takes it")
    func symlinkedAncestor() throws {
        let scratch = try Scratch()
        let dotfiles = scratch.root + "/home/pbear/dotfiles/services"
        try FileManager.default.createDirectory(atPath: dotfiles, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: scratch.root + "/home/pbear/.config", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: scratch.root + "/home/pbear/.config/services", withDestinationPath: dotfiles)

        try scratch.installer().run(Self.install(Self.user))
        #expect(scratch.contents(Self.user.definition) == Self.user.text)
        #expect(FileManager.default.fileExists(atPath: dotfiles + "/agent.service"))
    }

    @Test("A reinstall over a pending switch leaves the same files, the switch cleared")
    func reinstallUser() throws {
        let scratch = try Scratch()
        try scratch.installer().run(Self.install(Self.user))
        let first = try scratch.tree()
        #expect(FileManager.default.createFile(atPath: scratch.root + Self.userRoot.switchPending, contents: Data()))
        try scratch.installer().run(Self.install(Self.user))
        #expect(try scratch.tree() == first)
    }

    @Test(
        "A system reinstall over a pending switch leaves the same files and owners, the switch cleared",
        .enabled(if: runsAsRoot, "handing files to another account needs root"))
    func reinstallSystem() throws {
        let scratch = try Scratch()
        try scratch.installer(account: Self.account).run(Self.install(Self.system))
        let first = try scratch.tree(owner: Self.systemOwner)
        #expect(FileManager.default.createFile(atPath: scratch.root + Self.systemRoot.switchPending, contents: Data()))
        try scratch.installer(account: Self.account).run(Self.install(Self.system))
        #expect(try scratch.tree(owner: Self.systemOwner) == first)
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

    @Test(
        "A system uninstall empties the agent's root through descriptors, then removes it",
        .enabled(if: runsAsRoot, "handing files to another account needs root"))
    func uninstallSystem() throws {
        let scratch = try Scratch()
        try scratch.installer(account: Self.account).run(Self.install(Self.system))
        try scratch.installer(account: Self.account).run(Self.uninstall(Self.system))
        #expect(try scratch.tree() == Dictionary(uniqueKeysWithValues: Self.systemDirectories.map { ($0, "d0755") }))
        try scratch.installer(account: Self.account).run(Self.uninstall(Self.system))
    }
}
#endif
