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

        /// Puts a stand-in `sudo` first on the script's `PATH`: it records `sudo <arguments>`, refuses `-n` with
        /// sudo's own message when `refusesNonInteractive`, and otherwise runs the rest.
        func addSudo(refusesNonInteractive: Bool) throws {
            let bin = directory.path + "/bin"
            try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
            chmod(bin, 0o777)
            let refusal = refusesNonInteractive ? "echo 'sudo: a password is required' >&2; exit 1" : ":"
            let sudo = """
                #!/bin/sh
                echo "sudo $*" >> '\(calls)'
                if [ "$1" = -n ]; then \(refusal); shift; fi
                exec "$@"

                """
            try Data(sudo.utf8).write(to: URL(fileURLWithPath: bin + "/sudo"))
            chmod(bin + "/sudo", 0o755)
            path = bin + ":" + path
        }

        private var path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"

        /// Runs `sh install.sh arguments`, under `prefix` when given, with `NONINTERACTIVE` set when
        /// `nonInteractive` and `input` on standard input, answering its exit status.
        func run(
            _ arguments: [String], as prefix: [String] = [], nonInteractive: Bool = true, input: String = ""
        ) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = path
            environment["NONINTERACTIVE"] = nonInteractive ? "1" : nil
            process.environment = environment
            process.arguments = prefix + ["sh", directory.path + "/install.sh"] + arguments
            let stdin = Pipe()
            process.standardInput = stdin
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try stdin.fileHandleForWriting.close()
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
        #expect(disk.recorded() == ["0 install --system --dry-run", "0 install --system"])
        #expect(try disk.run([]) == 64)
        #expect(disk.recorded() == ["0 install --system --dry-run", "0 install --system"])
    }

    @Test(
        "Without NONINTERACTIVE it shows the plan and waits for Return, changing nothing without one",
        .enabled(if: geteuid() == 0, "needs a root shell, which the CI container is"))
    func waitsForReturn() throws {
        let disk = try Disk()
        #expect(try disk.run(["--system"], nonInteractive: false) == 1)
        #expect(disk.recorded() == ["0 install --system --dry-run"])
        #expect(try disk.run(["--system"], nonInteractive: false, input: "\n") == 0)
        #expect(disk.recorded().suffix(2) == ["0 install --system --dry-run", "0 install --system"])
    }

    @Test(
        "NONINTERACTIVE skips the wait and runs sudo -n, after the plan and before the user step",
        .enabled(if: geteuid() == 0, "needs root to become another user"))
    func nonInteractiveUsesSudoN() throws {
        let disk = try Disk()
        try disk.addSudo(refusesNonInteractive: false)
        #expect(try disk.run(["--system"], as: Self.nobody) == 0)
        let calls = disk.recorded()
        #expect(
            calls.prefix(4) == [
                "65534 install --dry-run", "65534 install --system --dry-run", "sudo -n true", "65534 install",
            ])
        #expect(calls.count == 6)
        #expect(calls.dropFirst(4).first?.hasPrefix("sudo -n /") == true)
        #expect(calls.dropFirst(4).first?.hasSuffix("/kernova-agent install --system") == true)
        #expect(calls.last == "65534 install --system")
    }

    @Test(
        "A sudo -n that needs a password stops before anything is changed",
        .enabled(if: geteuid() == 0, "needs root to become another user"))
    func refusedSudoChangesNothing() throws {
        let disk = try Disk()
        try disk.addSudo(refusesNonInteractive: true)
        #expect(try disk.run(["--system"], as: Self.nobody) == 1)
        #expect(disk.recorded() == ["65534 install --dry-run", "65534 install --system --dry-run", "sudo -n true"])
    }

    static let nobody = ["setpriv", "--reuid=65534", "--regid=65534", "--clear-groups"]

    @Test(
        "A user's --system without sudo refuses before the user step runs",
        .enabled(if: geteuid() == 0 && !Self.hasSudo, "needs root to become another user, and no sudo"))
    func userWithoutSudo() throws {
        let disk = try Disk()
        #expect(try disk.run(["--system"], as: Self.nobody) == 1)
        #expect(disk.recorded() == [])
        #expect(try disk.run([], as: Self.nobody) == 0)
        #expect(disk.recorded() == ["65534 install --dry-run", "65534 install"])
    }

    static var hasSudo: Bool {
        ["/usr/bin/sudo", "/bin/sudo", "/usr/sbin/sudo"].contains { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
#endif
