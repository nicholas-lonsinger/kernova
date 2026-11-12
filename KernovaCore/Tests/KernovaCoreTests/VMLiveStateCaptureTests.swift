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

    // MARK: - Recording the version that wrote the state

    private let scratch = TestScratchDirectory(prefix: "VMLiveStateCaptureTests")

    /// The products of a Kernova at version 0.10.0, build 412.
    private let products = AppBundleProducts(
        bundleURL: AppBundleProducts.testing.bundleURL, hostVersion: "0.10.0", buildNumber: "412",
        guestAgents: .testing)

    /// Writes a live capture of a running VM from a Kernova at `products`
    /// over `session` into `saveFileURL`.
    private func captureState(to saveFileURL: URL, over session: MockSnapshotSession) async throws {
        let instance = VMInstanceFixture.make(
            phase: .running(sessionID: UUID()), bundleProducts: products)
        try await instance.activity.launchedCapture(.live) { context in
            try await VMLiveStateCapture.captureLiveState(
                context, session: session, wasRunning: true, saveFileURL: saveFileURL
            ) {}
            return .rest(.asStarted, ())
        }
    }

    @Test("A write that fails leaves what it part-wrote with no version")
    func failedWriteRecordsNoVersion() async throws {
        let saveFileURL = scratch.url.appendingPathComponent("SaveFile.vzvmsave")
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        // However far VZ got before the write failed.
        try Data("part-written".utf8).write(to: saveFileURL)
        let session = MockSnapshotSession(guestState: .running)
        await session.setSaveError(CocoaError(.fileWriteOutOfSpace))

        await #expect(throws: CocoaError.self) {
            try await captureState(to: saveFileURL, over: session)
        }

        #expect(FileManager.default.fileExists(atPath: saveFileURL.path(percentEncoded: false)))
        #expect(SavedStateVersion.read(at: saveFileURL) == nil)
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
