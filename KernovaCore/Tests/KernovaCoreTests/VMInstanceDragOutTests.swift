import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import Testing
import UniformTypeIdentifiers

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// A hub whose item calls go nowhere.
final class FakeDragOutHub: DragOutHub, Sendable {
    func takeDrag(
        _ token: Data, of peer: PeerHandle,
        _ completion: @escaping @Sendable (Result<DragTakeID, WireError>) -> Void
    ) {}

    func pullItem(
        _ order: ItemPullOrder, from peer: PeerHandle,
        _ completion: @escaping @Sendable (Result<ItemPullID, WireError>) -> Void
    ) {}

    func cancelPull(_ id: ItemPullID, on peer: PeerHandle) {}

    func controlTake(_ id: DragTakeID, _ control: DragTakeControl, on peer: PeerHandle) {}

    func cancelTake(_ id: DragTakeID, on peer: PeerHandle) {}

    func releaseOffer(_ token: Data, of peer: PeerHandle) {}
}

/// The VM's own gates on its display taking a guest's drag over.
@Suite("VMInstance drag-out", .caseScoped)
@MainActor
struct VMInstanceDragOutTests {
    /// A display that does nothing a take asks of it.
    @MainActor
    private final class TrackingDisplay: GuestDragDisplay {
        func injectNudge(_ nudge: GuestDragNudge) {}
        func injectDrag(at point: CGPoint) {}
        func returnToExitPoint() {}
        func injectRelease() {}
        func beginHostSession(carrying take: any GuestDragTaking) -> Bool { false }
        func resumeTracking() {}
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
