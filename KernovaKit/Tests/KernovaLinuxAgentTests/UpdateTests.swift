#if os(Linux)
import Foundation
import Glibc
import KernovaAgentCore
@testable import KernovaAgentRuntime
import KernovaAgentSimulation
import KernovaDigest
import KernovaLogging
import KernovaPortableTestSupport
import KernovaWire
import SwiftProtobuf
import Testing

@testable import KernovaLinuxAgent

/// An install root in a scratch directory as `kernova-agent install` leaves it: slot `a` holds the installed
/// agent, `current` points at it, and `state.json` records it.
final class SlotFixture {
    let directory: PortableScratchDirectory
    let root: String

    init() throws {
        directory = try PortableScratchDirectory(prefix: "kernova-slots")
        root = directory.path + "/kernova-agent"
        try FileManager.default.createDirectory(atPath: root + "/slots/a", withIntermediateDirectories: true)
        try Data("installed agent".utf8).write(to: URL(filePath: root + "/slots/a/kernova-agent"))
        try FileManager.default.createSymbolicLink(atPath: root + "/current", withDestinationPath: "slots/a")
        try write(InstallState.fresh(payloadSHA256: "aa", versionLabel: "1.0"))
    }

    func slotRoot() throws -> SlotRoot { try SlotRoot(path: root) }

    func state() throws -> InstallState {
        try InstallState.decoded(Array(try Data(contentsOf: URL(filePath: root + "/state.json"))))
    }

    func write(_ state: InstallState) throws {
        try Data(try state.encoded()).write(to: URL(filePath: root + "/state.json"))
    }

    /// Where the link `name` points.
    func link(_ name: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: root + "/" + name)
    }

    /// Whether `name` exists, never followed.
    func exists(_ name: String) -> Bool {
        var info = stat()
        return lstat(root + "/" + name, &info) == 0
    }

    func contents(_ name: String) -> Data? {
        FileManager.default.contents(atPath: root + "/" + name)
    }

    func mode(_ name: String) -> mode_t? {
        var info = stat()
        return lstat(root + "/" + name, &info) == 0 ? info.st_mode & 0o7777 : nil
    }
}

/// Values a handler on another thread delivers, read in order.
final class Inbox<Value: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    /// Read and written only while `condition` is locked.
    private var values: [Value] = []

    func put(_ value: Value) {
        condition.lock()
        values.append(value)
        condition.broadcast()
        condition.unlock()
    }

    /// The oldest value not yet read, waiting for one to arrive. The backstop only bounds a failure: nothing
    /// a passing test waits for takes more than milliseconds.
    func next() throws -> Value {
        let deadline = Date(timeIntervalSinceNow: 30)
        condition.lock()
        defer { condition.unlock() }
        while values.isEmpty {
            guard condition.wait(until: deadline) || !values.isEmpty else { throw InboxTimeout() }
        }
        return values.removeFirst()
    }

    /// The next `count` values.
    func next(_ count: Int) throws -> [Value] {
        try (0..<count).map { _ in try next() }
    }
}

struct InboxTimeout: Error {}

/// One installer over a fixture, with what it reports and every relaunch and confirmation it asks for.
struct InstallerRun {
    let installer: LinuxUpdateInstaller
    let reports = Inbox<UpdateInput>()
    let switched = Inbox<Void>()
    let confirmed = Inbox<Void>()

    init(
        _ fixture: SlotFixture, running slot: String = "a",
        selfTest: SelfTest.Outcome = .passed,
        write: (@Sendable (Int32, UnsafeRawBufferPointer) -> Int)? = nil
    ) throws {
        var system = LinuxUpdateInstaller.System()
        system.selfTest = { _ in selfTest }
        if let write { system.write = write }
        let (switched, confirmed) = (switched, confirmed)
        installer = LinuxUpdateInstaller(
            root: try fixture.slotRoot(), runningSlot: slot, system: system,
            logger: KernovaLogger(subsystem: "app.kernova.tests", category: "Update") { _, _, _, _ in },
            onSwitched: { switched.put(()) }, onConfirmed: { confirmed.put(()) })
        let reports = reports
        installer.start(reporter: UpdateReporter { reports.put($0) })
    }
}

