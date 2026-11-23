#if os(Linux)
import Foundation
import Glibc
import KernovaPortableTestSupport
import Testing

/// The disk's `install.sh`, run against a stand-in `kernova-agent` and, where a test gives one, a stand-in
/// `sudo`, each recording how it was run: which steps a root shell and a user take, and in what order.
@Suite("The agent disk's install.sh")
struct AgentDiskScriptTests {
    /// The script, from the source tree, where KernovaCore bundles it for the disk.
    static let script = SourceTree.url("KernovaCore/Sources/KernovaCore/Resources/LinuxAgentDisk/agent-disk.sh").path

    /// The stand-ins, checked in because Linux refuses to run a file some process holds open for writing, and a
    /// child this process spawns concurrently can inherit the descriptor of a file it writes. Each appends a line
    /// to the file `STAND_IN_CALLS` names: the agent `<uid> <arguments>`, and `bin/sudo` `sudo <arguments>`
    /// before refusing `-n` with sudo's own message when `STAND_IN_SUDO_REFUSES` is set, and otherwise running
    /// the rest.
    static let standIns = SourceTree.url("KernovaKit/Tests/KernovaLinuxAgentTests/StandIns").path

    /// A disk directory holding the script as install.sh, the stand-in agent, and the `calls` they record to.
    final class Disk {
        let directory: PortableScratchDirectory
        var calls: String { directory.path + "/calls" }

        init() throws {
            directory = try PortableScratchDirectory(prefix: "agent-disk")
            try FileManager.default.copyItem(
                atPath: AgentDiskScriptTests.script, toPath: directory.path + "/install.sh")
            // The stand-in agent is 0644, so a script that runs its copy without making it executable fails here.
            try FileManager.default.createSymbolicLink(
                atPath: directory.path + "/kernova-agent",
                withDestinationPath: AgentDiskScriptTests.standIns + "/kernova-agent")
            // Every account may run it and record a call.
            chmod(directory.path, 0o777)
            _ = FileManager.default.createFile(atPath: calls, contents: Data())
            chmod(calls, 0o666)
        }

        private var path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        private var sudoRefuses = false

        /// Runs `sh install.sh arguments`, under `prefix` when given, with `NONINTERACTIVE` set when
        /// `nonInteractive` and `input` on standard input, answering its exit status.
        func run(
            _ arguments: [String], as prefix: [String] = [], nonInteractive: Bool = true, input: String = ""
        ) async throws -> Int32 {
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = path
            environment["NONINTERACTIVE"] = nonInteractive ? "1" : nil
            environment["STAND_IN_CALLS"] = calls
            environment["STAND_IN_SUDO_REFUSES"] = sudoRefuses ? "1" : nil
            return try await ChildProcess(
                URL(fileURLWithPath: "/usr/bin/env"), prefix + ["sh", directory.path + "/install.sh"] + arguments,
                environment: environment, input: Data(input.utf8)
            ).exit().status
        }

        func recorded() -> [String] {
            (FileManager.default.contents(atPath: calls).map { String(decoding: $0, as: UTF8.self) } ?? "")
                .split(separator: "\n").map(String.init)
        }
    }

    @Test(
        "A root shell's --system runs only the system step, without sudo; without --system it refuses",
        .enabled(if: geteuid() == 0, "needs a root shell, which the CI container is"))
    func rootShell() async throws {
        let disk = try Disk()
        #expect(try await disk.run(["--system"]) == 0)
        #expect(disk.recorded() == ["0 install --system --dry-run", "0 install --system"])
        #expect(try await disk.run([]) == 64)
        #expect(disk.recorded() == ["0 install --system --dry-run", "0 install --system"])
    }
}
#endif
