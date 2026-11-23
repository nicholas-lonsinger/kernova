#if canImport(Darwin) || os(Linux)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import KernovaAgentCore
@testable import KernovaAgentRuntime
import KernovaAgentSimulation
import KernovaDigest
import KernovaLogging
import KernovaPortableTestSupport
import KernovaWire
import SwiftProtobuf
import Testing

@testable import KernovaAgentInstall

/// An install root in a scratch directory as `kernova-agent install` leaves it: slot `a` holds the installed
/// agent, `current` points at it, and `state.json` records it.
final class SlotFixture {
    let directory: PortableScratchDirectory
    let root: String

    init() throws {
        directory = try PortableScratchDirectory(prefix: "kernova-slots")
        root = directory.path + "/kernova-agent"
        try FileManager.default.createDirectory(atPath: root + "/slots/a", withIntermediateDirectories: true)
        try Data("installed agent".utf8).write(to: URL(fileURLWithPath: root + "/slots/a/" + TestLander.name))
        try FileManager.default.createSymbolicLink(atPath: root + "/current", withDestinationPath: "slots/a")
        try write(InstallState.fresh(slot: "a", payloadSHA256: "aa", versionLabel: "1.0"))
    }

    func slotRoot() throws -> SlotRoot { try SlotRoot(path: root) }

    func state() throws -> InstallState {
        try InstallState.decoded(Array(try Data(contentsOf: URL(fileURLWithPath: root + "/state.json"))))
    }

    func write(_ state: InstallState) throws {
        try Data(try state.encoded()).write(to: URL(fileURLWithPath: root + "/state.json"))
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
}

/// A lander of one file, `agent`, in its slot, staged until it publishes. A write can be made to fail with an
/// errno, and a publish to refuse.
struct TestLander: PayloadLander {
    static let name = "agent"
    static let stagedName = KernovaAgentInstall.stagedName(of: name)

    var writeFailure: Int32?
    var refusal: PayloadRefusal?

    var format: PayloadFormat { .executable }

    func install(
        _ payload: InstallPayloadReader, as name: String, in slot: borrowing InstallDirectory<Installer.Failure>
    ) throws(Installer.Failure) {
        try slot.writeFile(name, mode: 0o755) { file throws(Installer.Failure) in
            try payload.read { piece throws(Installer.Failure) in try file.write(piece) }
        }
    }

    func beginUpdate(in slot: String, of root: SlotRoot) throws(SlotRoot.Failure) -> any PayloadLanding {
        let file = try root.openSlot(slot).stage(Self.name)
        return Landing(lander: self, file: file)
    }

    final class Landing: PayloadLanding, @unchecked Sendable {
        let lander: TestLander
        var file: StagedFile<SlotRoot.Failure>?

        init(lander: TestLander, file: consuming StagedFile<SlotRoot.Failure>) {
            self.lander = lander
            self.file = .some(file)
        }

        func write(_ bytes: UnsafeRawBufferPointer) throws(SlotRoot.Failure) {
            if let failure = lander.writeFailure {
                throw SlotRoot.Failure(operation: "write", path: TestLander.stagedName, errno: failure)
            }
            try file?.write(bytes)
        }

        func publish() throws(PayloadRefusal) {
            guard let file = file.take() else { preconditionFailure("a publish after the landing ended") }
            let refusal: PayloadRefusal?
            do {
                refusal = try file.publish(mode: 0o755) { [lander] _ in lander.refusal }
            } catch {
                throw PayloadRefusal(.updateInstallFailed, "\(error)", errno: error.errno, rejectsPayload: false)
            }
            if let refusal { throw refusal }
        }

        func discard() {
            file.take()?.discard()
        }
    }
}

/// One installer over a fixture, with what it reports and every relaunch and confirmation it asks for.
struct InstallerRun {
    let installer: SlotUpdateInstaller
    let reports = BlockingInbox<UpdateInput>()
    let switched = BlockingInbox<Void>()
    let confirmed = BlockingInbox<Void>()

