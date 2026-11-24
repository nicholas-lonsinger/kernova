import Cocoa
import CoreServices
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// The dictionary's `snapshot`: what a script reads of one, and which snapshot
/// `make`, `revert to` and `delete` land on, with what consent.
///
/// A script's own events are dispatched to the test host (``ScriptHost``) and
/// answered by the gateway under test.
@Suite("VM snapshot scripting", .caseScoped)
@MainActor
struct VMSnapshotScriptingTests {
    /// A gateway whose library read has landed.
    private func makeGateway(_ wired: WiredCommandCore, host: ScriptHost) async -> VMScriptingGateway {
        let readiness = LibraryReadiness(awaitReady: {})
        await readiness.ready()
        return VMScriptingGateway(
            commands: wired.core, readiness: readiness, prepareToSurface: {}, runtime: host.runtime)
    }

    /// A stopped VM listing `snapshots`, each with a captured configuration a
    /// revert can restore.
    @discardableResult
    private func register(
        in wired: WiredCommandCore, name: String, snapshots: [VMSnapshot], hostState: VMHostState = VMHostState()
    ) -> VMInstance {
        let instance = wired.register(name: name, snapshots: snapshots, hostState: hostState)
        for snapshot in snapshots {
            wired.machineFiles.setCapturedConfiguration(instance.configuration, for: snapshot.id)
        }
        return instance
    }

    // MARK: - Script references

    /// `virtual machine "<name>"`.
    fileprivate static func vm(named name: String) -> NSAppleEventDescriptor {
        ScriptEvent.element("KvVM", named: name)
    }

    /// `snapshot "<name>" of virtual machine "<vm>"`.
    private static func snapshot(named name: String, of vm: String) -> NSAppleEventDescriptor {
        ScriptEvent.element("KvSn", named: name, of: Self.vm(named: vm))
    }

    /// `snapshot id "<id>" of virtual machine "<vm>"`.
    private static func snapshot(_ snapshot: VMSnapshot, of vm: String) -> NSAppleEventDescriptor {
        ScriptEvent.element("KvSn", id: snapshot.id.uuidString, of: Self.vm(named: vm))
    }

    /// `revert to <reference> [with confirmation]`.
    private static func revert(to reference: NSAppleEventDescriptor, confirmation: Bool) -> NSAppleEventDescriptor {
        ScriptEvent.verb("Rvrt", reference, confirmation: confirmation)
    }

    // MARK: - Verbs

    /// The ways a script names the VM a `make new snapshot` is made at.
    enum MakeForm: CaseIterable, Sendable {
        /// `make new snapshot at virtual machine "Alpha" …`
        case atTheVM
        /// `make new snapshot at end of snapshots of virtual machine "Alpha" …`
        case atTheEndOfItsSnapshots
        /// `tell virtual machine "Alpha" to make new snapshot …`
        case toldTheVM

        /// The event, as AppleScript sends this form, with `properties`.
        @MainActor
        func event(properties: [String: NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
            let alpha = VMSnapshotScriptingTests.vm(named: "Alpha")
            return switch self {
            case .atTheVM: ScriptEvent.make(new: "KvSn", at: alpha, properties: properties)
            case .atTheEndOfItsSnapshots:
                ScriptEvent.make(
                    new: "KvSn", at: ScriptEvent.end(of: ScriptEvent.every("KvSn", of: alpha)), properties: properties)
            case .toldTheVM: ScriptEvent.told(ScriptEvent.make(new: "KvSn", properties: properties), to: alpha)
            }
        }
    }

