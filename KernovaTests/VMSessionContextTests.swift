import Darwin
import Foundation
import KernovaTestSupport
import Observation
import Testing
import Virtualization

@testable import Kernova

/// Box for `withObservationTracking`'s `@Sendable` `onChange`, which runs inline
/// in the mutating property's `willSet` — on whatever actor performed the write.
private final class ObservationFlag: @unchecked Sendable {
    private(set) var fired = false
    func fire() { fired = true }
}

/// A sink target that keeps whatever descriptor it is handed open, so EOF on
/// the peer proves the sink was cleared rather than never set.
private final class RetainingAcceptor: VsockDataConnectionAccepting {
    nonisolated func acceptDataConnection(fd: Int32) {}
}

/// The session context as the unit scoping rests on: what one boot attempt
/// opens, what a teardown releases, and that a projection off it still reaches
/// every observer the loose fields used to.
@Suite("VMSessionContext", .admissionGated)
@MainActor
struct VMSessionContextTests {
    private func makeInstance(
        guestOS: VMGuestOS = .macOS, phase: VMLifecyclePhase = .running(sessionID: UUID())
    ) -> VMInstance {
        VMInstanceFixture.make(name: "Session Context VM", guestOS: guestOS, phase: phase) {
            $0.dropFilesEnabled = true
            $0.lastSeenAgentVersion = "0.9.2"
        }
    }

    /// Whether mutating through `mutate` wakes an observer that reads `track`.
    ///
    /// The `onChange` fires synchronously in the mutated property's `willSet`,
    /// so the flag is readable the moment `mutate` returns — no drain needed.
    private func observationFires(
        reading track: @MainActor () -> Void,
        on mutate: @MainActor () -> Void
    ) -> Bool {
        let flag = ObservationFlag()
        withObservationTracking {
            track()
        } onChange: {
            flag.fire()
        }
        mutate()
        return flag.fired
    }

    /// One attached passthrough accessory, for the live-state assertions.
    static func attachedAccessory(
        deviceID: UUID = UUID(), registryID: UInt64 = 0x1_0000
    ) -> AttachedUSBAccessory {
        AttachedUSBAccessory(
            deviceID: deviceID,
            accessory: MockUSBAccessoryService.accessory(registryID: registryID))
    }

    // MARK: - Teardown

    @Test("tearDown releases every service, pipe and hand-off the session held")
    func tearDownReleasesEverything() throws {
        let instance = makeInstance(guestOS: .linux)
        let context = instance.beginSessionContextForTesting()

        context.serialInputPipe = Pipe()
        context.serialOutputPipe = Pipe()
        context.clipboardInputPipe = Pipe()
        context.clipboardOutputPipe = Pipe()
        let clipboard = SpiceClipboardService(inputPipe: Pipe(), outputPipe: Pipe())
        context.clipboardService = clipboard
        instance.clipboardDataSink.set(RetainingAcceptor())
        context.liveRemovableMedia = [RemovableMediaDeviceInfo(path: "/tmp/media.iso", readOnly: true)]
        context.liveUSBAccessories = [Self.attachedAccessory()]
        context.agentExpectedButMissing = true
        context.hasSeenAgentThisSession = true
        context.networkAttachmentPending = true
        context.vsock.livePolicyApplication = Task<Void, Never> {}

        context.tearDown()

        #expect(context.serialInputPipe == nil)
        #expect(context.serialOutputPipe == nil)
        #expect(context.clipboardInputPipe == nil)
        #expect(context.clipboardOutputPipe == nil)
        #expect(context.clipboardService == nil)
        #expect(context.vsock.control == nil)
        #expect(context.vsock.log == nil)
        #expect(context.vsock.clipboard == nil)
        #expect(context.vsock.drop == nil)
        #expect(context.networkAttachmentCoordinator == nil)
        #expect(context.liveRemovableMedia.isEmpty)
        #expect(context.liveUSBAccessories.isEmpty)
        #expect(context.agentExpectedButMissing == false)
        #expect(context.hasSeenAgentThisSession == false)
        #expect(context.networkAttachmentPending == false)
        #expect(context.session == nil)
        #expect(context.agentPostStartTask == nil)
        #expect(context.vsock.livePolicyApplication == nil)
        // The instance-owned sinks the session published into are cleared too:
        // a descriptor handed to a cleared sink is closed, which its peer sees
        // as EOF.
        let (owned, peer) = try makeRawSocketPair()
        defer { close(peer) }  // `owned` is the sink's to close.
        instance.clipboardDataSink.accept(fd: owned)
        #expect(fcntl(peer, F_SETFL, O_NONBLOCK) >= 0)
        var byte: UInt8 = 0
        #expect(recv(peer, &byte, 1, 0) == 0)
    }

