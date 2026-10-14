import Testing
import Foundation
@testable import Kernova

@Suite("RemovableMediaDeviceService Tests", .caseScoped)
@MainActor
struct RemovableMediaDeviceServiceTests {
    private func makeInstance(phase: VMLifecyclePhase = .running(sessionID: UUID()))
        -> VMInstance
    {
        VMInstanceFixture.make(name: "USB Test VM", phase: phase)
    }

    // MARK: - RemovableMediaDeviceInfo Model Tests

    @Test("RemovableMediaDeviceInfo displayName returns last path component")
    func removableMediaDeviceInfoDisplayName() {
        let info = RemovableMediaDeviceInfo(path: "/Users/test/disk.dmg", readOnly: true)
        #expect(info.displayName == "disk.dmg")
    }

    // MARK: - VMInstance State Tests

    @Test("The session's end clears liveRemovableMedia")
    func tearDownClearsRemovableMedia() {
        let instance = makeInstance()
        let context = instance.beginSessionContextForTesting()

        context.liveRemovableMedia.append(RemovableMediaDeviceInfo(path: "/tmp/a.dmg", readOnly: false))
        context.liveRemovableMedia.append(RemovableMediaDeviceInfo(path: "/tmp/b.dmg", readOnly: true))
        #expect(instance.liveRemovableMedia.count == 2)

        instance.handleSessionEvent(.guestDidStop)

        #expect(context.liveRemovableMedia.isEmpty)
    }

    @Test(
        "Removable media attach to a VM that presents a settled live session",
        arguments: zip(
            [
                PhaseFixture.settled(.running(sessionID: UUID())),
                .settled(.livePaused(sessionID: UUID())),
                .operating(.saving, from: .running(sessionID: UUID())),
                .settled(.suspended), .settled(.stopped),
            ],
            [true, true, false, false, false]))
    func canAttachFollowsLiveSession(phase: PhaseFixture, expected: Bool) {
        let instance = makeInstance(phase: phase.phase)
        #expect((instance.attachableSessionID != nil) == expected)
    }
}