enum Payloads {
    static let id = UpdatePullID(generation: ConnectionGeneration(rawValue: 1), stream: StreamID(rawValue: 1))
    static let bytes = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) })
    static let hash = Data(KernovaDigest.SHA256.hash(Array(bytes)))
    static let manifest = UpdateManifestValue(
        payloadHash: hash, payloadSize: UInt64(bytes.count), format: .executable, versionLabel: "2.0")

    static func available(rejected: Data? = nil) -> UpdateInput {
        .availability(.available(UpdateOffer(formats: [.executable], rejectedHash: rejected)))
    }

    /// Writes `bytes` in three pieces, each reported consumed.
    static func write(_ run: InstallerRun, _ bytes: Data = bytes) throws {
        let third = bytes.count / 3
        let pieces = [bytes[..<third], bytes[third..<(2 * third)], bytes[(2 * third)...]]
        for piece in pieces { run.installer.write(id, Data(piece)) }
        #expect(try run.reports.next(3) == pieces.map { .consumed(id, $0.count) })
    }
}

@Suite("The Linux update installer")
struct LinuxUpdateInstallerTests {
    @Test("It advertises the executable format and no rejected hash on a fresh install")
    func availability() throws {
        let fixture = try SlotFixture()
        let run = try InstallerRun(fixture)
        #expect(try run.reports.next() == Payloads.available())
    }

    @Test("write, complete and switch: the payload lands in the spare slot, current moves, the switch is pending")
    func switches() throws {
        let fixture = try SlotFixture()
        let run = try InstallerRun(fixture)
        _ = try run.reports.next()
        try Payloads.write(run)
        run.installer.complete(Payloads.id, Payloads.manifest)
        #expect(try run.reports.next() == .installed(Payloads.id))
        _ = try run.switched.next()

        #expect(fixture.contents("slots/b/kernova-agent") == Payloads.bytes)
        #expect(fixture.mode("slots/b/kernova-agent") == 0o755)
        #expect(!fixture.exists("slots/b/" + LinuxUpdateInstaller.partialName))
        #expect(fixture.link("current") == "slots/b")
        #expect(fixture.link("rollback") == "slots/a")
        #expect(fixture.contents("switch-pending") == Data())
        let hash = lowercaseHex(Payloads.hash)
        let state = try fixture.state()
        #expect(state.active == "b")
        #expect(state.slots["b"] == InstallState.Slot(payloadSHA256: hash, versionLabel: "2.0"))
        #expect(state.pendingSwitch == InstallState.Switch(from: "a", to: "b", payloadSHA256: hash))
        #expect(state.rejectedSHA256 == nil)
    }

    @Test(
        "A payload whose hash, size or format is not the manifest's is rejected, recorded, and never switched to",
        arguments: [
            (
                UpdateManifestValue(
                    payloadHash: Data(repeating: 7, count: 32), payloadSize: UInt64(Payloads.bytes.count),
                    format: .executable),
                ErrorCode.updateHashMismatch
            ),
            (
                UpdateManifestValue(
                    payloadHash: Payloads.hash, payloadSize: UInt64(Payloads.bytes.count) + 1, format: .executable),
                .updateSizeMismatch
            ),
            (
                UpdateManifestValue(
                    payloadHash: Payloads.hash, payloadSize: UInt64(Payloads.bytes.count), format: .paxTree),
                .updateFormatUnsupported
            ),
        ])
    func rejects(manifest: UpdateManifestValue, code: ErrorCode) throws {
        let fixture = try SlotFixture()
        let run = try InstallerRun(fixture)
        _ = try run.reports.next()
        try Payloads.write(run)
        run.installer.complete(Payloads.id, manifest)
        #expect(try run.reports.next() == Payloads.available(rejected: manifest.payloadHash))
        guard case .rejected(let id, let error) = try run.reports.next() else {
            Issue.record("no rejection")
            return
        }
        #expect(id == Payloads.id)
        #expect(error.code == code)
        try Self.expectUnswitched(fixture)
        #expect(try fixture.state().rejectedSHA256 == lowercaseHex(manifest.payloadHash))
    }

    @Test("A payload whose self-test fails is rejected and recorded before any switch")
    func selfTestFails() throws {
        let fixture = try SlotFixture()
        let run = try InstallerRun(fixture, selfTest: .exited(1))
        _ = try run.reports.next()
        try Payloads.write(run)
        run.installer.complete(Payloads.id, Payloads.manifest)
        #expect(try run.reports.next() == Payloads.available(rejected: Payloads.hash))
        guard case .rejected(_, let error) = try run.reports.next() else {
            Issue.record("no rejection")
            return
        }
        #expect(error.code == .updateInstallFailed)
        try Self.expectUnswitched(fixture)
    }

