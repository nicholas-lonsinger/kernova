import Foundation
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The steps a write of a live guest's state takes over its session: the
/// pause and resume around it, and the passthrough accessories swept off first.
@Suite("Live state capture", .caseScoped)
@MainActor
struct VMLiveStateCaptureTests {
    // MARK: - Snapshot capture

    /// Runs ``VMLiveStateCapture/captureLiveState(_:session:wasRunning:saveFileURL:captureDisks:)`` in a
    /// live capture of a running VM.
    private func capture(
        _ session: MockSnapshotSession, wasRunning: Bool, captureDisks: @escaping @MainActor () async -> Void = {}
    ) async throws {
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
        try await instance.activity.launchedCapture(.live) { context in
            try await VMLiveStateCapture.captureLiveState(
                context, session: session, wasRunning: wasRunning,
                saveFileURL: URL(filePath: "/var/empty/save.vzvmsave")
            ) {
                await captureDisks()
            }
            return .rest(.asStarted, ())
        }
    }

    @Test("A capture puts a running guest back to running")
    func captureResumesAGuestItPaused() async throws {
        let session = MockSnapshotSession(guestState: .running)
        var stateWhileCapturing: MockSnapshotSession.GuestState?

        try await capture(session, wasRunning: true) { stateWhileCapturing = await session.guestState }

        #expect(stateWhileCapturing == .paused)
        let finalState = await session.guestState
        #expect(finalState == .running)
    }

    @Test("A capture of a guest the user already paused leaves it paused")
    func captureLeavesAnAlreadyPausedGuestPaused() async throws {
        // `resumeIfPaused` resumes whatever is paused, so an unconditional call
        // here restarts the guest while the VM is reported as paused.
        let session = MockSnapshotSession(guestState: .paused)

        try await capture(session, wasRunning: false)

        let finalState = await session.guestState
        let calls = await session.calls
        #expect(finalState == .paused)
        #expect(!calls.contains("resumeIfPaused"))
    }

    @Test("A capture that fails to save never copies the disks")
    func captureStopsAtAFailedSave() async {
        let session = MockSnapshotSession(guestState: .running)
        await session.setSaveError(VMSnapshotError.snapshotMissingSavedState)
        var captured = false

        await #expect(throws: VMSnapshotError.self) {
            try await capture(session, wasRunning: true) { captured = true }
        }

