#if os(Linux)
import Foundation
import Glibc
import KernovaPortableTestSupport
import Testing

/// The disk's `install.sh`, run against a stand-in `kernova-agent` that records how it was run: which steps
/// a root shell and a user take.
@Suite("The agent disk's install.sh")
struct AgentDiskScriptTests {
    /// The script, from the source tree, where KernovaCore bundles it for the disk.
    static let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../KernovaCore/Sources/KernovaCore/Resources/LinuxAgentDisk/agent-disk.sh")
        .standardizedFileURL.path

    /// A disk directory holding the script as install.sh and a stand-in agent that appends
    /// `<uid> <arguments>` to `calls`.
    final class Disk {
        let directory: PortableScratchDirectory
        var calls: String { directory.path + "/calls" }

        init() throws {
            directory = try PortableScratchDirectory(prefix: "agent-disk")
            try FileManager.default.copyItem(
                atPath: AgentDiskScriptTests.script, toPath: directory.path + "/install.sh")
            let agent = "#!/bin/sh\necho \"$(id -u) $*\" >> '\(calls)'\n"
            try Data(agent.utf8).write(to: URL(fileURLWithPath: directory.path + "/kernova-agent"))
            // Every account may run it and record a call.
            chmod(directory.path, 0o777)
            _ = FileManager.default.createFile(atPath: calls, contents: Data())
            chmod(calls, 0o666)
        }

        /// Runs `sh install.sh arguments`, under `prefix` when given, answering its exit status.
        func run(_ arguments: [String], as prefix: [String] = []) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = prefix + ["sh", directory.path + "/install.sh"] + arguments
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        func recorded() -> [String] {
            (FileManager.default.contents(atPath: calls).map { String(decoding: $0, as: UTF8.self) } ?? "")
                .split(separator: "\n").map(String.init)
        }
    }

    @Test(
        "A root shell's --system runs only the system step, without sudo; without --system it refuses",
        .enabled(if: geteuid() == 0, "needs a root shell, which the CI container is"))
    func rootShell() throws {
        let disk = try Disk()
        #expect(try disk.run(["--system"]) == 0)
        #expect(disk.recorded() == ["0 install --system"])
        #expect(try disk.run([]) == 64)
        #expect(disk.recorded() == ["0 install --system"])
    }

    @Test(
        "A user's --system without sudo refuses before the user step runs",
        .enabled(if: geteuid() == 0 && !Self.hasSudo, "needs root to become another user, and no sudo"))
    func userWithoutSudo() throws {
        let disk = try Disk()
        let nobody = ["setpriv", "--reuid=65534", "--regid=65534", "--clear-groups"]
        #expect(try disk.run(["--system"], as: nobody) == 1)
        #expect(disk.recorded() == [])
        #expect(try disk.run([], as: nobody) == 0)
        #expect(disk.recorded() == ["65534 install"])
    }

    static var hasSudo: Bool {
        ["/usr/bin/sudo", "/bin/sudo", "/usr/sbin/sudo"].contains { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
#endif
