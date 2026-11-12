#if os(Linux)
import Foundation
import Glibc
import KernovaAgentCore
import KernovaPortableTestSupport
import KernovaSynchronization
import KernovaWire
import Testing

@testable import KernovaAgentInstall
@testable import KernovaLinuxAgent

@Suite("The executable lander")
struct ExecutableLanderTests {
    /// An install root holding slot `a`'s binary, in a scratch directory.
    final class Root {
        let directory: PortableScratchDirectory
        let path: String

        init() throws {
            directory = try PortableScratchDirectory(prefix: "kernova-lander")
            path = directory.path + "/kernova-agent"
            try FileManager.default.createDirectory(atPath: path + "/slots/a", withIntermediateDirectories: true)
            try Data("installed agent".utf8).write(to: URL(fileURLWithPath: path + "/slots/a/kernova-agent"))
        }

        func contents(_ name: String) -> Data? { FileManager.default.contents(atPath: path + "/" + name) }

        func exists(_ name: String) -> Bool {
            var info = stat()
            return lstat(path + "/" + name, &info) == 0
        }

        func mode(_ name: String) -> mode_t? {
            var info = stat()
            return lstat(path + "/" + name, &info) == 0 ? info.st_mode & 0o7777 : nil
        }
    }

    static let bytes = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) })
    static let staged = stagedName(of: "kernova-agent")
    static let stagedInB = "slots/b/" + staged

    /// A lander whose self-test answers `outcome`, recording the path it was asked to run.
    static func lander(selfTest outcome: SelfTest.Outcome = .passed, ran: Locked<[String]>? = nil) -> ExecutableLander {
        var lander = ExecutableLander()
        lander.system.selfTest = { path in
            ran?.withLock { $0.append(path) }
            return outcome
        }
        return lander
    }

    static func write(_ landing: any PayloadLanding, _ bytes: Data = bytes) throws {
        let third = bytes.count / 3
        for piece in [bytes[..<third], bytes[third..<(2 * third)], bytes[(2 * third)...]] {
            try Data(piece).withUnsafeBytes { buffer throws(SlotRoot.Failure) in try landing.write(buffer) }
        }
    }

    @Test("An update lands as the slot's binary, mode 0755, its staged file gone, after a self-test of the staged file")
    func publishes() throws {
        let root = try Root()
        let ran = Locked<[String]>([])
        let lander = Self.lander(ran: ran)
        #expect(lander.format == .executable)
        let landing = try lander.beginUpdate(in: "b", of: try SlotRoot(path: root.path))
        try Self.write(landing)
        try landing.publish()
        #expect(ran.withLock { $0 } == [root.path + "/" + Self.stagedInB])
        #expect(root.contents("slots/b/kernova-agent") == Self.bytes)
        #expect(root.mode("slots/b/kernova-agent") == 0o755)
        #expect(!root.exists(Self.stagedInB))
        #expect(root.contents("slots/a/kernova-agent") == Data("installed agent".utf8))
    }

    @Test("A staged binary whose self-test fails is refused, the payload at fault, and removed")
    func selfTestFails() throws {
        let root = try Root()
        let landing = try Self.lander(selfTest: .exited(1)).beginUpdate(in: "b", of: try SlotRoot(path: root.path))
        try Self.write(landing)
        let refusal = try #require(throws: PayloadRefusal.self) { try landing.publish() }
        #expect(refusal.code == .updateInstallFailed)
        #expect(refusal.rejectsPayload)
        #expect(!root.exists(Self.stagedInB))
        #expect(!root.exists("slots/b/kernova-agent"))
    }

    @Test("A write failing ENOSPC throws its errno, and discarding drops the staged file")
    func diskFull() throws {
        let root = try Root()
        let full = InterposedFileSystem(writeFailure: ENOSPC)
        let landing = try Self.lander().beginUpdate(in: "b", of: try SlotRoot(path: root.path, fileSystem: full))
        let failure = try #require(throws: SlotRoot.Failure.self) { try Self.write(landing) }
        #expect(failure.errno == ENOSPC)
        landing.discard()
        #expect(!root.exists(Self.stagedInB))
    }

    @Test("discard drops the staged file and leaves the slot's binary")
    func discard() throws {
        let root = try Root()
        let landing = try Self.lander().beginUpdate(in: "a", of: try SlotRoot(path: root.path))
        try Self.write(landing)
        #expect(root.exists("slots/a/" + Self.staged))
        landing.discard()
        #expect(!root.exists("slots/a/" + Self.staged))
        #expect(root.contents("slots/a/kernova-agent") == Data("installed agent".utf8))
    }
}

@Suite("The user units' refresh")
struct RefreshTests {
    @Test("The user scope's unit refresh writes exactly the install's units and autostart entry, then reloads")
    func refreshUnits() {
        let layout = InstallLayout.user(
            root: "/home/pbear/.local/share/kernova-agent", configHome: "/home/pbear/.config")
        let plan = InstallPlan.refreshUnits(layout)
        #expect(plan.writes == InstallPlan.install(layout).writes)
        #expect(plan.treeWrites.isEmpty && plan.treeRemovals.isEmpty && plan.before.isEmpty && !plan.removesRoot)
        #expect(plan.after.map(\.arguments) == [["systemctl", "--user", "daemon-reload"]])
    }
}
#endif