    @Test(
        "make answers the snapshot it took by a reference revert to lands on, which fails once it is deleted",
        arguments: MakeForm.allCases)
    func aTakenSnapshotIsTheReferenceItsVerbsLandOn(form: MakeForm) async throws {
        let virtualization = MockVirtualizationService()
        let wired = WiredCommandCore(virtualization: virtualization)
        let earlier = VMSnapshot(name: "Earlier", kind: .cold, macAddress: nil)
        let alpha = register(in: wired, name: "Alpha", snapshots: [earlier])
        let host = ScriptHost()
        let gateway = await makeGateway(wired, host: host)

        let made = try await host.send(
            form.event(properties: [
                "pnam": NSAppleEventDescriptor(string: "Before the run"),
                "KvNo": NSAppleEventDescriptor(string: "a note"),
            ]),
            to: gateway)
        try #require(made.errorNumber == 0, "\(form): \(made.errorString ?? "")")
        let taken = try #require(alpha.snapshotManifest.snapshots.first { $0.id != earlier.id })
        #expect(taken.name == "Before the run")
        #expect(taken.notes == "a note")
        let reference = try #require(made.descriptor)

        let reverted = try await host.send(Self.revert(to: reference, confirmation: true), to: gateway)
        #expect(reverted.errorNumber == 0)
        #expect(virtualization.revertedSnapshots.map(\.id) == [taken.id])
        let deleted = try await host.send(ScriptEvent.delete(reference, confirmation: true), to: gateway)
        #expect(deleted.errorNumber == 0)
        #expect(wired.machineFiles.discardedIDs == [taken.id])
        let stale = try await host.send(Self.revert(to: reference, confirmation: true), to: gateway)

        #expect(stale.errorNumber == Int(errAENoSuchObject))
        #expect(virtualization.revertedSnapshots.map(\.id) == [taken.id])
        #expect(alpha.snapshotManifest.snapshots.map(\.id) == [earlier.id])
    }

    @Test("revert to and delete refuse without with confirmation, naming it, then land on the snapshot named with it")
    func revertAndDeleteTakeTheirConsent() async throws {
        let virtualization = MockVirtualizationService()
        let wired = WiredCommandCore(virtualization: virtualization)
        let clean = VMSnapshot(name: "Clean", kind: .cold, macAddress: nil)
        let dirty = VMSnapshot(name: "Dirty", kind: .cold, macAddress: nil)
        let alpha = register(in: wired, name: "Alpha", snapshots: [clean, dirty])
        let host = ScriptHost()
        let gateway = await makeGateway(wired, host: host)
        let revertClean = { Self.revert(to: Self.snapshot(named: "Clean", of: "Alpha"), confirmation: $0) }
        let deleteDirty = { ScriptEvent.delete(Self.snapshot(named: "Dirty", of: "Alpha"), confirmation: $0) }

        let unconsented = [
            try await host.send(revertClean(false), to: gateway),
            try await host.send(deleteDirty(false), to: gateway),
        ]
        let prompts = [
            VMCommandCore.revertPrompt(clean, on: alpha), VMCommandCore.deleteSnapshotPrompt(dirty, on: alpha),
        ]
        for (reply, prompt) in zip(unconsented, prompts) {
            #expect(reply.errorNumber == Int(errAEEventFailed))
            #expect(
                reply.errorString
                    == CommandError.confirmationRequired(prompt).appleEventErrorString(
                        consenting: CommandError.withConfirmation))
            #expect(reply.errorString?.contains("with confirmation") == true)
        }
        #expect(virtualization.revertedSnapshots.isEmpty)
        #expect(wired.machineFiles.discardedIDs.isEmpty)

        let reverted = try await host.send(revertClean(true), to: gateway)
        let deleted = try await host.send(deleteDirty(true), to: gateway)

        #expect(reverted.errorNumber == 0)
        #expect(deleted.errorNumber == 0)
        #expect(virtualization.revertedSnapshots.map(\.id) == [clean.id])
        #expect(alpha.snapshotManifest.currentID == clean.id)
        #expect(wired.machineFiles.discardedIDs == [dirty.id])
        #expect(alpha.snapshotManifest.snapshots.map(\.id) == [clean.id])
    }