    init(_ fixture: SlotFixture, running slot: String = "a", lander: TestLander = TestLander()) throws {
        let (switched, confirmed) = (switched, confirmed)
        installer = SlotUpdateInstaller(
            root: try fixture.slotRoot(), runningSlot: slot, lander: lander,
            logger: KernovaLogger(subsystem: "app.kernova.tests", category: "Update", sink: .init { _, _, _, _ in }),
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

    static func available(rejected: Data? = nil, code: ErrorCode? = nil) -> UpdateInput {
        .availability(
            .available(
                UpdateOffer(formats: [.executable], rejected: rejected.map { RejectedPayload(hash: $0, code: code) })))
    }

    /// Writes `bytes` in three pieces, each reported consumed.
    static func write(_ run: InstallerRun, _ bytes: Data = bytes) async throws {
        let third = bytes.count / 3
        let pieces = [bytes[..<third], bytes[third..<(2 * third)], bytes[(2 * third)...]]
        for piece in pieces { run.installer.write(id, Data(piece)) }
        #expect(try await run.reports.next(3) == pieces.map { .consumed(id, $0.count) })
    }
}

@Suite("The slot update installer")
struct SlotUpdateInstallerTests {
    @Test("write, complete and switch: the payload lands in the spare slot, current moves, the switch is pending")
    func switches() async throws {
        let fixture = try SlotFixture()
        let run = try InstallerRun(fixture)
        _ = try await run.reports.next()
        try await Payloads.write(run)
        run.installer.complete(Payloads.id, Payloads.manifest)
        #expect(try await run.reports.next() == .installed(Payloads.id))
        _ = try await run.switched.next()

        #expect(fixture.contents("slots/b/" + TestLander.name) == Payloads.bytes)
        #expect(!fixture.exists("slots/b/" + TestLander.stagedName))
        #expect(fixture.link("current") == "slots/b")
        #expect(fixture.link("rollback") == "slots/a")
        #expect(fixture.contents("switch-pending") == Data())
        let hash = lowercaseHex(Payloads.hash)
        let state = try fixture.state()
        #expect(state.active == "b")
        #expect(state.slots["b"] == InstallState.Slot(payloadSHA256: hash, versionLabel: "2.0"))
        #expect(state.pendingSwitch == InstallState.Switch(from: "a", to: "b", payloadSHA256: hash))
        #expect(state.rejected == nil)
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
    func rejects(manifest: UpdateManifestValue, code: ErrorCode) async throws {
        let fixture = try SlotFixture()
        let run = try InstallerRun(fixture)
        _ = try await run.reports.next()
        try await Payloads.write(run)
        run.installer.complete(Payloads.id, manifest)
        #expect(try await run.reports.next() == Payloads.available(rejected: manifest.payloadHash, code: code))
        guard case .rejected(let id, let error) = try await run.reports.next() else {
            Issue.record("no rejection")
            return
        }
        #expect(id == Payloads.id)
        #expect(error.code == code)
        try Self.expectUnswitched(fixture)
        #expect(try fixture.state().rejected?.payloadSHA256 == lowercaseHex(manifest.payloadHash))
    }

    /// Switches the fixture to slot b through the installer, as the running version a does.
    static func switchToB(_ fixture: SlotFixture) async throws {
        let run = try InstallerRun(fixture)
        _ = try await run.reports.next()
        try await Payloads.write(run)
        run.installer.complete(Payloads.id, Payloads.manifest)
        #expect(try await run.reports.next() == .installed(Payloads.id))
    }

    static func expectUnswitched(_ fixture: SlotFixture) throws {
        #expect(fixture.link("current") == "slots/a")
        #expect(!fixture.exists("switch-pending"))
        #expect(!fixture.exists("slots/b/" + TestLander.name))
        #expect(!fixture.exists("slots/b/" + TestLander.stagedName))
        #expect(try fixture.state().pendingSwitch == nil)
    }
}

@Suite("The rollback check")
struct RollbackCheckTests {
    final class Kills: @unchecked Sendable {
        var pids: [UInt32] = []
    }

    /// A service manager whose peer runs as `pid`.
    struct Manager: ServiceManager {
        var pid: UInt32
        func peerProcessID() -> UInt32 { pid }
    }

    static func check(_ fixture: SlotFixture, mainPID: UInt32 = 4242, kills: Kills) throws -> RollbackCheck {
        RollbackCheck(
            root: try fixture.slotRoot(), serviceManager: Manager(pid: mainPID), kill: { kills.pids.append($0) })
    }

    @Test("Runs 1–4 count and change nothing; run 5 reverts, kills the new version, and the old one records it")
    func reverts() async throws {
        let fixture = try SlotFixture()
        try await SlotUpdateInstallerTests.switchToB(fixture)
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

        // The service manager restarts the peer through current: the previous version, which records the payload.
        let previous = try InstallerRun(fixture, running: "a")
        #expect(try await previous.reports.next() == Payloads.available(rejected: Payloads.hash))
        let state = try fixture.state()
        #expect(state.rejected?.payloadSHA256 == lowercaseHex(Payloads.hash))
        #expect(state.pendingSwitch == nil)
        #expect(state.active == "a")
        #expect(!fixture.exists("switch-rejected"))
    }

    @Test("A unit with no main process — waiting to restart — is reverted and nothing is killed")
    func revertsWithoutProcess() async throws {
        let fixture = try SlotFixture()
        try await SlotUpdateInstallerTests.switchToB(fixture)
        let kills = Kills()
        let check = try Self.check(fixture, mainPID: 0, kills: kills)
        for _ in 1..<RollbackCheck.runsToRevert { _ = try check.run() }
        #expect(try check.run() == .reverted(killed: nil))
        #expect(kills.pids.isEmpty)
        #expect(fixture.link("current") == "slots/a")
    }
}

@Suite("Slot metadata")
struct SlotMetadataTests {
    @Test("A fresh install's state.json names no switch and no rejected hash; both round-trip under their keys")
    func stateKeys() throws {
        let fresh = String(
            decoding: try InstallState.fresh(slot: "a", payloadSHA256: "aa", versionLabel: "1").encoded(), as: UTF8.self
        )
        #expect(!fresh.contains("switch"))
        #expect(!fresh.contains("rejected"))
        var state = InstallState.fresh(slot: "a", payloadSHA256: "aa", versionLabel: "1")
        state.pendingSwitch = InstallState.Switch(from: "a", to: "b", payloadSHA256: "bb")
        state.rejected = .init(payloadSHA256: "cc", code: .updateLaunchRefused)
        let encoded = try state.encoded()
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.contains(#""switch""#))
        #expect(text.contains(#""rejectedPayloadSHA256" : "cc""#))
        #expect(text.contains(#""rejectedPayloadCode" : 127"#))
        #expect(try InstallState.decoded(encoded) == state)
    }

    @Test("A rejected hash recorded with no code reads back with none, and a code with no hash is not read")
    func rejectionWithoutCode() throws {
        let hashOnly = #"{"active": "a", "slots": {}, "rejectedPayloadSHA256": "cc"}"#
        #expect(try InstallState.decoded(Array(hashOnly.utf8)).rejected == .init(payloadSHA256: "cc"))
        let codeOnly = #"{"active": "a", "slots": {}, "rejectedPayloadCode": 127}"#
        #expect(try InstallState.decoded(Array(codeOnly.utf8)).rejected == nil)
    }
}
#endif
