import Foundation
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The steps a write of a live guest's state takes over its session: the
/// pause and resume around it, and every hot-pluggable USB device unplugged
/// first.
@Suite("Live state capture", .caseScoped)
@MainActor
struct VMLiveStateCaptureTests {
    // MARK: - Snapshot capture

    /// Runs ``VMLiveStateCapture/captureLiveState(_:_:session:wasRunning:saveFileURL:captureDisks:)`` in a
    /// live capture of a running VM.
    private func capture(
        _ session: MockSnapshotSession, wasRunning: Bool, captureDisks: @escaping @MainActor () async -> Void = {}
    ) async throws {
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
        try await instance.activity.launchedCapture(.live) { context in
            try await VMLiveStateCapture.captureLiveState(
                context, try VMLiveStateCapture.approve(.all, toSave: instance, as: .takeSnapshot),
                session: session, wasRunning: wasRunning,
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

    // MARK: - Unplugging USB devices before a save

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
            try await instance.activity.perform(.saving) { [instance] context in
                do {
                    try await VMLiveStateCapture.suspendState(
                        context, try VMLiveStateCapture.approve(.all, toSave: instance, as: .suspend),
                        session: session, to: URL(filePath: "/var/empty/save.vzvmsave"))
                    return .rest(.asStarted, ())
                } catch {
                    return .failed(.asStarted, error)
                }
            }
        }
    }

    /// A session whose controller holds `fixture`'s devices.
    private func session(holding fixture: AccessoryFixture) async -> MockSnapshotSession {
        let session = MockSnapshotSession(guestState: .running)
        await session.setUSBDevices(fixture.deviceIDs)
        return session
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
        let session = await session(holding: fixture)

        try await fixture.sweep(session)

        let detached = await session.detachedUSBDeviceIDs
        #expect(detached == fixture.deviceIDs)
        #expect(fixture.instance.liveUSBAccessories.isEmpty)
        #expect(fixture.library.accessoryHolders.heldRegistryIDs.isEmpty)
    }

    @Test("A device the controller already lost is released and does not fail the save")
    func anAlreadyDetachedDeviceIsNotAFailure() async throws {
        let fixture = try await instanceHoldingAccessories(1)
        let session = await session(holding: fixture)
        await session.setDetachError(VMSessionError.usbDeviceNotFound)

        try await fixture.sweep(session)

        #expect(fixture.instance.liveUSBAccessories.isEmpty)
    }

    @Test("A detach that fails for any other reason stops the save rather than writing state")
    func aFailedDetachStopsTheSave() async throws {
        let fixture = try await instanceHoldingAccessories(1)
        let session = await session(holding: fixture)
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
        let session = await session(holding: fixture)
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
        let session = await session(holding: fixture)
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
            try await fixture.instance.activity.launchedCapture(.live) { [instance = fixture.instance] context in
                try await VMLiveStateCapture.captureLiveState(
                    context, try VMLiveStateCapture.approve(.all, toSave: instance, as: .takeSnapshot),
                    session: session, wasRunning: false, saveFileURL: URL(filePath: "/var/empty/save.vzvmsave")
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

        try await fixture.sweep(await session(holding: fixture))

        #expect(fixture.library.accessoryHolders.owedReturn(of: identity) == nil)
    }

    @Test("A session holding nothing asks VZ for no detach at all")
    func noAccessoriesMeansNoDetachCalls() async throws {
        let fixture = try await instanceHoldingAccessories(0)
        let session = await session(holding: fixture)

        try await fixture.sweep(session)

        let calls = await session.calls
        #expect(calls == ["pauseIfRunning", "saveMachineState"])
    }
}

// MARK: - Removable media and boot storage

extension VMLiveStateCaptureTests {
    /// A live VM whose session holds `media`, recorded as a boot attaches
    /// them, with `bootStorage` among its storage disks.
    private func instanceHoldingMedia(
        _ media: [RemovableMediaItem], bootStorage: StorageDisk? = nil
    ) -> (VMInstance, UUID) {
        let sessionID = UUID()
        let instance = VMInstanceFixture.make(phase: .running(sessionID: sessionID)) { config in
            config.removableMedia = media
            if let bootStorage {
                config.storageDisks = [StorageDisk(path: "Disk.asif", isInternal: true), bootStorage]
            }
        }
        instance.beginSessionContextForTesting()
        for item in media {
            instance.recordAttachedMedia(
                RemovableMediaDeviceInfo(id: item.id, path: item.path, readOnly: item.readOnly), for: sessionID)
        }
        return (instance, sessionID)
    }

    /// Suspends `instance` over `session` under `consent`, a question ending
    /// the save as started, as the engine's does.
    private func suspend(
        _ instance: VMInstance, over session: MockSnapshotSession, consent: Consent = .all
    ) async throws {
        try await instance.activity.perform(.saving) {
            (context: borrowing VMOperationContext) -> VMOperationEnding<Void> in
            let approval: VMLiveStateCapture.UnplugApproval
            do {
                approval = try VMLiveStateCapture.approve(consent, toSave: instance, as: .suspend)
            } catch {
                return .failed(.asStarted, error)
            }
            try await VMLiveStateCapture.suspendState(
                context, approval, session: session, to: URL(filePath: "/var/empty/save.vzvmsave"))
            return .rest(.asStarted, ())
        }
    }

    @Test("A suspend unplugs every removable medium, then pauses, then saves, and keeps USB boot storage")
    func suspendUnplugsMediaBeforePausing() async throws {
        let data = RemovableMediaItem(path: "/Volumes/Data.img", readOnly: false, label: "Data")
        let iso = RemovableMediaItem(path: "/Volumes/Tools.iso", readOnly: true, label: "Tools")
        let boot = StorageDisk(path: "/Volumes/Live.iso", readOnly: true, kind: .usbMassStorage)
        let (instance, _) = instanceHoldingMedia([data, iso], bootStorage: boot)
        let session = MockSnapshotSession(guestState: .running)
        await session.setUSBDevices([boot.id, data.id, iso.id])

        try await suspend(instance, over: session)

        #expect(await session.detachedUSBDeviceIDs == [data.id, iso.id])
        #expect(await session.usbDevices == [boot.id])
        #expect(
            await session.calls == ["detachUSBDevice", "detachUSBDevice", "pauseIfRunning", "saveMachineState"])
        #expect(instance.liveRemovableMedia.isEmpty)
    }

    @Test("A device on the controller that Kernova's records lost still comes off")
    func anUnrecordedDeviceStillComesOff() async throws {
        let (instance, _) = instanceHoldingMedia([])
        let stray = UUID()
        let session = MockSnapshotSession(guestState: .running)
        await session.setUSBDevices([stray])

        try await suspend(instance, over: session)

        #expect(await session.detachedUSBDeviceIDs == [stray])
    }

    @Test("A save whose question is still open touches nothing")
    func anOpenQuestionTouchesNothing() async throws {
        let data = RemovableMediaItem(path: "/Volumes/Data.img", readOnly: false, label: "Data")
        let (instance, _) = instanceHoldingMedia([data])
        let session = MockSnapshotSession(guestState: .running)
        await session.setUSBDevices([data.id])

        let error = await #expect(throws: CommandError.self) {
            try await suspend(instance, over: session, consent: Consent([.unplugUSBDisks]))
        }

        #expect(error?.confirmationPrompt?.kind == .unplugUSBDisksAtRisk)
        #expect(await session.calls.isEmpty)
        #expect(instance.liveRemovableMedia.map(\.id) == [data.id])
    }

    /// A library VM live on a session holding `data`, whose reconciles attach
    /// through `media`.
    private func libraryVMHolding(
        _ data: RemovableMediaItem, media: MockRemovableMediaDeviceService
    ) -> (VMLibrary, VMInstance, UUID) {
        let library = makeWiredLibrary(lifecycle: makeTestLifecycle(removableMedia: media))
        let sessionID = UUID()
        let instance = library.registerFixture(phase: .running(sessionID: sessionID)) {
            $0.removableMedia = [data]
        }
        instance.beginSessionContextForTesting()
        instance.recordAttachedMedia(
            RemovableMediaDeviceInfo(id: data.id, path: data.path, readOnly: data.readOnly), for: sessionID)
        return (library, instance, sessionID)
    }

    /// A live capture of `instance` through ``VMLiveStateCapture/captureWarm(_:_:consent:as:session:prepare:savingStateTo:copy:)``
    /// under `consent`, its disk copy throwing `copyError` when given.
    private func captureWarm(
        _ instance: VMInstance, over session: MockSnapshotSession, consent: Consent,
        copyError: (any Error)? = nil
    ) async throws -> VMOperationEnding<Void> {
        let ending = EndingRecord()
        do {
            try await instance.activity.launchedCapture(.live) { context in
                let captured = await VMLiveStateCapture.captureWarm(
                    instance, context, consent: consent, as: .takeSnapshot, session: session,
                    prepare: {}, savingStateTo: { URL(filePath: "/var/empty/save.vzvmsave") },
                    copy: { if let copyError { throw copyError } })
                ending.ending = captured
                return captured
            }
        } catch  where ending.ending != nil {
            // The capture's own failure, which the ending records.
        }
        return try #require(ending.ending)
    }

    @Test(
        "A warm capture plugs the media it unplugged back in, on either outcome",
        arguments: [false, true])
    func aWarmCapturePlugsTheMediaBackIn(copyFails: Bool) async throws {
        let media = MockRemovableMediaDeviceService()
        // Read-only: a live snapshot refuses while a writable external disk is attached.
        let data = RemovableMediaItem(path: "/Volumes/Tools.iso", readOnly: true, label: "Tools")
        let (library, instance, _) = libraryVMHolding(data, media: media)
        defer { withExtendedLifetime(library) {} }
        let session = MockSnapshotSession(guestState: .running)
        await session.setUSBDevices([data.id])

        _ = try await captureWarm(
            instance, over: session, consent: .all,
            copyError: copyFails ? VMSnapshotError.snapshotMissingSavedState : nil)

        #expect(await session.detachedUSBDeviceIDs == [data.id])
        try await waitForChange { instance.liveRemovableMedia.map(\.id) == [data.id] }
        #expect(media.attachedPaths == [data.path])
    }

    @Test("A warm capture whose question is still open touches nothing and plugs nothing in")
    func aRefusedWarmCaptureTouchesNothing() async throws {
        let media = MockRemovableMediaDeviceService()
        // Read-only: a live snapshot refuses while a writable external disk is attached.
        let data = RemovableMediaItem(path: "/Volumes/Tools.iso", readOnly: true, label: "Tools")
        let (library, instance, sessionID) = libraryVMHolding(data, media: media)
        defer { withExtendedLifetime(library) {} }
        let session = MockSnapshotSession(guestState: .running)
        await session.setUSBDevices([data.id])

        let ending = try await captureWarm(instance, over: session, consent: .none)

        guard case .failed(.asStarted, let error) = ending else {
            Issue.record("Expected the capture to fail as started, got \(ending)")
            return
        }
        #expect((error as? CommandError)?.confirmationPrompt?.kind == .unplugUSBDisks)
        #expect(await session.calls.isEmpty)
        #expect(media.attachCallCount == 0)
        #expect(instance.phase == .running(sessionID: sessionID))
    }
}

/// How a capture ended, read back after the operation.
@MainActor
private final class EndingRecord {
    var ending: VMOperationEnding<Void>?
}

/// Which VM a return was owed to at one moment mid-sweep.
@MainActor
private final class OwedRecord {
    var instance: VMInstance?
}