    @Test("tearDownSession drops the context, and every projection reads empty after")
    func tearDownSessionDropsTheContext() {
        let instance = makeInstance()
        instance.beginSessionContextForTesting(bootedIntoRecovery: true)
        #expect(instance.sessionContext != nil)

        instance.handleSessionEvent(.guestDidStop)

        #expect(instance.sessionContext == nil)
        #expect(instance.session == nil)
        #expect(instance.clipboardService == nil)
        #expect(instance.vsockControlService == nil)
        #expect(instance.vsockDropService == nil)
        #expect(instance.vsockLogService == nil)
        #expect(instance.networkAttachmentCoordinator == nil)
        #expect(instance.networkAttachmentPending == false)
        #expect(instance.liveRemovableMedia.isEmpty)
        #expect(instance.liveUSBAccessories.isEmpty)
        #expect(instance.bootedIntoRecovery == false)
        #expect(instance.agentExpectedButMissing == false)
        #expect(instance.hasSeenAgentThisSession == false)
    }

    private static func buildResult(
        coldRemovableMedia: [RemovableMediaDeviceInfo] = []
    ) -> ConfigurationBuilder.BuildResult {
        ConfigurationBuilder.BuildResult(
            configuration: VZVirtualMachineConfiguration(),
            serialInputPipe: Pipe(),
            serialOutputPipe: Pipe(),
            clipboardInputPipe: Pipe(),
            clipboardOutputPipe: Pipe(),
            coldRemovableMedia: coldRemovableMedia,
            vmnetNetworks: MockVmnetNetworkProvider(),
            entitlements: .unentitled)
    }

    @Test("A bring-up that tries again releases the previous attempt's context before opening the next")
    func retriedAttemptReleasesThePriorContext() async throws {
        let instance = makeInstance(phase: .stopped)
        try await instance.activity.bringUp(.starting(recovery: false)) { context in
            let first = instance.beginSessionContext(context)
            first.serialInputPipe = Pipe()

            context.operation.endSession()

            // Drained, not merely dropped — an unreleased context would keep
            // its VZ session and security scopes alive with nothing left
            // pointing at it.
            #expect(first.serialInputPipe == nil)
            #expect(instance.sessionContext == nil)
            let second = instance.beginSessionContext(context)
            #expect(second !== first)
            #expect(instance.sessionContext === second)
            return .rest(.atRest(.stopped), ())
        }
        // A bring-up that ends at rest releases the context it left open.
        #expect(instance.sessionContext == nil)
    }

    // MARK: - Build result

    @Test("adoptBuildResult takes the build's pipes and cold-attached media")
    func adoptBuildResultPopulatesTheContext() async throws {
        let instance = makeInstance(guestOS: .linux, phase: .stopped)
        let media = RemovableMediaDeviceInfo(path: "/tmp/cold.iso", readOnly: true)
        let result = Self.buildResult(coldRemovableMedia: [media])

        try await instance.activity.bringUp(.starting(recovery: false)) { context in
            let session = instance.beginSessionContext(context)
            instance.adoptBuildResult(context, result)

            #expect(session.serialInputPipe === result.serialInputPipe)
            #expect(session.serialOutputPipe === result.serialOutputPipe)
            #expect(session.clipboardInputPipe === result.clipboardInputPipe)
            #expect(session.clipboardOutputPipe === result.clipboardOutputPipe)
            #expect(instance.liveRemovableMedia == [media])
            return .rest(.atRest(.stopped), ())
        }
    }

    // MARK: - Runtime removable media write surface

    @Test("recordAttachedMedia appends, and a second call appends rather than replaces")
    func recordAttachedMediaAppends() {
        let sessionID = UUID()
        let instance = makeInstance(phase: .running(sessionID: sessionID))
        instance.beginSessionContextForTesting()
        let first = RemovableMediaDeviceInfo(path: "/tmp/a.iso", readOnly: true)
        let second = RemovableMediaDeviceInfo(path: "/tmp/b.iso", readOnly: false)

        instance.recordAttachedMedia(first, for: sessionID)
        instance.recordAttachedMedia(second, for: sessionID)

        #expect(instance.liveRemovableMedia == [first, second])
    }

    @Test("forgetAttachedMedia removes only the matching entry")
    func forgetAttachedMediaRemovesOnlyTheMatch() {
        let sessionID = UUID()
        let instance = makeInstance(phase: .running(sessionID: sessionID))
        instance.beginSessionContextForTesting()
        let kept = RemovableMediaDeviceInfo(path: "/tmp/keep.iso", readOnly: true)
        let removed = RemovableMediaDeviceInfo(path: "/tmp/remove.iso", readOnly: false)
        instance.recordAttachedMedia(kept, for: sessionID)
        instance.recordAttachedMedia(removed, for: sessionID)

        instance.forgetAttachedMedia(deviceID: removed.id, for: sessionID)

        #expect(instance.liveRemovableMedia == [kept])
    }

