import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// What the catalog tells a surface and what the verb does agree, for every
/// operation that can hold a VM: a capability the catalog accepts is one its
/// verb is not refused by admission, and one it refuses is one the verb is.
///
/// A verb may still fail past its gate — a missing item, a consent it asks
/// for, a deadline — which is not admission's answer and not what this pins.
@Suite("VMCapability Agreement Tests", .serialized, .admissionGated)
@MainActor
struct VMCapabilityAgreementTests {
    private let preferences = makeTestPreferences()

    private struct Harness {
        let core: VMCommandCore
        let library: VMLibrary
        let storage: MockVMStorageService
        let snapshots: MockVMBundleMachineFiles
    }

    private func makeHarness() -> Harness {
        let storage = MockVMStorageService()
        let snapshots = MockVMBundleMachineFiles(files: storage.files)
        let fileSystem = MockFileSystem()
        let virtualization = MockVirtualizationService()
        // A shutdown request that lands on a held VM changes nothing: the
        // session the operation holds stays, and nothing waits on it.
        virtualization.guestIgnoresShutdownRequest = true
        let lifecycle = makeTestLifecycle(
            virtualization: virtualization, usbAccessoryService: MockUSBAccessoryService(),
            fileSystem: fileSystem)
        let library = makeWiredLibrary(
            storage: storage, machineFiles: snapshots, lifecycle: lifecycle,
            fileSystem: fileSystem, preferences: preferences)
        // Already past any deadline, so a restart the catalog accepts answers
        // on its power-off deadline instead of waiting on a guest.
        let core = VMCommandCore(
            library: library, lifecycle: lifecycle, storageService: storage,
            diskImageService: MockDiskImageService(), fileSystem: fileSystem,
            preferences: preferences, clock: TestEngineClock())
        return Harness(core: core, library: library, storage: storage, snapshots: snapshots)
    }

    /// The capabilities `capability`'s verb is gated on, or `nil` for one
    /// with no verb.
    ///
    /// Stop, Force Stop and the cold-paused discard are one verb, whose gate
    /// takes either of two capabilities.
    private func gates(of capability: VMCapability) -> [VMCapability]? {
        guard capability.verb != nil else { return nil }
        switch capability {
        case .stop, .discardSavedState: return [.stop, .discardSavedState]
        case .forceStop: return [.forceStop, .discardSavedState]
        default: return [capability]
        }
    }

    /// Calls `capability`'s verb the way a surface does, stopping short of any
    /// consent it asks for.
    private func invoke(
        _ capability: VMCapability, on instance: VMInstance, snapshot: VMSnapshot,
        in harness: Harness
    ) async throws {
        let core = harness.core
        let vm = VMSelector.id(instance.id)
        switch capability {
        case .info: _ = try core.info(vm)
        case .ipAddress: _ = try core.ipAddress(of: vm)
        case .snapshots: _ = try core.snapshots(of: vm)
        case .start: try await core.start(vm, recovery: false)
        case .cancelGuestSetup: try core.cancelGuestSetup(vm, confirmed: false)
        case .stop, .discardSavedState:
            try await core.stop(vm, disposition: .graceful, confirmed: false, timeout: nil)
        case .forceStop:
            try await core.stop(vm, disposition: .force, confirmed: false, timeout: nil)
        case .restart: try await core.restart(vm, timeout: 1)
        case .pause: try await core.pause(vm)
        case .resume: try await core.resume(vm)
        case .suspend: try await core.suspend(vm)
        case .open: try core.open(vm)
        case .reveal: try core.reveal(vm)
        case .takeSnapshot: _ = try await core.takeSnapshot(vm, name: "Agreement", notes: "")
        case .revertToSnapshot:
            try await core.revertToSnapshot(
                vm, snapshot: snapshot.id, takingCheckpoint: false, confirmed: false)
        case .deleteSnapshot: try await core.deleteSnapshot(vm, snapshot: snapshot.id, confirmed: false)
        case .renameSnapshot: try core.renameSnapshot(vm, snapshot: snapshot.id, to: "Renamed")
        case .setSnapshotNotes: try core.setSnapshotNotes(vm, snapshot: snapshot.id, notes: "Noted")
        case .editStorageDisks: try core.renameStorageDisk(vm, disk: UUID(), to: "Label")
        case .createStorageDisk: try await core.createStorageDisk(vm, sizeInGB: 1)
        case .trashStorageDisk:
            try await core.removeStorageDisk(vm, disk: UUID(), trashFile: true, confirmed: false)
        case .editRemovableMedia: try core.ejectRemovableMedia(vm, item: UUID())
        case .createRemovableMedia:
            try await core.createRemovableMedia(
                vm, sizeInGB: 1,
                destinationURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString).asif"))
        case .editSharedDirectories: try core.removeSharedDirectory(vm, directory: UUID())
        case .editUSBAccessories: try await core.attachUSBAccessory(vm, accessory: 42)
        case .forgetUSBPairing: try core.forgetUSBPairing(vm, key: "unknown")
        case .editConfiguration:
            try core.setConfiguration(
                vm, assignments: [ConfigurationEntry(key: "cpus", value: String(instance.configuration.cpuCount + 1))],
                confirmed: true)
        case .editLiveConfiguration:
            try core.setConfiguration(
                vm,
                assignments: [
                    ConfigurationEntry(
                        key: "clipboard.sharing", value: String(!instance.configuration.clipboardSharingEnabled))
                ],
                confirmed: true)
        case .switchNetworkMode:
            try core.setConfiguration(
                vm, assignments: [ConfigurationEntry(key: "network.mode", value: "shared")],
                confirmed: true)
        case .clone: try core.beginClone(vm, machineIdentity: .new)
        case .rename: try core.rename(vm, to: "Renamed VM")
        case .delete: try await core.delete(vm, permanently: false, alsoRemoving: [], confirmed: false)
        case .showInFinder: try core.showInFinder(vm)
        case .toggleGuestAgentDisk: _ = try core.mountGuestAgentDisk(vm)
        case .startInRecovery, .togglePopOut, .toggleFullscreen, .showClipboard, .toggleSettingsPane:
            Issue.record("\(capability) has no verb to call")
        }
    }

