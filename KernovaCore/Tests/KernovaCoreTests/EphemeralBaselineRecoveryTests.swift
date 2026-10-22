import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// Whether an Ephemeral Mode VM at rest is off its baseline, read from the
/// bundle's files and the baseline's copies of them alone.
@Suite("Ephemeral Baseline Predicate Tests", .caseScoped)
@MainActor
struct EphemeralBaselinePredicateTests {
    private let preferences = makeTestPreferences()

    private static let saveFile = VMBundleLayout.saveFilePathForTesting
    private static let additionalDisk = VMBundleLayout.additionalDiskRelativePath(id: UUID())

    /// An Ephemeral Mode VM resting at `phase` whose baseline is a `kind`
    /// snapshot, and that baseline.
    private func makeVM(
        baseline kind: VMSnapshotKind, phase: VMLifecyclePhase = .stopped,
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> (instance: VMInstance, baseline: VMSnapshot) {
        let baseline = VMSnapshot(name: "Clean", kind: kind, macAddress: nil)
        let instance = VMInstanceFixture.make(
            name: "Throwaway", phase: phase, preferences: preferences,
            hostState: .ephemeral(baseline: baseline.id),
            snapshots: VMSnapshotManifest(snapshots: [baseline], currentID: baseline.id),
            mutate: mutate)
        return (instance, baseline)
    }

    /// Writes `paths` into `baseline`'s directory and installs each in the
    /// bundle as a revert does.
    private func install(
        _ paths: [String], of baseline: VMSnapshot, into instance: VMInstance
    ) throws {
        let layout = instance.bundleLayout
        for path in paths {
            try layout.writeCaptured(path, ofSnapshot: baseline.id)
            try layout.installCaptured(path, fromSnapshot: baseline.id)
        }
    }

    @Test("A VM at its baseline owes nothing", arguments: [VMSnapshotKind.warm, .cold])
    func atTheBaselineOwesNothing(kind: VMSnapshotKind) throws {
        let (instance, baseline) = makeVM(baseline: kind)
        let disk = instance.bundleLayout.mainDiskPathForTesting
        try install(kind == .warm ? [disk, Self.saveFile] : [disk], of: baseline, into: instance)

        #expect(!instance.restsOff(baseline))
        #expect(!instance.restsOffEphemeralBaseline)
    }

    @Test("A suspended session of the VM's own owes nothing, whatever its disks hold")
    func ownSuspendedSessionOwesNothing() throws {
        let (instance, baseline) = makeVM(baseline: .warm, phase: .suspended)
        let disk = instance.bundleLayout.mainDiskPathForTesting
        try instance.bundleLayout.writeCaptured(Self.saveFile, ofSnapshot: baseline.id)
        try instance.bundleLayout.writeCaptured(disk, ofSnapshot: baseline.id)
        try instance.bundleLayout.writeAsGuest(disk)
        try VMInstanceFixture.writeSaveFile(for: instance)

        #expect(!instance.restsOffEphemeralBaseline)
    }

    @Test("A warm baseline's VM resting with no suspend slot is off it")
    func warmBaselineWithNoSlotIsOff() throws {
        let (instance, baseline) = makeVM(baseline: .warm)
        try instance.bundleLayout.writeCaptured(Self.saveFile, ofSnapshot: baseline.id)
        try install([instance.bundleLayout.mainDiskPathForTesting], of: baseline, into: instance)

        #expect(instance.restsOffEphemeralBaseline)
    }

    @Test(
        "A guest-written file differing from the baseline's copy is off a cold baseline",
        arguments: ["Disk.asif", "EFIVariableStore"])
    func guestWrittenFileIsOffAColdBaseline(path: String) throws {
        let (instance, baseline) = makeVM(baseline: .cold)
        let disk = instance.bundleLayout.mainDiskPathForTesting
        try install([disk, VMBundleLayout.efiVariableStoreRelativePath], of: baseline, into: instance)

        try instance.bundleLayout.writeAsGuest(path)

        #expect(instance.restsOffEphemeralBaseline)
    }

    @Test("A revert cut short, some files swapped in and some not, is off the baseline")
    func interruptedRevertIsOff() throws {
        let additional = Self.additionalDisk
        let (instance, baseline) = makeVM(baseline: .cold) {
            $0.setStorageDisks([
                StorageDisk.mainDisk(layout: VMBundleLayout(bundleURL: VMInstanceFixture.bundleURL(for: $0.id))),
                StorageDisk(path: additional, isInternal: true),
            ])
        }
        try install([instance.bundleLayout.mainDiskPathForTesting], of: baseline, into: instance)
        try instance.bundleLayout.writeCaptured(additional, ofSnapshot: baseline.id)
        try instance.bundleLayout.writeAsGuest(additional)

        #expect(instance.restsOffEphemeralBaseline)
    }

    @Test("A disk added at rest, which the baseline lacks, decides nothing")
    func addedDiskOwesNothing() throws {
        let additional = Self.additionalDisk
        let (instance, baseline) = makeVM(baseline: .cold) {
            $0.setStorageDisks([
                StorageDisk.mainDisk(layout: VMBundleLayout(bundleURL: VMInstanceFixture.bundleURL(for: $0.id))),
                StorageDisk(path: additional, isInternal: true),
            ])
        }
        try install([instance.bundleLayout.mainDiskPathForTesting], of: baseline, into: instance)
        try instance.bundleLayout.writeAsGuest(additional)

        #expect(!instance.restsOffEphemeralBaseline)
    }

    @Test("A disk removed at rest, which only the baseline holds, decides nothing")
    func removedDiskOwesNothing() throws {
        let (instance, baseline) = makeVM(baseline: .cold)
        try install([instance.bundleLayout.mainDiskPathForTesting], of: baseline, into: instance)
        try instance.bundleLayout.writeCaptured(Self.additionalDisk, ofSnapshot: baseline.id)

        #expect(!instance.restsOffEphemeralBaseline)
    }

    @Test("Settings changed at rest decide nothing")
    func settingsChangeOwesNothing() throws {
        let (instance, baseline) = makeVM(baseline: .cold) {
            $0.cpuCount = 1
            $0.clipboardSharingEnabled.toggle()
        }
        try install([instance.bundleLayout.mainDiskPathForTesting], of: baseline, into: instance)

        #expect(!instance.restsOffEphemeralBaseline)
    }

    @Test("A live VM is never read as resting off its baseline")
    func liveVMIsNeverOff() throws {
        let (instance, baseline) = makeVM(baseline: .warm, phase: .running(sessionID: UUID()))
        try instance.bundleLayout.writeCaptured(Self.saveFile, ofSnapshot: baseline.id)

        #expect(!instance.restsOffEphemeralBaseline)
    }
}

/// What a VM off its Ephemeral baseline owes at the moment this copy takes it,
/// and the consent turning the mode on asks for when it would revert one now.
@Suite("Ephemeral Baseline Recovery Tests", .serialized, .caseScoped)
@MainActor
struct EphemeralBaselineRecoveryTests {
    private let preferences = makeTestPreferences()
    private let virtualization = MockVirtualizationService()

