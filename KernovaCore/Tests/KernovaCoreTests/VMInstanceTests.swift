import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaCommandModel
import KernovaAgentRuntime
import KernovaKit
import KernovaTestSupport
import KernovaWire
import SwiftProtobuf
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("VMInstance Tests", .caseScoped)
@MainActor
struct VMInstanceTests {
    // MARK: - The suspend slot

    @Test("A suspend slot only counts while nothing is live")
    func holdsSuspendedSessionNeedsAnAtRestPhase() throws {
        let instance = VMInstanceFixture.make(phase: .suspended)
        #expect(!instance.holdsSuspendedSession)

        try VMInstanceFixture.writeSaveFile(for: instance)
        for phase: VMLifecyclePhase in [.suspended, .stopped, .failed(message: "x"), .initialBoot] {
            instance.activity.placeForTesting(phase)
            #expect(instance.holdsSuspendedSession, "\(phase)")
            #expect(!instance.activity.admits(.edit(.machineKeys)), "\(phase)")
            #expect(instance.activity.admits(.resume), "\(phase)")
            #expect(instance.activity.admits(.operation(.deleting)), "\(phase)")
        }
        let live = VMLifecyclePhase.running(sessionID: UUID())
        for phase: VMLifecyclePhase in [
            live, .operating(.saving, from: live),
            .operating(.bringUp(.guestStart(.starting(recovery: false))), from: .stopped),
            .operating(.bringUp(.reverting(snapshotID: UUID(), resumesAfter: false)), from: .stopped),
        ] {
            instance.activity.placeForTesting(phase)
            #expect(!instance.holdsSuspendedSession, "\(phase)")
        }
    }

    @Test("A VM answers admission as it will stand once its saved state is discarded")
    func decideAfterTheSaveFileIsDeletedLiftsOnlyThatTerm() throws {
        let instance = VMInstanceFixture.make(phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: instance)
        let edit = VMAdmission.Request.edit(.machineKeys)

        #expect(!instance.activity.admits(edit))
        #expect(instance.activity.decide(edit, posture: .commit, after: .deletesSaveFile) == .admit)
        // A revert to a cold baseline lands it stopped too; a warm baseline's
        // lands it suspended on the baseline's own saved state.
        let cold = VMSnapshot(name: "Cold", kind: .cold, macAddress: nil)
        let warm = VMSnapshot(name: "Warm", kind: .warm, macAddress: nil)
        #expect(instance.activity.decide(edit, posture: .commit, after: .revertsToBaseline(cold)) == .admit)
        #expect(instance.activity.decide(edit, posture: .commit, after: .revertsToBaseline(warm)) != .admit)
        // The file is untouched, and the answer goes on reading it.
        #expect(instance.hasSaveFile)
        #expect(!instance.activity.admits(edit))

        // Only that term is lifted: a VM no phase admits the edit in stays
        // refused.
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        #expect(instance.activity.decide(edit, posture: .commit, after: .deletesSaveFile) != .admit)
    }

    // MARK: - effectiveMachineIdentifierData

    @Test("A file the install writes is the identifier, though the bundle was read before it existed")
    func effectiveMachineIDFollowsThePlatformFilesWrite() async throws {
        let machineFiles = MockVMBundleMachineFiles()
        let instance = VMInstanceFixture.make(
            guestOS: .macOS, bundleFactory: VMBundle.Factory(machineFiles: machineFiles))
        try FileManager.default.createDirectory(at: instance.bundleURL, withIntermediateDirectories: true)
        #expect(instance.machineIdentity == nil)

        let changed = ObservationFireRecorder()
        withObservationTracking {
            _ = instance.machineIdentity
        } onChange: {
            changed.record()
        }
        machineFiles.setPlatformMachineIdentifier(Data([7, 7, 7]))
        _ = try await withOperation(on: instance) { context in
            try await context.bundle.createMacPlatformFiles(hardwareModel: Data())
        }

        #expect(changed.didFire)
        #expect(instance.configuration.machineIdentifierData == nil)
        #expect(instance.machineIdentity == .mac(Data([7, 7, 7])))
    }

    // MARK: - machineIdentity

    @Test("A macOS guest's identity is its effective macOS identifier")
    func machineIdentityOfAMacOSGuest() throws {
        let configured = VMInstanceFixture.make(guestOS: .macOS) { $0.machineIdentifierData = Data([1]) }
        #expect(configured.machineIdentity == .mac(Data([1])))

        let fileOnly = VMInstanceFixture.make(guestOS: .macOS)
        try FileManager.default.createDirectory(at: fileOnly.bundleURL, withIntermediateDirectories: true)
        try Data([2]).write(to: fileOnly.bundleLayout.machineIdentifierURL)
        #expect(fileOnly.machineIdentity == .mac(Data([2])))
    }

    @Test("A Linux guest's identity is its generic identifier, and nil without one")
    func machineIdentityOfALinuxGuest() {
        let identified = VMInstanceFixture.make { $0.genericMachineIdentifierData = Data([3]) }
        #expect(identified.machineIdentity == .generic(Data([3])))
        #expect(VMInstanceFixture.make().machineIdentity == nil)
    }

    // MARK: - Bundle Paths

    @Test("Bundle path URLs are correctly derived from bundleURL")
    func bundlePaths() {
        let instance = VMInstanceFixture.make()

        #expect(instance.bundleLayout.saveFileURL.lastPathComponent == "SaveFile.vzvmsave")
    }

    // MARK: - Session Events

    @Test("a session event whose id matches no live session is dropped")
    func staleSessionEventIsDropped() {
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
        // No session attached: any delivered id is stale — the event a
        // torn-down session's guest stop produces after a fresh start.
        instance.activity.deliverSessionEvent(.guestDidStop, from: UUID())
        #expect(instance.status == .running)
    }
}