    /// Whether `error` is the refusal admission gives, in the command
    /// vocabulary ``VMCommandCore/admissionRefusal(_:on:)`` maps it into.
    private func isAdmissionRefusal(_ error: CommandError) -> Bool {
        switch error {
        case .busy, .invalidState, .notFound, .conflict, .unsupportedByBuild, .terminating: true
        case .itemNotFound, .itemNotFoundOnHost, .ambiguous, .confirmationRequired,
            .guestAccountPasswordRequired, .invalidArgument, .unsupported, .timedOut,
            .operationFailed:
            false
        }
    }

    @Test("Every capability with a verb is called by this sweep")
    func sweepCoversEveryVerb() {
        let gated = Set(VMCapability.allCases.compactMap(gates(of:)).joined())
        let withVerb = Set(VMCapability.allCases.filter { $0.verb != nil })
        #expect(gated == withVerb)
    }

    @Test(
        "During every held operation, the catalog accepts exactly what admission lets the verb do",
        arguments: VMGuestOS.allCases)
    func catalogAndVerbAgreeDuringEveryOperation(guestOS: VMGuestOS) async throws {
        for phase in VMLifecyclePhaseFixtures.operations {
            let operation = try #require(phase.operation)
            for capability in VMCapability.allCases {
                guard let gates = gates(of: capability) else { continue }
                let harness = makeHarness()
                let snapshot = VMSnapshot(name: "Kept", macAddress: nil)
                let instance = RegisteredVMInstanceFixture.register(
                    name: "Agreeing", phase: .stopped, guestOS: guestOS, snapshots: [snapshot],
                    library: harness.library, storage: harness.storage, preferences: preferences)
                harness.snapshots.setCapturedConfiguration(instance.configuration, for: snapshot.id)
                defer { VMInstanceFixture.removeBundle(of: instance) }
                // The slot the operation started from is a file, as every
                // predicate reads it.
                if operation.startedFrom == .suspended {
                    try VMInstanceFixture.writeSaveFile(for: instance)
                }
                instance.activity.placeForTesting(phase)
                // A verb that joins the placed operation awaits its outcome,
                // which no body is running to resolve.
                operation.outcome.resolve(.success(()))

                let accepted = gates.contains { harness.library.capabilities.accepts($0, on: instance) }
                var refusal: CommandError?
                do {
                    try await invoke(capability, on: instance, snapshot: snapshot, in: harness)
                } catch let error as CommandError {
                    if isAdmissionRefusal(error) { refusal = error }
                } catch {
                    Issue.record("\(capability) during \(operation.kind) on \(guestOS) threw \(error)")
                }
                #expect(
                    accepted == (refusal == nil),
                    "\(capability) during \(operation.kind) from \(operation.startedFrom) on \(guestOS): accepted \(accepted), refusal \(String(describing: refusal))"
                )
            }
        }
    }
}
