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
}
