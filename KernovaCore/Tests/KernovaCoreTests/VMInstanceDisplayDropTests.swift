import Foundation
import KernovaCommandModel
import KernovaAgentCore
import KernovaAgentHost
import KernovaKit
import KernovaTestSupport
import KernovaWire
import SwiftProtobuf
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The three-state gate on dragging files onto a VM display: a VM that has never
/// run the agent is not a drag destination at all, one whose agent is away takes
/// part and refuses, and a reachable one accepts.
@Suite("VMInstance display drop availability", .caseScoped)
@MainActor
struct VMInstanceDisplayDropTests {
    /// A VM instance plus the socket pairs its drag-out service runs on.
    private final class Harness {
        let instance: VMInstance
        private var channels: [VsockChannel] = []
        private let stagingRoot = TestStagingRoot()

        @MainActor
        init(
            guestOS: VMGuestOS = .macOS, lastSeenAgentVersion: String? = "1.0.0",
            clipboardSharingEnabled: Bool = true, dropFilesEnabled: Bool = true,
            phase: VMLifecyclePhase = .running(sessionID: UUID())
        ) {
            instance = VMInstanceFixture.make(name: "Drop VM", guestOS: guestOS, phase: phase) {
                $0.lastSeenAgentVersion = lastSeenAgentVersion
                $0.clipboardSharingEnabled = clipboardSharingEnabled
                $0.dropFilesEnabled = dropFilesEnabled
            }
            // The services below are session state, so they need a session to
            // live in — the boot paths open one before any listener is wired.
            instance.beginSessionContextForTesting()
        }

        /// Publishes a hub snapshot whose DROP console peer is `peer`.
        @MainActor
        func publishConsolePeer(_ peer: PeerHandle?) {
            instance.publishAgentHubSnapshotForTesting(
                AgentHubSnapshot(
                    peers: [], features: FeatureStatus.merge([]), consolePeers: peer.map { [.drop: $0] } ?? [:]))
        }

        @MainActor
        @discardableResult
        func attachDrop() throws -> VsockChannel {
            let (guest, host) = try makePair()
            let service = VsockDropService(
                channel: host, label: "Drop VM", reporter: instance.clipboardTransfers,
                stagingRoot: stagingRoot.root, stagingKey: "drop-vm")
            instance.sessionContext?.vsock.drop = service
            service.start()
            return guest
        }

        /// Offers a one-file drag from the guest end and waits for the drop
        /// service to hold it.
        @MainActor
        func offerDrag(on guest: VsockChannel, generation: UInt64 = 1) async throws {
            try guest.send(
                .dragOffer(
                    generation: generation,
                    reps: [
                        RepInfo(uti: "public.data", byteCount: 4, filename: "a.bin", isInline: false)
                            .wire
                    ]))
            try await waitForChange {
                self.instance.vsockDropService?.guestDrag?.generation == generation
            }
        }

        @MainActor
        private func makePair() throws -> (guest: VsockChannel, host: VsockChannel) {
            let (guestFd, hostFd) = try makeRawSocketPair()
            let guest = VsockChannel(fileDescriptor: guestFd)
            let host = VsockChannel(fileDescriptor: hostFd)
            guest.start()
            host.start()
            channels.append(contentsOf: [guest, host])
            return (guest, host)
        }

        @MainActor
        func tearDown() {
            instance.vsockDropService?.stop()
            for channel in channels { channel.close() }
        }
    }

    @Test("a VM that has never seen an agent is not a drag destination")
    func neverConnectedIsNotADestination() {
        let harness = Harness(lastSeenAgentVersion: nil)
        defer { harness.tearDown() }

        #expect(harness.instance.displayDropAvailability == .none)
    }

    @Test("a Linux guest is never a drag destination — the agent is macOS-only")
    func linuxIsNotADestination() {
        // A Linux guest never records an agent version, so this is belt and
        // braces; the guest-OS check is what makes it explicit.
        let harness = Harness(guestOS: .linux, lastSeenAgentVersion: "1.0.0")
        defer { harness.tearDown() }

        #expect(harness.instance.displayDropAvailability == .none)
    }