        #expect(!captured)
    }

    // MARK: - Detaching passthrough accessories before a save

    /// A VM in a library whose live session holds `count` passthrough
    /// accessories, attached the way every attach is.
    private struct AccessoryFixture {
        /// Kept for the test's length: the VM reads what it holds from it.
        let library: VMLibrary
        let instance: VMInstance
        let deviceIDs: [UUID]

        /// Writes the guest's state inside a save operation holding the VM, as a
        /// suspend does, leaving the guest live whatever the sweep did so what
        /// it still holds can be read.
        @MainActor
        func sweep(_ session: MockSnapshotSession) async throws {
            try await instance.activity.perform(.saving) { context in
                do {
                    try await VMLiveStateCapture.suspendState(
                        context, session: session, to: URL(filePath: "/var/empty/save.vzvmsave"))
                    return .rest(.asStarted, ())
                } catch {
                    return .failed(.asStarted, error)
                }
            }
        }
    }

    private func instanceHoldingAccessories(
        _ count: Int, _ mutate: (inout VMConfiguration) -> Void = { _ in }
    ) async throws -> AccessoryFixture {
        let accessories = MockUSBAccessoryService()
        let lifecycle = makeTestLifecycle(usbAccessoryPassthrough: .available(accessories))
        let library = makeWiredLibrary(lifecycle: lifecycle)
        let sessionID = UUID()
        let instance = library.registerFixture(phase: .running(sessionID: sessionID), mutate: mutate)
        instance.beginSessionContextForTesting()
        var deviceIDs: [UUID] = []
        for index in 0..<count {
            let registryID = UInt64(index + 1)
            accessories.accessories.append(
                MockUSBAccessoryService.accessory(registryID: registryID, serial: "SER\(index)"))
            let deviceID = UUID()
            accessories.nextDeviceID = deviceID
            try await lifecycle.attachUSBAccessory(registryID, to: instance, for: sessionID)
            deviceIDs.append(deviceID)
        }
        return AccessoryFixture(library: library, instance: instance, deviceIDs: deviceIDs)
    }

    @Test("Every passthrough accessory is detached, and released from the VM")
    func detachesEveryAccessoryBeforeSaving() async throws {
        let fixture = try await instanceHoldingAccessories(2)
        let session = MockSnapshotSession(guestState: .running)

        try await fixture.sweep(session)

        let detached = await session.detachedUSBDeviceIDs
        #expect(detached == fixture.deviceIDs)
        #expect(fixture.instance.liveUSBAccessories.isEmpty)
        #expect(fixture.library.accessoryHolders.heldRegistryIDs.isEmpty)
    }

    @Test(
        "A save whose USB ports would have a gap is refused before anything is taken off, paused or written, naming the disks above it",
        arguments: [false, true])
    func anUnrestorableSaveIsRefusedFirst(leftByAccessories: Bool) async throws {
        let fixture = try await instanceHoldingAccessories(2) {
            $0.removableMedia = [RemovableMediaItem(path: "/tmp/later.iso", readOnly: true, label: "Later")]
        }
        let disk = try #require(fixture.instance.configuration.removableMedia?.first?.id)
        let session = MockSnapshotSession(guestState: .running)
        await session.setDevicesAboveGap(asIs: leftByAccessories ? [] : [disk], removing: [disk])

        let refusal = try #require(
            await #expect(throws: VMLiveStateCapture.SaveRefusal.self) { try await fixture.sweep(session) })

        #expect(refusal == .usbPortGap(below: ["Later"], leftByAccessories: leftByAccessories))
        // Judged as the state would stand once the accessories were taken off.
        #expect(await session.askedRemovingUSBDevices == Set(fixture.deviceIDs))
        #expect(await session.calls.isEmpty)
        #expect(fixture.instance.liveUSBAccessories.count == 2)
    }

    @Test("The refusal says where the gap is, what left it, and which disks to detach")
    func refusalCopy() {
        #expect(
            VMLiveStateCapture.SaveRefusal.usbPortGap(below: ["KERNOVA_AGENT"], leftByAccessories: false)
                .localizedDescription
                == "Kernova can't save this virtual machine's state: its USB ports have a gap below \u{201C}KERNOVA_AGENT\u{201D}, and a saved state with a gap in its USB ports doesn't restore. Detach \u{201C}KERNOVA_AGENT\u{201D} and try again, or shut the virtual machine down instead."
        )
        #expect(
            VMLiveStateCapture.SaveRefusal.usbPortGap(below: ["A", "B"], leftByAccessories: true).localizedDescription
                == "Kernova can't save this virtual machine's state: saving takes its USB accessories off, which leaves a gap in its USB ports below \u{201C}A\u{201D} and \u{201C}B\u{201D}, and a saved state with a gap in its USB ports doesn't restore. Detach \u{201C}A\u{201D} and \u{201C}B\u{201D} and try again, or shut the virtual machine down instead."
        )
    }

    @Test("A device the controller already lost is released and does not fail the save")
    func anAlreadyDetachedDeviceIsNotAFailure() async throws {
        let fixture = try await instanceHoldingAccessories(1)
        let session = MockSnapshotSession(guestState: .running)
        await session.setDetachError(VMSessionError.usbDeviceNotFound)

        try await fixture.sweep(session)

        #expect(fixture.instance.liveUSBAccessories.isEmpty)
    }

    @Test("A detach that fails for any other reason stops the save rather than writing state")
    func aFailedDetachStopsTheSave() async throws {
        let fixture = try await instanceHoldingAccessories(1)
        let session = MockSnapshotSession(guestState: .running)
        await session.setDetachError(VMSessionError.usbControllerUnavailable)

        // Swallowing this would write a saved state still carrying a
        // passthrough device, from an operation that reported success.
        await #expect(throws: VMSessionError.self) {
            try await fixture.sweep(session)
        }

        let calls = await session.calls
        #expect(!calls.contains("saveMachineState"))
        #expect(fixture.instance.liveUSBAccessories.count == 1)
    }

    @Test("A sweep that throws part-way leaves only what it never reached attached")
    func aPartialSweepClearsWhatItEjected() async throws {
        let fixture = try await instanceHoldingAccessories(2)
        let session = MockSnapshotSession(guestState: .running)
        await session.setDetachError(
            VMSessionError.usbControllerUnavailable, forDeviceID: fixture.deviceIDs[1])

        await #expect(throws: VMSessionError.self) {
            try await fixture.sweep(session)
        }

        #expect(fixture.instance.liveUSBAccessories.map(\.deviceID) == [fixture.deviceIDs[1]])
    }

    @Test("A capture's sweep owes back exactly the accessories it took off")
    func aCaptureSweepOwesWhatItTookOff() async throws {
        let fixture = try await instanceHoldingAccessories(3)
        let session = MockSnapshotSession(guestState: .running)
        await session.setDetachError(
            VMSessionError.usbControllerUnavailable, forDeviceID: fixture.deviceIDs[1])
        let owedBefore = OwedRecord()
        let holders = fixture.library.accessoryHolders
        let identities = fixture.instance.liveUSBAccessories.compactMap(\.accessory.identity)
        #expect(identities.count == 3)
        let firstDevice = fixture.deviceIDs[0]
        let firstIdentity = identities[0]
        await session.setBeforeDetach { deviceID in
            await MainActor.run {
                guard deviceID == firstDevice else { return }
                owedBefore.instance = holders.owedReturn(of: firstIdentity)
            }
        }

        await #expect(throws: VMSessionError.self) {
            try await fixture.instance.activity.launchedCapture(.live) { context in
                try await VMLiveStateCapture.captureLiveState(
                    context, session: session, wasRunning: false, saveFileURL: URL(filePath: "/var/empty/save.vzvmsave")
                ) {}
                return .rest(.asStarted, ())
            }
        }

        // Owed before its own detach ran, since macOS can hand it back before
        // that returns.
        #expect(owedBefore.instance === fixture.instance)
        #expect(holders.owedReturn(of: identities[0]) === fixture.instance)
        // The one whose detach threw is still the guest's, and the one never
        // reached was never taken off.
        #expect(holders.owedReturn(of: identities[1]) == nil)
        #expect(holders.owedReturn(of: identities[2]) == nil)
    }

    @Test("A save's sweep owes nothing back")
    func aSaveSweepOwesNothing() async throws {
        let fixture = try await instanceHoldingAccessories(1)
        let identity = try #require(fixture.instance.liveUSBAccessories.first?.accessory.identity)

        try await fixture.sweep(MockSnapshotSession(guestState: .running))

        #expect(fixture.library.accessoryHolders.owedReturn(of: identity) == nil)
    }

    @Test("A session holding nothing asks VZ for no detach at all")
    func noAccessoriesMeansNoDetachCalls() async throws {
        let fixture = try await instanceHoldingAccessories(0)
        let session = MockSnapshotSession(guestState: .running)

        try await fixture.sweep(session)

        let calls = await session.calls
        #expect(calls == ["pauseIfRunning", "saveMachineState"])
    }
}

/// Which VM a return was owed to at one moment mid-sweep.
@MainActor
private final class OwedRecord {
    var instance: VMInstance?
}