    private func makeHarness() -> WiredCommandCore {
        WiredCommandCore(virtualization: virtualization, preferences: preferences)
    }

    /// A VM resting at `phase` with a `kind` snapshot, Ephemeral Mode on with
    /// it as the baseline when `ephemeral`, and its files off that snapshot: a
    /// guest wrote its disk, and it holds no suspend slot.
    private func makeVM(
        in harness: WiredCommandCore, baseline kind: VMSnapshotKind = .warm,
        ephemeral: Bool = true, phase: VMLifecyclePhase = .stopped
    ) throws -> (instance: VMInstance, baseline: VMSnapshot) {
        let baseline = VMSnapshot(name: "Clean", kind: kind, macAddress: nil)
        let instance = RegisteredVMInstanceFixture.register(
            name: "Throwaway", phase: phase, guestOS: .linux, snapshots: [baseline],
            library: harness.library, preferences: preferences,
            hostState: ephemeral ? .ephemeral(baseline: baseline.id) : VMHostState())
        // What the baseline's own config.json holds, so a revert reads it back
        // and the bring-up after it finds the baseline readable.
        harness.machineFiles.setCapturedConfiguration(instance.configuration, for: baseline.id)
        harness.storage.files.setSnapshotConfiguration(
            instance.configuration, id: baseline.id, at: instance.bundleURL)
        let layout = instance.bundleLayout
        if kind == .warm {
            try layout.writeCaptured(VMBundleLayout.saveFilePathForTesting, ofSnapshot: baseline.id)
        }
        try layout.writeCaptured(layout.mainDiskPathForTesting, ofSnapshot: baseline.id)
        try layout.writeAsGuest(layout.mainDiskPathForTesting)
        return (instance, baseline)
    }

    // MARK: - The lock take

    @Test("A Start on a VM off its baseline reverts it first, then starts on the baseline")
    func startRevertsFirstThenStarts() async throws {
        let harness = makeHarness()
        let (instance, baseline) = try makeVM(in: harness)

        try await harness.core.start(.id(instance.id), recovery: false, consent: .none)

        #expect(virtualization.revertedSnapshots.map(\.id) == [baseline.id])
        #expect(virtualization.startCallCount == 1)
        // The baseline's saved state the revert installed, not the disks the
        // session left: a cold boot would mean the start ran on those.
        #expect(virtualization.lastStartRoute == .restoredSavedState)
        #expect(instance.status == .running)
    }

