#if os(Linux)
import Foundation
import Glibc
import KernovaAgentCore
import KernovaPortableTestSupport
import Testing

@testable import KernovaLinuxAgent

/// `kernova-agent install --root <dir> --no-systemctl`, carried out in a scratch directory: exactly the
/// files the plan names, with their modes and owners, and nothing else.
@Suite("The installer on disk")
struct InstallerTests {
    /// The account the system tests hand the agent's root to: one every Linux system has.
    static let account = "nobody"
    /// Handing files to it needs root, which the CI container runs as.
    static let runsAsRoot = geteuid() == 0

    /// A scratch staging root and a stand-in payload, removed at the end.
    final class Scratch {
        let directory: PortableScratchDirectory
        let root: String
        let payload: String
        let payloadBytes: [UInt8] = Array("\u{7F}ELF stand-in payload".utf8) + Array(repeating: 0xA5, count: 70_000)

        init() throws {
            directory = try PortableScratchDirectory(prefix: "kernova-installer")
            root = directory.path + "/stage"
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
            payload = directory.path + "/payload"
            try Data(payloadBytes).write(to: URL(filePath: payload))
        }

        func installer(account: String? = nil) -> Installer {
            Installer(
                stagingRoot: root, runsSystemd: false, payloadSource: payload, versionLabel: "9.9 (99)",
                account: account)
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

    static let environment = ["HOME": "/home/pbear"]

    static func layout(_ scope: InstallScope) throws -> InstallLayout {
        try Installer.layout(
            for: AgentCommand.InstallRequest(scope: scope, root: "/stage", runsSystemd: false),
            environment: environment, effectiveUID: getuid())
    }

    /// The account's uid for a directory or file in the system root, the invoker's for every other path. The
    /// `current` link stays the invoker's: the installer gives a link no owner, since that could only be done by
    /// name, and a link's owner grants nothing.
    static func systemOwner(_ path: String) -> uid_t {
        let account = getpwnam(Self.account)?.pointee.pw_uid ?? 0
        guard path != "/opt/kernova-agent/current" else { return getuid() }
        return path == "/opt/kernova-agent" || path.hasPrefix("/opt/kernova-agent/") ? account : getuid()
    }

    static let userDirectories = [
        "/home", "/home/pbear", "/home/pbear/.local", "/home/pbear/.local/share", "/home/pbear/.config",
        "/home/pbear/.config/systemd", "/home/pbear/.config/systemd/user", "/home/pbear/.config/autostart",
    ]

    static let userInstall: [String: String] = Dictionary(uniqueKeysWithValues: userDirectories.map { ($0, "d0755") })
        .merging([
            "/home/pbear/.local/share/kernova-agent": "d0755",
            "/home/pbear/.local/share/kernova-agent/slots": "d0755",
            "/home/pbear/.local/share/kernova-agent/slots/a": "d0755",
            "/home/pbear/.local/share/kernova-agent/slots/a/kernova-agent": "f0755",
            "/home/pbear/.local/share/kernova-agent/state.json": "f0644",
            "/home/pbear/.local/share/kernova-agent/current": "lslots/a",
            "/home/pbear/.config/systemd/user/kernova-agent.service": "f0644",
            "/home/pbear/.config/systemd/user/kernova-agent-rollback.timer": "f0644",
            "/home/pbear/.config/systemd/user/kernova-agent-rollback.service": "f0644",
            "/home/pbear/.config/autostart/app.kernova.agent.desktop": "f0644",
        ]) { $1 }

    static let systemDirectories = [
        "/opt", "/etc", "/etc/systemd", "/etc/systemd/system", "/etc/sysusers.d", "/etc/polkit-1",
        "/etc/polkit-1/rules.d",
    ]

    static let systemInstall: [String: String] = Dictionary(
        uniqueKeysWithValues: systemDirectories.map { ($0, "d0755") }
    ).merging([
        "/opt/kernova-agent": "d0755",
        "/opt/kernova-agent/slots": "d0755",
        "/opt/kernova-agent/slots/a": "d0755",
        "/opt/kernova-agent/slots/a/kernova-agent": "f0755",
        "/opt/kernova-agent/state.json": "f0644",
        "/opt/kernova-agent/current": "lslots/a",
        "/etc/systemd/system/kernova-agent-system.service": "f0644",
        "/etc/systemd/system/kernova-agent-rollback.timer": "f0644",
        "/etc/systemd/system/kernova-agent-rollback.service": "f0644",
        "/etc/sysusers.d/kernova-agent.conf": "f0644",
        "/etc/polkit-1/rules.d/50-kernova-agent.rules": "f0644",
    ]) { $1 }

    private static func checkFiles(_ scratch: Scratch, _ layout: InstallLayout) throws {
        let binary = FileManager.default.contents(atPath: scratch.root + layout.installSlot + "/kernova-agent")
        #expect(binary.map(Array.init) == scratch.payloadBytes)
        let state = try JSONDecoder().decode(
            InstallState.self, from: Data(try #require(scratch.contents(layout.state)).utf8))
        #expect(state.active == "a")
        #expect(state.slots["a"]?.versionLabel == "9.9 (99)")
        #expect(state.slots["a"]?.payloadSHA256.count == 64)
        #expect(scratch.contents(layout.unitDirectory + "/" + layout.serviceName) == UnitFiles.service(layout))
        #expect(
            scratch.contents(layout.unitDirectory + "/kernova-agent-rollback.timer") == UnitFiles.rollbackTimer(layout))
        #expect(
            scratch.contents(layout.unitDirectory + "/kernova-agent-rollback.service")
                == UnitFiles.rollbackService(layout))
    }

    @Test("A user install writes exactly the planned files with their modes, and the payload and state they name")
    func userInstall() throws {
        let scratch = try Scratch()
        let layout = try Self.layout(.user)
        try scratch.installer().run(.install(layout))
        #expect(try scratch.tree() == Self.userInstall)
        try Self.checkFiles(scratch, layout)
    }

    @Test(
        "A system install writes the same, through descriptors, every directory and file in the agent's root handed to its account",
        .enabled(if: runsAsRoot, "handing files to another account needs root"))
    func systemInstall() throws {
        let scratch = try Scratch()
        let layout = try Self.layout(.system)
        try scratch.installer(account: Self.account).run(.install(layout))
        #expect(try scratch.tree(owner: Self.systemOwner) == Self.systemInstall)
        try Self.checkFiles(scratch, layout)
    }

    @Test(
        "A link the account planted where a slot belongs is refused, never followed",
        .enabled(if: runsAsRoot, "handing files to another account needs root"))
    func plantedLink() throws {
        let scratch = try Scratch()
        let layout = try Self.layout(.system)
        try scratch.installer(account: Self.account).run(.install(layout))
        // A directory the account could never write, as /etc is.
        let outside = scratch.directory.path + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: false)
        let slot = scratch.root + layout.installSlot
        try FileManager.default.removeItem(atPath: slot)
        try FileManager.default.createSymbolicLink(atPath: slot, withDestinationPath: outside)
        let planted = try #require(getpwnam(Self.account)?.pointee)
        #expect(lchown(slot, planted.pw_uid, planted.pw_gid) == 0)

        #expect(throws: Installer.Failure.self) { try scratch.installer(account: Self.account).run(.install(layout)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside) == [])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: slot) == outside)
    }