    @Test("recordAttachedMedia and forgetAttachedMedia are no-ops, logged, with no session open")
    func mediaWritesAreNoOpsWithNoSessionOpen() {
        let sessionID = UUID()
        let instance = makeInstance(phase: .running(sessionID: sessionID))
        instance.beginSessionContextForTesting()
        instance.handleSessionEvent(.guestDidStop)
        #expect(instance.sessionContext == nil)

        instance.recordAttachedMedia(RemovableMediaDeviceInfo(path: "/tmp/late.iso", readOnly: true), for: sessionID)
        instance.forgetAttachedMedia(deviceID: UUID(), for: sessionID)

        #expect(instance.liveRemovableMedia.isEmpty)
    }

    @Test("A media write for a superseded session leaves the successor's tracking alone")
    func mediaWritesForASupersededSessionAreDropped() async throws {
        let sessionA = UUID()
        let instance = makeInstance(phase: .running(sessionID: sessionA))
        instance.beginSessionContextForTesting()
        let carried = RemovableMediaDeviceInfo(path: "/tmp/carried.iso", readOnly: true)
        instance.recordAttachedMedia(carried, for: sessionA)

        // Force stop, then a restart whose cold boot re-registers the same item.
        instance.handleSessionEvent(.guestDidStop)
        let coldBooted = RemovableMediaDeviceInfo(id: carried.id, path: "/tmp/carried.iso", readOnly: true)
        try await instance.activity.bringUp(.starting(recovery: false)) { context in
            instance.beginSessionContext(context)
            instance.adoptBuildResult(context, Self.buildResult(coldRemovableMedia: [coldBooted]))
            context.bindSessionForTesting(UUID())
            return .rest(.live(.running), ())
        }

        instance.recordAttachedMedia(carried, for: sessionA)
        instance.forgetAttachedMedia(deviceID: carried.id, for: sessionA)

        #expect(instance.liveRemovableMedia == [coldBooted])
    }

    // MARK: - Observation propagation
    //
    // A projection is computed, so an observer reading one registers two
    // dependencies: the instance's context slot, and the context's own
    // property. Both edges have to wake it, or a UI surface silently stops
    // updating — the failure this shape is most likely to regress into.

    @Test("A context field change wakes an observer reading through the projection")
    func contextFieldChangeWakesTheObserver() {
        let sessionID = UUID()
        let instance = makeInstance(phase: .running(sessionID: sessionID))
        let context = instance.beginSessionContextForTesting()

        #expect(
            observationFires(reading: { _ = instance.networkAttachmentPending }) {
                context.networkAttachmentPending = true
            })
        #expect(
            observationFires(reading: { _ = instance.agentStatus }) {
                context.agentExpectedButMissing = true
            })
        #expect(
            observationFires(reading: { _ = instance.displayDropAvailability }) {
                context.vsock.drop = nil
            })
        #expect(
            observationFires(reading: { _ = instance.liveRemovableMedia }) {
                context.liveRemovableMedia = [RemovableMediaDeviceInfo(path: "/tmp/a.iso", readOnly: true)]
            })
        #expect(
            observationFires(reading: { _ = instance.liveRemovableMedia }) {
                instance.recordAttachedMedia(
                    RemovableMediaDeviceInfo(path: "/tmp/b.iso", readOnly: true), for: sessionID)
            })
    }

    @Test("Opening a context wakes an observer that read the empty projection")
    func openingTheContextWakesTheObserver() {
        // The slot edge on its own: with no context the projections
        // short-circuit at `sessionContext`, so that access is the only
        // dependency registered — and opening one has to be enough.
        for track in [
            { @MainActor (instance: VMInstance) in _ = instance.networkAttachmentPending },
            { @MainActor (instance: VMInstance) in _ = instance.agentStatus },
            { @MainActor (instance: VMInstance) in _ = instance.displayDropAvailability },
            { @MainActor (instance: VMInstance) in _ = instance.clipboardService },
            { @MainActor (instance: VMInstance) in _ = instance.liveRemovableMedia },
        ] {
            let instance = makeInstance()
            #expect(
                observationFires(reading: { track(instance) }) {
                    instance.beginSessionContextForTesting()
                })
        }
    }

    @Test("Releasing the context wakes an observer reading through the projection")
    func releasingTheContextWakesTheObserver() {
        for track in [
            { @MainActor (instance: VMInstance) in _ = instance.networkAttachmentPending },
            { @MainActor (instance: VMInstance) in _ = instance.agentStatus },
            { @MainActor (instance: VMInstance) in _ = instance.displayDropAvailability },
            { @MainActor (instance: VMInstance) in _ = instance.clipboardService },
            { @MainActor (instance: VMInstance) in _ = instance.liveRemovableMedia },
        ] {
            let instance = makeInstance()
            instance.beginSessionContextForTesting()
            #expect(
                observationFires(reading: { track(instance) }) {
                    instance.handleSessionEvent(.guestDidStop)
                })
        }
    }
}