    @Test("A write failing ENOSPC fails the pull DISK_FULL, drops the staged file, and ignores the pull's rest")
    func diskFull() throws {
        let fixture = try SlotFixture()
        let run = try InstallerRun(fixture) { _, _ in
            errno = ENOSPC
            return -1
        }
        _ = try run.reports.next()
        run.installer.write(Payloads.id, Payloads.bytes)
        #expect(try run.reports.next() == .failed(Payloads.id, WireError(.diskFull, posixErrno: ENOSPC)))
        run.installer.write(Payloads.id, Payloads.bytes)
        run.installer.complete(Payloads.id, Payloads.manifest)
        // Sequenced behind both on the installer's queue: nothing reported between.
        run.installer.recordRejected(Data(repeating: 1, count: 32))
        #expect(try run.reports.next() == Payloads.available(rejected: Data(repeating: 1, count: 32)))
        try Self.expectUnswitched(fixture)
    }

    @Test("abort drops the staged file")
    func abort() throws {
        let fixture = try SlotFixture()
        let run = try InstallerRun(fixture)
        _ = try run.reports.next()
        try Payloads.write(run)
        #expect(fixture.exists("slots/b/" + LinuxUpdateInstaller.partialName))
        run.installer.abort(Payloads.id)
        run.installer.clearRejected()
        run.installer.recordRejected(Data(repeating: 1, count: 32))
        _ = try run.reports.next()
        #expect(!fixture.exists("slots/b/" + LinuxUpdateInstaller.partialName))
    }

    @Test("recordRejected and clearRejected persist the rejected hash and re-advertise it")
    func rejectedHash() throws {
        let fixture = try SlotFixture()
        let run = try InstallerRun(fixture)
        _ = try run.reports.next()
        let hash = Data(repeating: 0xC3, count: 32)
        run.installer.recordRejected(hash)
        #expect(try run.reports.next() == Payloads.available(rejected: hash))
        #expect(try fixture.state().rejectedSHA256 == lowercaseHex(hash))
        // A later process reads it back.
        let later = try InstallerRun(fixture)
        #expect(try later.reports.next() == Payloads.available(rejected: hash))
        later.installer.clearRejected()
        #expect(try later.reports.next() == Payloads.available())
        #expect(try fixture.state().rejectedSHA256 == nil)
    }

    @Test("The new version confirms the switch to itself once connected: the marker goes, the record clears")
    func confirms() throws {
        let fixture = try SlotFixture()
        try Self.switchToB(fixture)
        let next = try InstallerRun(fixture, running: "b")
        #expect(try next.reports.next() == Payloads.available())
        #expect(try fixture.state().pendingSwitch != nil)
        next.installer.confirm()
        _ = try next.confirmed.next()
        #expect(!fixture.exists("switch-pending"))
        let state = try fixture.state()
        #expect(state.pendingSwitch == nil)
        #expect(state.active == "b")
    }

    @Test("A version the switch did not make current drops the switch as it starts, and confirms nothing")
    func confirmsOnlyItsOwnSwitch() throws {
        let fixture = try SlotFixture()
        try Self.switchToB(fixture)
        // Slot a running again with the switch still pending can only be a crash before current moved: the
        // switch never took effect, and starting drops it.
        try FileManager.default.removeItem(atPath: fixture.root + "/current")
        try FileManager.default.createSymbolicLink(atPath: fixture.root + "/current", withDestinationPath: "slots/a")
        let old = try InstallerRun(fixture, running: "a")
        #expect(try old.reports.next() == Payloads.available())
        old.installer.confirm()
        old.installer.recordRejected(Data(repeating: 1, count: 32))
        _ = try old.reports.next()
        #expect(!fixture.exists("switch-pending"))
        let state = try fixture.state()
        #expect(state.pendingSwitch == nil)
        #expect(state.active == "a")
        #expect(state.rejectedSHA256 == lowercaseHex(Data(repeating: 1, count: 32)))
    }

    /// Switches the fixture to slot b through the installer, as the running version a does.
    static func switchToB(_ fixture: SlotFixture) throws {
        let run = try InstallerRun(fixture)
        _ = try run.reports.next()
        try Payloads.write(run)
        run.installer.complete(Payloads.id, Payloads.manifest)
        #expect(try run.reports.next() == .installed(Payloads.id))
    }

    static func expectUnswitched(_ fixture: SlotFixture) throws {
        #expect(fixture.link("current") == "slots/a")
        #expect(!fixture.exists("switch-pending"))
        #expect(!fixture.exists("slots/b/kernova-agent"))
        #expect(!fixture.exists("slots/b/" + LinuxUpdateInstaller.partialName))
        #expect(try fixture.state().pendingSwitch == nil)
    }
}