    @Test("a VM whose agent has connected before, but isn't now, refuses the drag")
    func previouslyConnectedRefuses() {
        let harness = Harness()
        defer { harness.tearDown() }

        // Registered as a destination (not `.none`), so the drag participates and
        // springs back rather than passing through to whatever is behind.
        #expect(harness.instance.displayDropAvailability == .disconnected)
    }

    @Test("a hub whose peers offer no DROP still refuses")
    func requiresADropConsolePeer() {
        let harness = Harness()
        defer { harness.tearDown() }

        harness.publishConsolePeer(nil)

        #expect(harness.instance.displayDropAvailability == .disconnected)
        #expect(!harness.instance.dropOnGuest(FakePasteboard(), promises: []))
    }

    @Test("a DROP console peer makes a running VM a destination that takes the drop")
    func consolePeerMakesItAvailable() {
        let harness = Harness()
        defer { harness.tearDown() }

        harness.publishConsolePeer(PeerHandle(rawValue: 1))

        #expect(harness.instance.displayDropAvailability == .available)
    }

    // MARK: - The per-VM toggle

    @Test("a VM with drag and drop switched off is not a drag destination")
    func dropToggleOffIsNotADestination() {
        let harness = Harness(dropFilesEnabled: false)
        defer { harness.tearDown() }
        harness.publishConsolePeer(PeerHandle(rawValue: 1))

        // `.none` rather than `.disconnected`: the display unregisters, so a drag
        // over it behaves as if Kernova were not there at all.
        #expect(harness.instance.displayDropAvailability == .none)
        #expect(!harness.instance.dropOnGuest(FakePasteboard(), promises: []))
    }

    @Test("drag and drop is independent of clipboard sharing")
    func dropIsIndependentOfClipboardSharing() {
        let harness = Harness(clipboardSharingEnabled: false)
        defer { harness.tearDown() }

        harness.publishConsolePeer(PeerHandle(rawValue: 1))

        #expect(harness.instance.displayDropAvailability == .available)
        #expect(!harness.instance.configuration.clipboardSharingEnabled)
    }

    @Test("the policy turns DROP on and off with the drag and drop setting", arguments: [true, false])
    func policyFollowsTheSetting(enabled: Bool) {
        let harness = Harness(dropFilesEnabled: enabled)
        defer { harness.tearDown() }

        let policy = VMInstance.agentHubPolicy(for: harness.instance.configuration)

        #expect(policy.isEnabled(.drop) == enabled)
    }

    // MARK: - A VM that isn't running

    @Test("a paused VM refuses the drag — its guest is frozen, not gone")
    func pausedRefusesTheDrag() {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.publishConsolePeer(PeerHandle(rawValue: 1))

        // Pausing ends no connection, so the hub still names DROP's console
        // peer — only the phase says the guest cannot answer.
        harness.instance.activity.placeForTesting(.suspended)

        #expect(harness.instance.displayDropAvailability == .disconnected)
        #expect(!harness.instance.dropOnGuest(FakePasteboard(), promises: []))
    }

    @Test("losing DROP's console peer downgrades an available VM back to a refusal")
    func losingTheConsolePeerRefusesAgain() {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.publishConsolePeer(PeerHandle(rawValue: 1))
        #expect(harness.instance.displayDropAvailability == .available)

        harness.publishConsolePeer(nil)

        #expect(harness.instance.displayDropAvailability == .disconnected)
    }

    // MARK: - Reporting a drop the clipboard toggle has no say over

