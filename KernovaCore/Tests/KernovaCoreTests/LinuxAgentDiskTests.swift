import Foundation
import KernovaCommandModel
import KernovaISO9660
import KernovaTestSupport
import Testing

@testable import KernovaCore

/// The Linux agent's installer disk: its files, the commands that run them, and the one write per process
/// that makes it.
@Suite("LinuxAgentDisk", .caseScoped)
struct LinuxAgentDiskTests {
    private let scratch = TestScratchDirectory(prefix: "LinuxAgentDiskTests")

    private func agent(_ bytes: [UInt8]) throws -> URL {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let url = scratch.url.appending(path: "kernova-agent")
        try Data(bytes).write(to: url)
        return url
    }

    private static func contents(_ entry: ISO9660Entry) throws -> [UInt8] {
        var bytes: [UInt8] = []
        try entry.contents { bytes += $0 }
        return bytes
    }

    @Test("The disk holds the agent and both scripts executable, and its text files readable")
    func entries() throws {
        let payload = (0..<(3 << 20) + 11).map { UInt8(truncatingIfNeeded: $0) }
        let entries = try LinuxAgentDisk.entries(agent: try agent(payload), files: LinuxAgentDisk.bundledFiles)
        #expect(
            Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.permissions) }) == [
                "install.sh": 0o755, "uninstall.sh": 0o755, "kernova-agent": 0o755, "README.txt": 0o644,
                "LICENSES.txt": 0o644,
            ])
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        let agent = try #require(byName["kernova-agent"])
        #expect(agent.size == UInt64(payload.count))
        #expect(try Self.contents(agent) == payload)
        // One script, which acts by the name it runs as.
        let install = try Self.contents(try #require(byName["install.sh"]))
        #expect(install == (try Self.contents(try #require(byName["uninstall.sh"]))))
        #expect(install.starts(with: Array("#!/bin/sh\n".utf8)))
    }

    @Test("README.txt gives the commands the popover and the alerts give")
    func readmeCommands() throws {
        let readme = String(
            decoding: try LinuxAgentDisk.resource("README.txt", in: LinuxAgentDisk.bundledFiles), as: UTF8.self)
        for choice in LinuxAgentInstallChoice.allCases {
            #expect(readme.contains(LinuxAgentDisk.installCommand(for: choice)))
        }
        #expect(readme.contains(LinuxAgentDisk.uninstallCommand))
        let headless = LinuxAgentDisk.mountAndInstallCommands(for: .both).map { "    " + $0 }
        #expect(readme.contains(headless.joined(separator: "\n")))
    }

    @Test("Each choice's command installs exactly its agents: as the user, with --system, or as root through sudo")
    func installCommandPerChoice() {
        let mount =
            "findmnt -n LABEL=KERNOVA_AGENT >/dev/null || udisksctl mount -b /dev/disk/by-label/KERNOVA_AGENT >/dev/null; "
        let script = #""$(findmnt -nro TARGET LABEL=KERNOVA_AGENT)/install.sh""#
        #expect(LinuxAgentDisk.installCommand(for: .sessionAgent) == mount + "sh " + script)
        #expect(LinuxAgentDisk.installCommand(for: .both) == mount + "sh " + script + " --system")
        #expect(LinuxAgentDisk.installCommand(for: .systemService) == mount + "sudo sh " + script + " --system")
        #expect(
            LinuxAgentDisk.uninstallCommand
                == mount + #"sh "$(findmnt -nro TARGET LABEL=KERNOVA_AGENT)/uninstall.sh""#)
        #expect(LinuxAgentDisk.mountAndInstallCommands(for: .sessionAgent).last == "sh /mnt/kernova-agent/install.sh")
        #expect(
            LinuxAgentDisk.mountAndInstallCommands(for: .both).last == "sh /mnt/kernova-agent/install.sh --system")
        #expect(
            LinuxAgentDisk.mountAndInstallCommands(for: .systemService).last
                == "sudo sh /mnt/kernova-agent/install.sh --system")
    }

    @Test("A choice names its agents, starts on the ones the VM has run, and on both where it has run none")
    func installChoice() {
        let titles = ["Session agent and system service", "Session agent", "System service"]
        #expect(LinuxAgentInstallChoice.allCases.map(\.title) == titles)
        for choice in LinuxAgentInstallChoice.allCases {
            #expect(LinuxAgentInstallChoice(installing: choice.scopes) == choice)
        }
        #expect(LinuxAgentInstallChoice(installing: []) == nil)
        #expect(LinuxAgentInstallChoice(seen: []) == .both)
        #expect(LinuxAgentInstallChoice(seen: [.login]) == .sessionAgent)
        #expect(LinuxAgentInstallChoice(seen: [.system]) == .systemService)
        #expect(LinuxAgentInstallChoice(seen: [.login, .system]) == .both)
    }

    @Test("The cache writes the image once per process, at one path, labelled KERNOVA_AGENT")
    func writesOnce() async throws {
        let agent = try agent([1, 2, 3])
        let cache = GuestAgentDiskCache(
            directory: scratch.url.appending(path: "disks"), files: LinuxAgentDisk.bundledFiles)
        let url = try await cache.disk(agent: agent)
        #expect(url == cache.url)
        #expect(url.lastPathComponent == "linux-arm64.iso")
        let image = try Data(contentsOf: url)
        #expect(String(decoding: image[16 * 2048 + 40..<16 * 2048 + 53], as: UTF8.self) == "KERNOVA_AGENT")

        try FileManager.default.removeItem(at: url)
        #expect(try await cache.disk(agent: agent) == url)
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.url.appending(path: "disks").path) == [])
    }

    @Test("A write that failed is tried again on the next ask")
    func retriesAFailedWrite() async throws {
        let agent = scratch.url.appending(path: "kernova-agent")
        let cache = GuestAgentDiskCache(
            directory: scratch.url.appending(path: "disks"), files: LinuxAgentDisk.bundledFiles)
        await #expect(throws: (any Error).self) { try await cache.disk(agent: agent) }
        _ = try self.agent([4, 5, 6])
        #expect(try await cache.disk(agent: agent) == cache.url)
    }
}
