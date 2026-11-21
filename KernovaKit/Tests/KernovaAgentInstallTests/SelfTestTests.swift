#if canImport(Darwin) || os(Linux)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing

@testable import KernovaAgentInstall

@Suite("The self-test")
struct SelfTestTests {
    /// A stand-in, checked in: Linux refuses to run a file some process holds open for writing, and a child this
    /// process spawns concurrently can inherit the descriptor of a file it writes.
    static func standIn(_ name: String) -> String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("StandIns/" + name).path
    }

    @Test("The self-test passes a binary that runs and exits 0, and fails every other")
    func selfTest() {
        #expect(SelfTest.run(Self.standIn("exits-0")) == .passed)
        #expect(SelfTest.run(Self.standIn("exits-3")) == .exited(3))
        #expect(SelfTest.run(Self.standIn("sleeps"), limit: .milliseconds(200)) == .timedOut)
        #expect(SelfTest.run(Self.standIn("not-executable")) == .couldNotStart(EACCES))
        #expect(SelfTest.run(Self.standIn("missing")) == .couldNotStart(ENOENT))
    }
}
#endif