    @Test("A snapshot reference lands on its own VM where another VM lists a snapshot under the same identifier")
    func aSnapshotReferenceNamesItsOwnVM() async throws {
        let virtualization = MockVirtualizationService()
        let wired = WiredCommandCore(virtualization: virtualization)
        // A clone carries its source's snapshot identifiers.
        let baseline = VMSnapshot(name: "Baseline", kind: .cold, macAddress: nil)
        let source = register(in: wired, name: "Source", snapshots: [baseline])
        let copy = register(in: wired, name: "Copy", snapshots: [baseline])
        let host = ScriptHost()
        let gateway = await makeGateway(wired, host: host)

        let reverted = try await host.send(
            Self.revert(to: Self.snapshot(baseline, of: "Copy"), confirmation: true), to: gateway)
        let deleted = try await host.send(
            ScriptEvent.delete(Self.snapshot(baseline, of: "Source"), confirmation: true), to: gateway)

        #expect(reverted.errorNumber == 0)
        #expect(deleted.errorNumber == 0)
        #expect(copy.snapshotManifest.currentID == baseline.id)
        #expect(source.snapshotManifest.currentID == nil)
        #expect(source.snapshotManifest.isEmpty)
        #expect(copy.snapshotManifest.snapshots.map(\.id) == [baseline.id])
    }

    @Test("A name two snapshots answer to refuses, naming both, and neither is reverted to or deleted")
    func aSharedNameRefuses() async throws {
        let virtualization = MockVirtualizationService()
        let wired = WiredCommandCore(virtualization: virtualization)
        let first = VMSnapshot(name: "Clean", kind: .cold, macAddress: nil)
        let second = VMSnapshot(name: "clean", kind: .cold, macAddress: nil)
        let alpha = register(in: wired, name: "Alpha", snapshots: [first, second])
        let host = ScriptHost()
        let gateway = await makeGateway(wired, host: host)
        let named = Self.snapshot(named: "Clean", of: "Alpha")

        let replies = [
            try await host.send(Self.revert(to: named, confirmation: true), to: gateway),
            try await host.send(ScriptEvent.delete(named, confirmation: true), to: gateway),
        ]

        for reply in replies {
            #expect(reply.errorNumber == Int(errAENoSuchObject))
            #expect(reply.errorString?.contains(first.id.uuidString) == true)
            #expect(reply.errorString?.contains(second.id.uuidString) == true)
        }
        #expect(virtualization.revertedSnapshots.isEmpty)
        #expect(wired.machineFiles.discardedIDs.isEmpty)
        #expect(alpha.snapshotManifest.snapshots.map(\.id) == [first.id, second.id])
    }

    @Test("A delete of a list of snapshot references takes its consent, then deletes each one it names")
    func aListOfSnapshotsIsDeleted() async throws {
        let wired = WiredCommandCore()
        let keep = VMSnapshot(name: "Keep", kind: .cold, macAddress: nil)
        let older = VMSnapshot(name: "Older", kind: .cold, macAddress: nil)
        let oldest = VMSnapshot(name: "Oldest", kind: .cold, macAddress: nil)
        let alpha = register(in: wired, name: "Alpha", snapshots: [keep, older, oldest])
        let host = ScriptHost()
        let gateway = await makeGateway(wired, host: host)
        // `set old to …` holds a list of references, which `delete old` sends.
        let old = NSAppleEventDescriptor.list()
        old.insert(Self.snapshot(older, of: "Alpha"), at: 1)
        old.insert(Self.snapshot(oldest, of: "Alpha"), at: 2)

        let unconsented = try await host.send(ScriptEvent.delete(old, confirmation: false), to: gateway)
        #expect(unconsented.errorNumber == Int(errAEEventFailed))
        #expect(unconsented.errorString?.contains("with confirmation") == true)
        #expect(wired.machineFiles.discardedIDs.isEmpty)
        let deleted = try await host.send(ScriptEvent.delete(old, confirmation: true), to: gateway)

        #expect(deleted.errorNumber == 0)
        #expect(wired.machineFiles.discardedIDs == [older.id, oldest.id])
        #expect(alpha.snapshotManifest.snapshots.map(\.id) == [keep.id])
    }

    // MARK: - Reads

    /// One `snapshot` as `get properties` answers it.
    private struct SnapshotRow: Equatable {
        let id: String?
        let name: String?
        let notes: String?
        let kind: FourCharCode?
        let created: Date?
        let current: Bool?
        let ephemeralBaseline: Bool?
        /// `nil` for missing value.
        let size: Double?
        let privateSize: Double?

