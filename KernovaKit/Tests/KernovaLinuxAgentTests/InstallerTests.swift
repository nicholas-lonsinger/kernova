#if os(Linux)
import Foundation
import Glibc
import KernovaAgentCore
import KernovaPortableTestSupport
import Testing

@testable import KernovaLinuxAgent

/// `kernova-agent install --root <dir> --no-systemctl`, carried out in a scratch directory: exactly the
/// files the plan names, with their modes, owned by whoever ran it, and nothing else.
@Suite("The installer on disk")
struct InstallerTests {
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

        func installer() -> Installer {
            Installer(stagingRoot: root, runsSystemd: false, payloadSource: payload, versionLabel: "9.9 (99)")
        }

        /// Every path under the staging root: `d0755` for a directory, `f0644` for a file, `l<target>`
        /// for a link; each must be owned by this process's user and group.
        func tree() throws -> [String: String] {
            var entries: [String: String] = [:]
            // By hand, never following a link.
            var pending = try FileManager.default.contentsOfDirectory(atPath: root).map { "/" + $0 }
            while let path = pending.popLast() {
                var info = stat()
                guard lstat(root + path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
                #expect(info.st_uid == getuid() && info.st_gid == getgid(), "\(path) is owned by another user")
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
        "/var", "/var/lib", "/etc", "/etc/systemd", "/etc/systemd/system", "/etc/sysusers.d", "/etc/polkit-1",
        "/etc/polkit-1/rules.d",
    ]

    static let systemInstall: [String: String] = Dictionary(
        uniqueKeysWithValues: systemDirectories.map { ($0, "d0755") }
    ).merging([
        "/var/lib/kernova-agent": "d0755",
        "/var/lib/kernova-agent/slots": "d0755",
        "/var/lib/kernova-agent/slots/a": "d0755",
        "/var/lib/kernova-agent/slots/a/kernova-agent": "f0755",
        "/var/lib/kernova-agent/state.json": "f0644",
        "/var/lib/kernova-agent/current": "lslots/a",
        "/etc/systemd/system/kernova-agent-system.service": "f0644",
        "/etc/systemd/system/kernova-agent-rollback.timer": "f0644",
        "/etc/systemd/system/kernova-agent-rollback.service": "f0644",
        "/etc/sysusers.d/kernova-agent.conf": "f0644",
        "/etc/polkit-1/rules.d/50-kernova-agent.rules": "f0644",
    ]) { $1 }

    @Test(
        "An install writes exactly the planned files with their modes, and the payload and state they name",
        arguments: [(InstallScope.user, userInstall), (.system, systemInstall)])
    func install(scope: InstallScope, expected: [String: String]) throws {
        let scratch = try Scratch()
        let layout = try Self.layout(scope)
        try scratch.installer().run(.install(layout))
        #expect(try scratch.tree() == expected)

        let binary = FileManager.default.contents(atPath: scratch.root + layout.installSlot + "/kernova-agent")
        #expect(binary.map(Array.init) == scratch.payloadBytes)
        let state = try JSONDecoder().decode(
            InstallState.self, from: Data(try #require(scratch.contents(layout.state)).utf8))
        #expect(state.active == "a")
        #expect(state.slots["a"]?.versionLabel == "9.9 (99)")
        #expect(state.slots["a"]?.payloadSHA256.count == 64)
        #expect(scratch.contents(layout.unitDirectory + "/" + layout.serviceName) == UnitFiles.service(layout))
        #expect(
            scratch.contents(layout.unitDirectory + "/kernova-agent-rollback.timer")
                == UnitFiles.rollbackTimer(layout))
        #expect(
            scratch.contents(layout.unitDirectory + "/kernova-agent-rollback.service")
                == UnitFiles.rollbackService(layout))
    }

    @Test(
        "A reinstall over a pending switch leaves the same files, the switch cleared",
        arguments: [InstallScope.user, .system])
    func reinstall(scope: InstallScope) throws {
        let scratch = try Scratch()
        let layout = try Self.layout(scope)
        try scratch.installer().run(.install(layout))
        let first = try scratch.tree()
        #expect(FileManager.default.createFile(atPath: scratch.root + layout.switchPending, contents: Data()))
        try scratch.installer().run(.install(layout))
        #expect(try scratch.tree() == first)
    }

    @Test(
        "An uninstall removes every file the install wrote, leaving only the shared directories",
        arguments: [(InstallScope.user, userDirectories), (.system, systemDirectories)])
    func uninstall(scope: InstallScope, remaining: [String]) throws {
        let scratch = try Scratch()
        let layout = try Self.layout(scope)
        try scratch.installer().run(.install(layout))
        try scratch.installer().run(.uninstall(layout))
        #expect(try scratch.tree() == Dictionary(uniqueKeysWithValues: remaining.map { ($0, "d0755") }))
        // Nothing left to remove is not a failure.
        try scratch.installer().run(.uninstall(layout))
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
                == .system(root: "/var/lib/kernova-agent"))
    }
}
#endif