@Suite("The rollback check")
struct RollbackCheckTests {
    final class Kills: @unchecked Sendable {
        var pids: [UInt32] = []
    }

    static func check(_ fixture: SlotFixture, mainPID: UInt32 = 4242, kills: Kills) throws -> RollbackCheck {
        RollbackCheck(root: try fixture.slotRoot(), mainPID: { mainPID }, kill: { kills.pids.append($0) })
    }

    @Test("With no switch pending it does nothing")
    func nothingPending() throws {
        let fixture = try SlotFixture()
        let kills = Kills()
        #expect(try Self.check(fixture, kills: kills).run() == .nothingPending)
        #expect(kills.pids.isEmpty)
    }

    @Test("Runs 1–4 count and change nothing; run 5 reverts, kills the new version, and the old one records it")
    func reverts() throws {
        let fixture = try SlotFixture()
        try LinuxUpdateInstallerTests.switchToB(fixture)
        let kills = Kills()
        let check = try Self.check(fixture, kills: kills)
        for runs in 1..<RollbackCheck.runsToRevert {
            #expect(try check.run() == .counted(runs: runs))
            #expect(fixture.link("current") == "slots/b")
            #expect(fixture.exists("switch-pending"))
        }
        #expect(kills.pids.isEmpty)

        #expect(try check.run() == .reverted(killed: 4242))
        #expect(kills.pids == [4242])
        #expect(fixture.link("current") == "slots/a")
        #expect(!fixture.exists("switch-pending"))
        #expect(fixture.exists("switch-rejected"))
        #expect(try check.run() == .nothingPending)

        // systemd restarts the unit through current: the previous version, which records the payload.
        let previous = try InstallerRun(fixture, running: "a")
        #expect(try previous.reports.next() == Payloads.available(rejected: Payloads.hash))
        let state = try fixture.state()
        #expect(state.rejectedSHA256 == lowercaseHex(Payloads.hash))
        #expect(state.pendingSwitch == nil)
        #expect(state.active == "a")
        #expect(!fixture.exists("switch-rejected"))
    }

    @Test("A unit with no main process — waiting to restart — is reverted and nothing is killed")
    func revertsWithoutProcess() throws {
        let fixture = try SlotFixture()
        try LinuxUpdateInstallerTests.switchToB(fixture)
        let kills = Kills()
        let check = try Self.check(fixture, mainPID: 0, kills: kills)
        for _ in 1..<RollbackCheck.runsToRevert { _ = try check.run() }
        #expect(try check.run() == .reverted(killed: nil))
        #expect(kills.pids.isEmpty)
        #expect(fixture.link("current") == "slots/a")
    }

    @Test("A switch confirmed before the reverting run makes the check stand down")
    func confirmedFirst() throws {
        let fixture = try SlotFixture()
        try LinuxUpdateInstallerTests.switchToB(fixture)
        let kills = Kills()
        let check = try Self.check(fixture, kills: kills)
        for _ in 1..<RollbackCheck.runsToRevert { _ = try check.run() }
        let next = try InstallerRun(fixture, running: "b")
        _ = try next.reports.next()
        next.installer.confirm()
        _ = try next.confirmed.next()
        #expect(try check.run() == .nothingPending)
        #expect(kills.pids.isEmpty)
        #expect(fixture.link("current") == "slots/b")
    }

    @Test("A switch reverted before the new version connects is not confirmed")
    func revertedFirst() throws {
        let fixture = try SlotFixture()
        try LinuxUpdateInstallerTests.switchToB(fixture)
        let kills = Kills()
        let check = try Self.check(fixture, kills: kills)
        // The new version is up but has not connected yet.
        let next = try InstallerRun(fixture, running: "b")
        _ = try next.reports.next()
        for _ in 1..<RollbackCheck.runsToRevert { _ = try check.run() }
        #expect(try check.run() == .reverted(killed: 4242))
        next.installer.confirm()
        next.installer.recordRejected(Data(repeating: 1, count: 32))
        _ = try next.reports.next()
        #expect(fixture.exists("switch-rejected"))
        #expect(try fixture.state().pendingSwitch != nil)
    }