    @Test("A Start whose owed revert fails is refused, booting nothing")
    func failedRevertRefusesTheStart() async throws {
        let harness = makeHarness()
        let (instance, baseline) = try makeVM(in: harness)
        virtualization.revertToSnapshotError = VMSnapshotError.snapshotMissingSavedState

        await #expect {
            try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
        } throws: { error in
            guard case .operationFailed(.start, _, let message, _) = error as? CommandError else {
                return false
            }
            return message.contains(baseline.name)
        }

        #expect(virtualization.startCallCount == 0)
        #expect(instance.liveSessionID == nil)
    }

    @Test("An operation that leaves the guest's files alone does not revert first")
    func snapshotDeleteDoesNotRevertFirst() async throws {
        let harness = makeHarness()
        let (instance, baseline) = try makeVM(in: harness)
        let other = VMSnapshot(name: "Other", kind: .cold, macAddress: nil)
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [baseline, other]))

        try await harness.core.deleteSnapshot(
            .id(instance.id), snapshot: other.id, consent: Consent([.deleteSnapshot]))

        #expect(virtualization.revertedSnapshots.isEmpty)
        #expect(instance.restsOffEphemeralBaseline)
    }

    // MARK: - Turning the mode on

    @Test("Turning the mode on at rest off the baseline asks first, and changes nothing unasked")
    func enablingOffTheBaselineAsks() throws {
        let harness = makeHarness()
        let (instance, baseline) = try makeVM(in: harness, ephemeral: false)

        #expect(instance.ephemeralEnableRevertsTo?.id == baseline.id)
        #expect {
            try harness.core.setConfiguration(
                .id(instance.id), assignments: [VMConfigurationKeyRegistry.ephemeral.assigning(true)],
                consent: .none)
        } throws: { error in
            guard case .confirmationRequired(let prompt) = error as? CommandError else { return false }
            return prompt.kind == .revertToSnapshot && prompt.message.contains(baseline.name)
                && prompt.title.contains(instance.name)
        }

        #expect(!instance.hostState.ephemeralModeEnabled)
        #expect(virtualization.revertedSnapshots.isEmpty)
    }

    @Test("Confirmed, turning the mode on at rest off the baseline turns it on and reverts now")
    func confirmedEnableRevertsNow() async throws {
        let harness = makeHarness()
        let (instance, baseline) = try makeVM(in: harness, ephemeral: false)

        try harness.core.setConfiguration(
            .id(instance.id), assignments: [VMConfigurationKeyRegistry.ephemeral.assigning(true)],
            consent: Consent([.revertToSnapshot]))
        await harness.library.waitForRevertsToSettle()

        #expect(instance.hostState.ephemeralModeEnabled)
        #expect(instance.ephemeralBaselineSnapshot?.id == baseline.id)
        #expect(virtualization.revertedSnapshots.map(\.id) == [baseline.id])
        #expect(!instance.restsOffEphemeralBaseline)
    }

    @Test("Turning the mode on while the VM runs asks nothing and reverts nothing now")
    func enablingWhileLiveAsksNothing() throws {
        let harness = makeHarness()
        let (instance, _) = try makeVM(
            in: harness, ephemeral: false, phase: .running(sessionID: UUID()))

        try harness.core.setConfiguration(
            .id(instance.id), assignments: [VMConfigurationKeyRegistry.ephemeral.assigning(true)],
            consent: .none)

        #expect(instance.hostState.ephemeralModeEnabled)
        #expect(virtualization.revertedSnapshots.isEmpty)
        #expect(instance.liveSessionID != nil)
    }

    @Test("Turning the mode on over a suspended session of the VM's own asks nothing")
    func enablingOverOwnSuspendedSessionAsksNothing() throws {
        let harness = makeHarness()
        let (instance, _) = try makeVM(in: harness, ephemeral: false, phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: instance)

        try harness.core.setConfiguration(
            .id(instance.id), assignments: [VMConfigurationKeyRegistry.ephemeral.assigning(true)],
            consent: .none)

        #expect(instance.hostState.ephemeralModeEnabled)
        #expect(virtualization.revertedSnapshots.isEmpty)
        #expect(instance.hasSaveFile)
    }

    @Test("Turning the mode on by capturing a fresh baseline asks nothing")
    func enablingByCapturingABaselineAsksNothing() async throws {
        let harness = makeHarness()
        let instance = RegisteredVMInstanceFixture.register(
            name: "Throwaway", phase: .stopped, guestOS: .linux, library: harness.library,
            preferences: preferences)
        try instance.bundleLayout.writeAsGuest(instance.bundleLayout.mainDiskPathForTesting)

        let summary = try await harness.core.takeSnapshot(
            .id(instance.id), name: "Clean", notes: "", asEphemeralBaseline: true)

        #expect(instance.hostState.ephemeralBaselineSnapshotID == summary.id)
        #expect(virtualization.revertedSnapshots.isEmpty)
    }
}
