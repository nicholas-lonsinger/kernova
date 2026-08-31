import Darwin
import Foundation
import KernovaKit
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
        var config = VMConfiguration(
            name: "Session Context VM", guestOS: guestOS,
            bootMode: guestOS == .macOS ? .macOS : .efi)
        config.dropFilesEnabled = true
        config.lastSeenAgentVersion = "0.9.2"
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL, phase: phase)
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

    // MARK: - Teardown

    @Test("tearDown releases every service, pipe and hand-off the session held")
    func tearDownReleasesEverything() throws {
        let instance = makeInstance(guestOS: .linux)
        let context = instance.beginSessionContext()

        context.serialInputPipe = Pipe()
        context.serialOutputPipe = Pipe()
        context.clipboardInputPipe = Pipe()
        context.clipboardOutputPipe = Pipe()
        let clipboard = SpiceClipboardService(inputPipe: Pipe(), outputPipe: Pipe())
        context.clipboardService = clipboard
        instance.clipboardDataSink.set(RetainingAcceptor())
        context.liveRemovableMedia = [USBDeviceInfo(path: "/tmp/media.iso", readOnly: true)]
        context.agentExpectedButMissing = true
        context.hasSeenAgentThisSession = true
        context.networkAttachmentPending = true
        context.livePolicyApplication = Task<Void, Never> {}

        context.tearDown()

        #expect(context.serialInputPipe == nil)
        #expect(context.serialOutputPipe == nil)
        #expect(context.clipboardInputPipe == nil)
        #expect(context.clipboardOutputPipe == nil)
        #expect(context.clipboardService == nil)
        #expect(context.vsockControlService == nil)
        #expect(context.vsockLogService == nil)
        #expect(context.vsockDropService == nil)
        #expect(context.networkAttachmentCoordinator == nil)
        #expect(context.liveRemovableMedia.isEmpty)
        #expect(context.agentExpectedButMissing == false)
        #expect(context.hasSeenAgentThisSession == false)
        #expect(context.networkAttachmentPending == false)
        #expect(context.session == nil)
        #expect(context.agentPostStartTask == nil)
        #expect(context.livePolicyApplication == nil)
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
        instance.beginSessionContext(bootedIntoRecovery: true)
        #expect(instance.sessionContext != nil)

        instance.tearDownSession(restingAt: .stopped)

        #expect(instance.sessionContext == nil)
        #expect(instance.session == nil)
        #expect(instance.clipboardService == nil)
        #expect(instance.vsockControlService == nil)
        #expect(instance.vsockDropService == nil)
        #expect(instance.vsockLogService == nil)
        #expect(instance.networkAttachmentCoordinator == nil)
        #expect(instance.networkAttachmentPending == false)
        #expect(instance.liveRemovableMedia.isEmpty)
        #expect(instance.bootedIntoRecovery == false)
        #expect(instance.agentExpectedButMissing == false)
        #expect(instance.hasSeenAgentThisSession == false)
    }

    @Test("beginSessionContext replaces a prior context, releasing what it held")
    func beginSessionContextReplacesThePriorOne() {
        let instance = makeInstance()
        let first = instance.beginSessionContext()
        first.serialInputPipe = Pipe()

        let second = instance.beginSessionContext()

        #expect(second !== first)
        #expect(instance.sessionContext === second)
        // The displaced context is drained, not merely dropped — an unreleased
        // one would keep its VZ session and security scopes alive with nothing
        // left pointing at it.
        #expect(first.serialInputPipe == nil)
    }

    // MARK: - Build result

    @Test("adoptBuildResult takes the build's pipes and cold-attached media")
    func adoptBuildResultPopulatesTheContext() {
        let instance = makeInstance(guestOS: .linux)
        let context = instance.beginSessionContext()
        let media = USBDeviceInfo(path: "/tmp/cold.iso", readOnly: true)
        let result = ConfigurationBuilder.BuildResult(
            configuration: VZVirtualMachineConfiguration(),
            serialInputPipe: Pipe(),
            serialOutputPipe: Pipe(),
            clipboardInputPipe: Pipe(),
            clipboardOutputPipe: Pipe(),
            coldRemovableMedia: [media])

        instance.adoptBuildResult(result)

        #expect(context.serialInputPipe === result.serialInputPipe)
        #expect(context.serialOutputPipe === result.serialOutputPipe)
        #expect(context.clipboardInputPipe === result.clipboardInputPipe)
        #expect(context.clipboardOutputPipe === result.clipboardOutputPipe)
        #expect(instance.liveRemovableMedia == [media])
    }

    // MARK: - Observation propagation
    //
    // A projection is computed, so an observer reading one registers two
    // dependencies: the instance's context slot, and the context's own
    // property. Both edges have to wake it, or a UI surface silently stops
    // updating — the failure this shape is most likely to regress into.

    @Test("A context field change wakes an observer reading through the projection")
    func contextFieldChangeWakesTheObserver() {
        let instance = makeInstance()
        let context = instance.beginSessionContext()

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
                context.vsockDropService = nil
            })
        #expect(
            observationFires(reading: { _ = instance.liveRemovableMedia }) {
                context.liveRemovableMedia = [USBDeviceInfo(path: "/tmp/a.iso", readOnly: true)]
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
                    instance.beginSessionContext()
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
            instance.beginSessionContext()
            #expect(
                observationFires(reading: { track(instance) }) {
                    instance.tearDownSession(restingAt: .stopped)
                })
        }
    }
}
