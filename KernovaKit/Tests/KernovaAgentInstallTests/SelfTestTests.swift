#if canImport(Darwin) || os(Linux)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import KernovaPortableTestSupport
import Testing

@testable import KernovaAgentInstall

@Suite("The self-test")
struct SelfTestTests {
    /// A script in a scratch directory with `mode`.
    static func script(_ directory: PortableScratchDirectory, _ name: String, _ text: String, mode: mode_t = 0o755)
        throws -> String
    {
        let path = directory.path + "/" + name
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        #expect(chmod(path, mode) == 0)
        return path
    }

    @Test("The self-test passes a binary that runs and exits 0, and fails every other")
    func selfTest() throws {
        let directory = try PortableScratchDirectory(prefix: "kernova-self-test")
        #expect(SelfTest.run(try Self.script(directory, "pass", "#!/bin/sh\nexit 0\n")) == .passed)
        #expect(SelfTest.run(try Self.script(directory, "fail", "#!/bin/sh\nexit 3\n")) == .exited(3))
        #expect(
            SelfTest.run(try Self.script(directory, "hang", "#!/bin/sh\nexec sleep 30\n"), limit: .milliseconds(200))
                == .timedOut)
        #expect(
            SelfTest.run(try Self.script(directory, "plain", "#!/bin/sh\nexit 0\n", mode: 0o644))
                == .couldNotStart(EACCES))
        #expect(SelfTest.run(directory.path + "/missing") == .couldNotStart(ENOENT))
    }
}
#endif