    @Test("A marker that names no switch is removed")
    func staleMarker() throws {
        let fixture = try SlotFixture()
        #expect(FileManager.default.createFile(atPath: fixture.root + "/switch-pending", contents: Data()))
        let kills = Kills()
        #expect(try Self.check(fixture, kills: kills).run() == .clearedStaleMarker)
        #expect(!fixture.exists("switch-pending"))
    }
}

@Suite("Slot metadata and the self-test")
struct SlotMetadataTests {
    @Test("A fresh install's state.json names no switch and no rejected hash; both round-trip under their keys")
    func stateKeys() throws {
        let fresh = String(
            decoding: try InstallState.fresh(payloadSHA256: "aa", versionLabel: "1").encoded(), as: UTF8.self)
        #expect(!fresh.contains("switch"))
        #expect(!fresh.contains("rejected"))
        var state = InstallState.fresh(payloadSHA256: "aa", versionLabel: "1")
        state.pendingSwitch = InstallState.Switch(from: "a", to: "b", payloadSHA256: "bb")
        state.rejectedSHA256 = "cc"
        let encoded = try state.encoded()
        #expect(String(decoding: encoded, as: UTF8.self).contains(#""switch""#))
        #expect(try InstallState.decoded(encoded) == state)
    }

    @Test("The user scope's unit refresh writes exactly the install's units and autostart entry, then reloads")
    func refreshUnits() {
        let layout = InstallLayout.user(
            root: "/home/pbear/.local/share/kernova-agent", configHome: "/home/pbear/.config")
        let plan = InstallPlan.refreshUnits(layout)
        #expect(plan.writes == InstallPlan.install(layout).writes)
        #expect(plan.treeWrites.isEmpty && plan.treeRemovals.isEmpty && plan.before.isEmpty && !plan.removesRoot)
        #expect(plan.after.map(\.arguments) == [["systemctl", "--user", "daemon-reload"]])
    }

    /// A script in a scratch directory with `mode`.
    static func script(_ directory: PortableScratchDirectory, _ name: String, _ text: String, mode: mode_t = 0o755)
        throws -> String
    {
        let path = directory.path + "/" + name
        try Data(text.utf8).write(to: URL(filePath: path))
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

@Suite("The rejected hash through the core")
struct RejectedHashThroughTheCoreTests {
    static func updateAvailable(_ manifest: UpdateManifestValue) -> Frame {
        WireFrames.session { message in
            var available = Kernova_V2_UpdateAvailable()
            available.manifest.payloadHash = manifest.payloadHash
            available.manifest.payloadSize = manifest.payloadSize
            available.manifest.format = manifest.format
            available.manifest.versionLabel = manifest.versionLabel
            message.updateAvailable = available
        }
    }

    /// The hash each UPDATE_PULL the peer opened asks for.
    static func pulls(_ run: HostileRun) -> [Data] {
        run.written.compactMap { frame in
            guard frame.type == .open, let open = try? Kernova_V2_Open(serializedBytes: frame.payload),
                open.kind == .updatePull, let body = try? Kernova_V2_UpdatePull(serializedBytes: open.body)
            else { return nil }
            return body.payloadHash
        }
    }

    @Test("A payload the install rejected is not pulled on a later connection until the offer changes")
    func rejectedUntilTheOfferChanges() throws {
        let fixture = try SlotFixture()
        let bad = UpdateManifestValue(
            payloadHash: Data(repeating: 7, count: 32), payloadSize: UInt64(Payloads.bytes.count), format: .executable)
        let first = try InstallerRun(fixture)
        _ = try first.reports.next()
        try Payloads.write(first)
        first.installer.complete(Payloads.id, bad)
        _ = try first.reports.next(2)

        // The next process, and its next connection, offered the same payload.
        let later = try InstallerRun(fixture)
        let availability = try later.reports.next()
        #expect(availability == Payloads.available(rejected: bad.payloadHash))
        let run = HostileRun(local: .peer, seed: 41)
        run.input(.update(availability))
        run.feed([WireFrames.hello(role: .host)], preamble: true)
        run.feed([Self.updateAvailable(bad)])
        #expect(Self.pulls(run).isEmpty)

        // The offer changes: the core clears the rejected hash through the installer, and pulls.
        run.feed([Self.updateAvailable(Payloads.manifest)])
        let effects = run.peerEffects.compactMap { if case .update(let effect) = $0 { effect } else { nil } }
        #expect(effects == [.clearRejected])
        #expect(Self.pulls(run) == [Payloads.hash])
        later.installer.clearRejected()
        #expect(try later.reports.next() == Payloads.available())
        #expect(try fixture.state().rejectedSHA256 == nil)
    }
}
#endif