    @Test("a drop reports itself on a VM whose Clipboard Sharing is switched off")
    func dropReportsWithClipboardSharingOff() throws {
        let harness = Harness(clipboardSharingEnabled: false)
        defer { harness.tearDown() }
        let instance = harness.instance
        // The toggle closes the Clipboard window and disables the toolbar item
        // that carries the ring, which is why the menu-bar status item — driven
        // by this report alone — is where the drop has to show.
        #expect(!instance.activity.admits(.affordance(.clipboard), posture: .offer))

        let operation = ClipboardTransferOperation(
            gesture: .drop, direction: .outbound, peerName: instance.name, revealDelay: 0,
            clock: GatedEngineClock(), onCancelRequested: {},
            reporter: instance.clipboardTransfers)
        let readout = ClipboardProgressSnapshot(
            direction: .outbound, peerName: instance.name, currentItemName: "a.txt",
            filesCompleted: 0, fileCount: 1, bytesTransferred: 10, totalBytes: 100,
            bytesPerSecond: 10, secondsRemaining: 9, gesture: .drop, elapsedSeconds: 5,
            isCancellable: true, operationID: operation.id)
        instance.clipboardTransfers.publish(from: operation, .running(readout, since: Date()))

        guard case .running(let shown, _) = instance.clipboardTransferReport else {
            Issue.record("the drop left the status item's readout empty")
            return
        }
        #expect(shown.gesture == .drop)
        #expect(shown.isCancellable)
        // And that readout reveals itself in the status item's callout, so the
        // drop is seen without the user going looking for it.
        var reveal = ClipboardProgressAutoReveal()
        #expect(reveal.readoutChanged(shown, dropdownIsOpen: false, reveal: { true }) == .shown)
        // The Cancel it carries reaches the drop through the same report.
        #expect(instance.clipboardTransfers.cancel(shown.operationID))
        withExtendedLifetime(operation) {}
    }

    // MARK: - Dragging out

    /// A display that records only whether a take handed the press back.
    @MainActor
    private final class ResumeRecordingDisplay: GuestDragDisplay {
        private(set) var resumed = false
        let changed = AsyncGate()

        func injectNudge(_ nudge: GuestDragNudge) {}
        func injectDrag(at point: CGPoint) {}
        func returnToExitPoint() {}
        func injectRelease() {}
        func beginHostSession(carrying take: any GuestDragTaking) -> Bool { false }

        func resumeForwarding() {
            resumed = true
            changed.notify()
        }
    }

    /// What can stand between a guest's drag and its display.
    enum DragGate: CaseIterable, Sendable {
        case settingOff
        case notRunning
        case serviceStopped
    }

    @Test("a running macOS guest's drag is one its display may take")
    func guestDragIsOfferedToTheDisplay() async throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let guest = try harness.attachDrop()

        try await harness.offerDrag(on: guest)

        #expect(harness.instance.displayGuestDrag?.generation == 1)
        #expect(harness.instance.displayGuestDrag?.items.map(\.filename) == ["a.bin"])
    }

    @Test("the display is offered no guest drag past a gate", arguments: DragGate.allCases)
    func guestDragIsGated(_ gate: DragGate) async throws {
        let harness = Harness(dropFilesEnabled: gate != .settingOff)
        defer { harness.tearDown() }
        let guest = try harness.attachDrop()
        try await harness.offerDrag(on: guest)

        switch gate {
        case .settingOff: break
        case .notRunning: harness.instance.activity.placeForTesting(.suspended)
        case .serviceStopped: harness.instance.vsockDropService?.stop()
        }

        #expect(harness.instance.displayGuestDrag == nil)
        #expect(harness.instance.takeGuestDrag(display: ResumeRecordingDisplay()) == nil)
    }

    @Test("a Linux guest's display is never offered a drag")
    func linuxIsNeverOfferedADrag() async throws {
        let harness = Harness(guestOS: .linux)
        defer { harness.tearDown() }
        let guest = try harness.attachDrop()
        try await harness.offerDrag(on: guest)

        #expect(harness.instance.displayGuestDrag == nil)
    }

    @Test("a new press on the display clears the drag on offer")
    func pressClearsTheDrag() async throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let guest = try harness.attachDrop()
        try await harness.offerDrag(on: guest)

        harness.instance.displayPressBegan()

        #expect(harness.instance.displayGuestDrag == nil)
    }

    @Test("a take holds only while the VM runs: pausing hands the press back")
    func pausingAbandonsTheTake() async throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let guest = try harness.attachDrop()
        try await harness.offerDrag(on: guest)
        let display = ResumeRecordingDisplay()

        let take = try #require(harness.instance.takeGuestDrag(display: display))
        #expect(take.generation == 1)
        #expect(harness.instance.displayGuestDrag == nil)

        harness.instance.activity.placeForTesting(.suspended)

        try await display.changed.wait { display.resumed }
    }
}
