import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaAgentRuntime
import KernovaCommandModel
import KernovaFileTree
import KernovaItemTransfer
import KernovaKit
import KernovaSynchronization
import KernovaTestSupport
import KernovaWire
import Testing
import UniformTypeIdentifiers

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The hub's item calls, each recorded with its completion for the test to
/// answer.
final class FakeDragOutHub: DragOutHub, Sendable {
    struct State {
        var takes: [(token: Data, peer: PeerHandle, completion: @Sendable (Result<DragTakeID, WireError>) -> Void)] =
            []
        var pulls:
            [(
                order: ItemPullOrder, peer: PeerHandle,
                completion: @Sendable (Result<ItemPullID, WireError>) -> Void
            )] = []
        var cancels: [ItemPullID] = []
        var releases: [(token: Data, peer: PeerHandle)] = []
        var controls: [(id: DragTakeID, control: DragTakeControl)] = []
        var takeCancels: [DragTakeID] = []
    }

    let state = Locked(State())
    let changed = AsyncGate()
    /// Fires on every `deliver`, so a thread off the main actor can wait for it.
    let delivering = DispatchSemaphore(value: 0)

    func takeDrag(
        _ token: Data, of peer: PeerHandle,
        _ completion: @escaping @Sendable (Result<DragTakeID, WireError>) -> Void
    ) {
        state.withLock { $0.takes.append((token, peer, completion)) }
        changed.notify()
    }

    func pullItem(
        _ order: ItemPullOrder, from peer: PeerHandle,
        _ completion: @escaping @Sendable (Result<ItemPullID, WireError>) -> Void
    ) {
        state.withLock { $0.pulls.append((order, peer, completion)) }
        changed.notify()
    }

    func cancelPull(_ id: ItemPullID, on peer: PeerHandle) {
        state.withLock { $0.cancels.append(id) }
        changed.notify()
    }

    func controlTake(_ id: DragTakeID, _ control: DragTakeControl, on peer: PeerHandle) {
        state.withLock { $0.controls.append((id, control)) }
        if control == .deliver { delivering.signal() }
        changed.notify()
    }

    func cancelTake(_ id: DragTakeID, on peer: PeerHandle) {
        state.withLock { $0.takeCancels.append(id) }
        changed.notify()
    }

    func releaseOffer(_ token: Data, of peer: PeerHandle) {
        state.withLock { $0.releases.append((token, peer)) }
        changed.notify()
    }

    var controls: [DragTakeControl] { state.withLock { $0.controls.map(\.control) } }
}

/// The VM's own gates on its display taking a guest's drag over.
@Suite("VMInstance drag-out", .caseScoped)
@MainActor
struct VMInstanceDragOutTests {
    /// A display that records only whether a take handed the press back.
    @MainActor
    private final class TrackingDisplay: GuestDragDisplay {
        private(set) var resumed = false
        let changed = AsyncGate()

        func injectNudge(_ nudge: GuestDragNudge) {}
        func injectDrag(at point: CGPoint) {}
        func returnToExitPoint() {}
        func injectRelease() {}
        func beginHostSession(carrying take: any GuestDragTaking) -> Bool { false }
        func resumeTracking() {
            resumed = true
            changed.notify()
        }
    }

    private let hub = FakeDragOutHub()
    private let peer = PeerHandle(rawValue: 3)
    private let token = Data(repeating: 0x5A, count: 16)

    private func makeInstance(dropFilesEnabled: Bool = true) async throws -> VMInstance {
        let instance = VMInstanceFixture.make(name: "Drag VM", guestOS: .macOS, phase: .running(sessionID: UUID())) {
            $0.dropFilesEnabled = dropFilesEnabled
        }
        instance.dragOut.hub = hub
        instance.dragOut.consolePeerChanged(peer)
        instance.dragOut.offerReceived(token, from: peer)
        try await waitForChange { instance.dragOut.offer != nil }
        return instance
    }

    @Test("with drag and drop off, the display is offered no guest drag")
    func settingOffGates() async throws {
        let instance = try await makeInstance(dropFilesEnabled: false)

        #expect(instance.displayGuestDrag == nil)
        #expect(instance.takeGuestDrag(display: TrackingDisplay()) == nil)
    }
}
