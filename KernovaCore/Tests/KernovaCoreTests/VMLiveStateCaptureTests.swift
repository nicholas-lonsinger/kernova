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

    private func instanceHoldingAccessories(_ count: Int) async throws -> AccessoryFixture {
        let accessories = MockUSBAccessoryService()
        let lifecycle = makeTestLifecycle(usbAccessoryPassthrough: .available(accessories))
        let library = makeWiredLibrary(lifecycle: lifecycle)
        let sessionID = UUID()
        let instance = library.registerFixture(phase: .running(sessionID: sessionID))
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

    // MARK: - Taking the installer disk off before a save

    /// A running macOS VM in a library whose session holds the installer disk live, beside a medium of the
    /// user's own that stays.
    private struct InstallerFixture {
        let library: VMLibrary
        let instance: VMInstance
        let installer: RemovableMediaItem
        let own: RemovableMediaItem
    }

    private func instanceHoldingInstallerDisk() throws -> InstallerFixture {
        let library = makeWiredLibrary()
        let sessionID = UUID()
        let path = try #require(BundledGuestAgents.testing.macOSInstallerDiskImageURL).path(percentEncoded: false)
        let installer = RemovableMediaItem(path: path, readOnly: true, label: BundledGuestAgents.macOSDiskLabel)
        let own = RemovableMediaItem(path: "/var/empty/Own.iso", readOnly: true)
        let instance = library.registerFixture(guestOS: .macOS, phase: .running(sessionID: sessionID)) {
            $0.removableMedia = [installer, own]
        }
        instance.beginSessionContextForTesting()
        instance.recordAttachedMedia(
            RemovableMediaDeviceInfo(id: installer.id, path: installer.path, readOnly: true), for: sessionID)
        return InstallerFixture(library: library, instance: instance, installer: installer, own: own)
    }

    private static let saveFile = URL(filePath: "/var/empty/save.vzvmsave")

    private func suspend(_ fixture: InstallerFixture, _ session: MockSnapshotSession) async throws {
        try await fixture.instance.activity.perform(.saving) { context in
            do {
                try await VMLiveStateCapture.suspendState(context, session: session, to: Self.saveFile)
                return .rest(.asStarted, ())
            } catch {
                return .failed(.asStarted, error)
            }
        }
    }

    @Test("A suspend takes the installer disk off the guest and out of the configuration before it writes")
    func suspendTakesTheInstallerDiskOffFirst() async throws {
        let fixture = try instanceHoldingInstallerDisk()
        let session = MockSnapshotSession(guestState: .running)

        try await suspend(fixture, session)

        let calls = await session.calls
        #expect(calls == ["detachUSBDevice", "pauseIfRunning", "saveMachineState"])
        #expect(await session.detachedUSBDeviceIDs == [fixture.installer.id])
        // What the restore builds from lists no installer disk, and the user's own medium stays.
        #expect(fixture.instance.configuration.removableMedia == [fixture.own])
        #expect(fixture.instance.liveRemovableMedia.isEmpty)
        #expect(!fixture.instance.hasGuestAgentInstallerMounted)
    }

    @Test("A warm capture takes the installer disk off before it writes, and it stays off once the guest resumes")
    func captureTakesTheInstallerDiskOffForGood() async throws {
        let fixture = try instanceHoldingInstallerDisk()
        let session = MockSnapshotSession(guestState: .running)

        try await fixture.instance.activity.launchedCapture(.live) { context in
            try await VMLiveStateCapture.captureLiveState(
                context, session: session, wasRunning: true, saveFileURL: Self.saveFile
            ) {}
            return .rest(.asStarted, ())
        }

        let calls = await session.calls
        #expect(calls == ["detachUSBDevice", "pauseIfRunning", "saveMachineState", "resumeIfPaused"])
        #expect(fixture.instance.configuration.removableMedia == [fixture.own])
        #expect(fixture.instance.liveRemovableMedia.isEmpty)
    }

    @Test("An installer disk the controller no longer holds does not fail the save")
    func anAlreadyEjectedInstallerDiskIsNotAFailure() async throws {
        let fixture = try instanceHoldingInstallerDisk()
        let session = MockSnapshotSession(guestState: .running)
        await session.setDetachError(VMSessionError.usbDeviceNotFound)

        try await suspend(fixture, session)

        #expect(await session.calls.contains("saveMachineState"))
        #expect(fixture.instance.configuration.removableMedia == [fixture.own])
    }

    @Test("Any other failure to take the installer disk off fails the save before it writes a state")
    func aFailedInstallerDetachStopsTheSave() async throws {
        let fixture = try instanceHoldingInstallerDisk()
        let session = MockSnapshotSession(guestState: .running)
        await session.setDetachError(VMSessionError.usbControllerUnavailable)

        await #expect(throws: VMSessionError.self) { try await suspend(fixture, session) }

        #expect(!(await session.calls.contains("saveMachineState")))
        #expect(fixture.instance.configuration.removableMedia == [fixture.installer, fixture.own])
        #expect(fixture.instance.liveRemovableMedia.map(\.id) == [fixture.installer.id])
    }
}

/// Which VM a return was owed to at one moment mid-sweep.
@MainActor
private final class OwedRecord {
    var instance: VMInstance?
}