    @Test(
        "An uninstall removes a link the account planted in its root without following it",
        .enabled(if: runsAsRoot, "handing files to another account needs root"))
    func uninstallPlantedLink() throws {
        let scratch = try Scratch()
        let layout = try Self.layout(.system)
        try scratch.installer(account: Self.account).run(.install(layout))
        let outside = scratch.directory.path + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: false)
        #expect(FileManager.default.createFile(atPath: outside + "/precious", contents: Data("keep".utf8)))
        try FileManager.default.createSymbolicLink(
            atPath: scratch.root + layout.root + "/slots/b", withDestinationPath: outside)
        try FileManager.default.createSymbolicLink(
            atPath: scratch.root + layout.switchPending, withDestinationPath: outside + "/precious")

        try scratch.installer(account: Self.account).run(.uninstall(layout))
        #expect(!FileManager.default.fileExists(atPath: scratch.root + layout.root))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside) == ["precious"])
    }

    @Test(
        "A reinstall over a planted switch-pending link removes the link and leaves its target",
        .enabled(if: runsAsRoot, "handing files to another account needs root"))
    func reinstallPlantedSwitchLink() throws {
        let scratch = try Scratch()
        let layout = try Self.layout(.system)
        try scratch.installer(account: Self.account).run(.install(layout))
        let precious = scratch.directory.path + "/precious"
        #expect(FileManager.default.createFile(atPath: precious, contents: Data("keep".utf8)))
        try FileManager.default.createSymbolicLink(
            atPath: scratch.root + layout.switchPending, withDestinationPath: precious)

        try scratch.installer(account: Self.account).run(.install(layout))
        #expect(FileManager.default.contents(atPath: precious) == Data("keep".utf8))
        #expect(
            (try? FileManager.default.destinationOfSymbolicLink(atPath: scratch.root + layout.switchPending)) == nil)
    }

    @Test("Above the agent's root, a symlinked directory is a directory, as mkdir -p takes it")
    func symlinkedAncestor() throws {
        let scratch = try Scratch()
        let layout = try Self.layout(.user)
        let dotfiles = scratch.root + "/home/pbear/dotfiles/systemd"
        try FileManager.default.createDirectory(atPath: dotfiles, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: scratch.root + "/home/pbear/.config", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: scratch.root + "/home/pbear/.config/systemd", withDestinationPath: dotfiles)

        try scratch.installer().run(.install(layout))
        #expect(
            scratch.contents(layout.unitDirectory + "/" + layout.serviceName) == UnitFiles.service(layout))
        #expect(FileManager.default.fileExists(atPath: dotfiles + "/user/kernova-agent.service"))
    }

    @Test("A reinstall over a pending switch leaves the same files, the switch cleared")
    func reinstallUser() throws {
        let scratch = try Scratch()
        let layout = try Self.layout(.user)
        try scratch.installer().run(.install(layout))
        let first = try scratch.tree()
        #expect(FileManager.default.createFile(atPath: scratch.root + layout.switchPending, contents: Data()))
        try scratch.installer().run(.install(layout))
        #expect(try scratch.tree() == first)
    }

    @Test(
        "A system reinstall over a pending switch leaves the same files and owners, the switch cleared",
        .enabled(if: runsAsRoot, "handing files to another account needs root"))
    func reinstallSystem() throws {
        let scratch = try Scratch()
        let layout = try Self.layout(.system)
        try scratch.installer(account: Self.account).run(.install(layout))
        let first = try scratch.tree(owner: Self.systemOwner)
        #expect(FileManager.default.createFile(atPath: scratch.root + layout.switchPending, contents: Data()))
        try scratch.installer(account: Self.account).run(.install(layout))
        #expect(try scratch.tree(owner: Self.systemOwner) == first)
    }

    @Test("A user uninstall removes every file the install wrote, leaving only the shared directories")
    func uninstallUser() throws {
        let scratch = try Scratch()
        let layout = try Self.layout(.user)
        try scratch.installer().run(.install(layout))
        try scratch.installer().run(.uninstall(layout))
        #expect(try scratch.tree() == Dictionary(uniqueKeysWithValues: Self.userDirectories.map { ($0, "d0755") }))
        // Nothing left to remove is not a failure.
        try scratch.installer().run(.uninstall(layout))
    }

    @Test(
        "A system uninstall empties the agent's root through descriptors, then removes it",
        .enabled(if: runsAsRoot, "handing files to another account needs root"))
    func uninstallSystem() throws {
        let scratch = try Scratch()
        let layout = try Self.layout(.system)
        try scratch.installer(account: Self.account).run(.install(layout))
        try scratch.installer(account: Self.account).run(.uninstall(layout))
        #expect(try scratch.tree() == Dictionary(uniqueKeysWithValues: Self.systemDirectories.map { ($0, "d0755") }))
        try scratch.installer(account: Self.account).run(.uninstall(layout))
    }

    @Test("A system the installer finds no systemd on is refused before anything is written")
    func needsSystemd() throws {
        let scratch = try Scratch()
        #expect(throws: Installer.Failure.self) {
            try Installer.requireSystemd(runDirectory: scratch.directory.path + "/run/systemd/system")
        }
        try FileManager.default.createDirectory(
            atPath: scratch.directory.path + "/run/systemd/system", withIntermediateDirectories: true)
        try Installer.requireSystemd(runDirectory: scratch.directory.path + "/run/systemd/system")
    }

    @Test("User scope refuses root and system scope needs it, on the live system")
    func liveUsers() {
        let user = AgentCommand.InstallRequest()
        let system = AgentCommand.InstallRequest(scope: .system)
        #expect(throws: Installer.Failure.self) {
            try Installer.layout(for: user, environment: Self.environment, effectiveUID: 0)
        }
        #expect(throws: Installer.Failure.self) {
            try Installer.layout(for: system, environment: Self.environment, effectiveUID: 1000)
        }
        #expect(
            (try? Installer.layout(for: user, environment: Self.environment, effectiveUID: 1000))
                == .user(root: "/home/pbear/.local/share/kernova-agent", configHome: "/home/pbear/.config"))
        #expect(
            (try? Installer.layout(for: system, environment: [:], effectiveUID: 0))
                == .system(root: "/opt/kernova-agent"))
    }
}
#endif
