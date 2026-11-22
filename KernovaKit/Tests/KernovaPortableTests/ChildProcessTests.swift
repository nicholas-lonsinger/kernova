#if !os(Windows)
import Foundation
import KernovaPortableTestSupport
import Testing

@Suite("Child processes", .timeLimit(.minutes(1)))
struct ChildProcessTests {
    private static let shell = URL(fileURLWithPath: "/bin/sh")

    @Test("A child's first line arrives while it runs, and an exit that outlives its deadline kills it")
    func anAbandonedExitKillsTheChild() async throws {
        let child = try ChildProcess(Self.shell, ["-c", "echo listening; exec sleep 30"])
        #expect(try await child.firstLine() == "listening")
        // deadline-under-test - the deadline firing is the asserted outcome
        await #expect(throws: TestFailure.self) { try await child.exit(timeout: 0.5) }
        #expect(try await child.exit().status == SIGKILL)
    }

    @Test("A child's output and errors are read as it writes them, past what a pipe holds")
    func bothPipesDrain() async throws {
        let bytes = 1 << 18
        let ran = try await ChildProcess(
            Self.shell, ["-c", "head -c \(bytes) /dev/zero; head -c \(bytes) /dev/zero >&2"]
        ).exit()
        #expect(ran.status == 0)
        #expect(ran.output.count == bytes)
        #expect(ran.errors.count == bytes)
    }
}
#endif