        init(
            id: String?, name: String?, notes: String?, kind: FourCharCode?, created: Date?, current: Bool?,
            ephemeralBaseline: Bool?, size: Double?, privateSize: Double?
        ) {
            self.id = id
            self.name = name
            self.notes = notes
            self.kind = kind
            self.created = created
            self.current = current
            self.ephemeralBaseline = ephemeralBaseline
            self.size = size
            self.privateSize = privateSize
        }

        init(_ record: NSAppleEventDescriptor) {
            func field(_ code: String) -> NSAppleEventDescriptor? {
                record.forKeyword(ScriptEvent.code(code))
            }
            func number(_ code: String) -> Double? {
                guard let value = field(code), value.descriptorType != typeType else { return nil }
                return value.doubleValue
            }
            self.init(
                id: field("ID  ")?.stringValue, name: field("pnam")?.stringValue, notes: field("KvNo")?.stringValue,
                kind: field("KvKd")?.enumCodeValue, created: field("ascd")?.dateValue,
                current: field("KvCu")?.booleanValue, ephemeralBaseline: field("KvEb")?.booleanValue,
                size: number("ptsz"), privateSize: number("KvPz"))
        }
    }

    @Test("Every snapshot answers each field of its listing and the sizes measured for the command, newest first")
    func propertiesAnswerFromTheListingAndTheMeasurement() async throws {
        let wired = WiredCommandCore()
        let warm = VMSnapshot(
            name: "Warm", createdAt: Date(timeIntervalSince1970: 3_000), notes: "booted", kind: .warm, macAddress: nil)
        let current = VMSnapshot(
            name: "Current", createdAt: Date(timeIntervalSince1970: 2_000), kind: .cold, macAddress: nil)
        let baseline = VMSnapshot(
            name: "Baseline", createdAt: Date(timeIntervalSince1970: 1_000), kind: .cold, macAddress: nil)
        let alpha = register(
            in: wired, name: "Alpha", snapshots: [baseline, warm, current],
            hostState: VMHostState(ephemeralModeEnabled: true, ephemeralBaselineSnapshotID: baseline.id))
        try await wired.core.revertToSnapshot(.id(alpha.id), snapshot: current.id, consent: .all)
        wired.machineFiles.setSnapshotSize(
            SnapshotSize(bytes: 2_500_000_000, privateBytes: 1_000_000_000), for: warm.id)
        // A volume that can't clone files: no private part.
        wired.machineFiles.setSnapshotSize(SnapshotSize(bytes: 3_000_000_000, privateBytes: nil), for: current.id)
        // `baseline` has no size seeded, so its files read as unreadable.
        let host = ScriptHost()
        let gateway = await makeGateway(wired, host: host)

        let reply = try await host.send(
            ScriptEvent.get(ScriptEvent.property("pALL", of: ScriptEvent.every("KvSn", of: Self.vm(named: "Alpha")))),
            to: gateway)

        #expect(reply.errorNumber == 0)
        #expect(host.suspensions == 1)
        #expect(
            reply.items.map(SnapshotRow.init) == [
                SnapshotRow(
                    id: warm.id.uuidString, name: "Warm", notes: "booted", kind: VMScriptSnapshotKind.warm.code,
                    created: Date(timeIntervalSince1970: 3_000), current: false, ephemeralBaseline: false,
                    size: 2.5, privateSize: 1),
                SnapshotRow(
                    id: current.id.uuidString, name: "Current", notes: "", kind: VMScriptSnapshotKind.cold.code,
                    created: Date(timeIntervalSince1970: 2_000), current: true, ephemeralBaseline: false,
                    size: 3, privateSize: nil),
                SnapshotRow(
                    id: baseline.id.uuidString, name: "Baseline", notes: "", kind: VMScriptSnapshotKind.cold.code,
                    created: Date(timeIntervalSince1970: 1_000), current: false, ephemeralBaseline: true,
                    size: nil, privateSize: nil),
            ])
    }
}
