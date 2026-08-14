import AppKit
import Testing

@testable import Kernova

@Suite("VMDisplayBackingView Tests")
@MainActor
struct VMDisplayBackingViewTests {
    @Test("update carries automaticallyReconfiguresDisplay through to the machine view")
    func updateAppliesAutoResizeFlag() {
        let backing = VMDisplayBackingView(frame: .zero)
        #expect(backing.machineView.automaticallyReconfiguresDisplay == true)

        backing.update(
            virtualMachine: nil, isPaused: false, transitionText: nil,
            automaticallyReconfiguresDisplay: false)
        #expect(backing.machineView.automaticallyReconfiguresDisplay == false)

        backing.update(
            virtualMachine: nil, isPaused: false, transitionText: nil,
            automaticallyReconfiguresDisplay: true)
        #expect(backing.machineView.automaticallyReconfiguresDisplay == true)
    }

    @Test("apply reaches the machine view without an update pass")
    func applyAutoResizeFlagStandalone() {
        let backing = VMDisplayBackingView(frame: .zero)

        backing.apply(automaticallyReconfiguresDisplay: false)
        #expect(backing.machineView.automaticallyReconfiguresDisplay == false)

        // Re-applying the same value is a no-op, and the next change still lands.
        backing.apply(automaticallyReconfiguresDisplay: false)
        #expect(backing.machineView.automaticallyReconfiguresDisplay == false)

        backing.apply(automaticallyReconfiguresDisplay: true)
        #expect(backing.machineView.automaticallyReconfiguresDisplay == true)
    }

    @Test("detach clears the machine view and leaves the auto-resize flag alone")
    func detachClearsWithoutTouchingTheFlag() {
        let backing = VMDisplayBackingView(frame: .zero)
        backing.apply(automaticallyReconfiguresDisplay: false)

        backing.detach()

        #expect(backing.machineView.virtualMachine == nil)
        #expect(backing.machineView.automaticallyReconfiguresDisplay == false)
    }

    // MARK: - File drop

    /// A dragging info carrying whatever `pasteboard` holds; only the pasteboard
    /// is read by the drop path.
    private final class StubDraggingInfo: NSObject, @unchecked Sendable, NSDraggingInfo {
        // `nonisolated` so the conformance stays outside the main actor:
        // `NSDraggingInfo` is a nonisolated protocol, and only the drop path's
        // reads of `draggingPasteboard` matter here. The stub is immutable
        // apart from the two settable properties AppKit requires, which nothing
        // in these tests writes.
        nonisolated(unsafe) let draggingPasteboard: NSPasteboard
        init(pasteboard: NSPasteboard) { self.draggingPasteboard = pasteboard }

        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggingLocation: NSPoint { .zero }
        var draggedImageLocation: NSPoint { .zero }
        var draggedImage: NSImage? { nil }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 0 }
        var animatesToDestination: Bool = false
        var numberOfValidItemsForDrop: Int = 0
        var draggingFormation: NSDraggingFormation = .default
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        func enumerateDraggingItems(
            options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
            classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
            using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
        ) {}
        func resetSpringLoading() {}
    }

    /// A uniquely-named pasteboard holding `urls` as file URLs.
    private func makeFileDrag(_ urls: [URL]) -> StubDraggingInfo {
        let pasteboard = NSPasteboard(name: .init("VMDisplayBackingViewTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        return StubDraggingInfo(pasteboard: pasteboard)
    }

    private func makeTextDrag(_ text: String) -> StubDraggingInfo {
        let pasteboard = NSPasteboard(name: .init("VMDisplayBackingViewTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return StubDraggingInfo(pasteboard: pasteboard)
    }

    @Test("a VM that never ran the agent is not a drag destination at all")
    func neverConnectedRegistersNothing() {
        let backing = VMDisplayBackingView(frame: .zero)
        backing.dropAvailability = { .none }

        backing.applyDropRegistration()

        #expect(backing.registeredDraggedTypes.isEmpty)
    }

    @Test("a VM whose agent has connected before registers, even while disconnected")
    func disconnectedStillRegisters() {
        let backing = VMDisplayBackingView(frame: .zero)
        var availability = DisplayDropAvailability.disconnected
        backing.dropAvailability = { availability }

        backing.applyDropRegistration()
        #expect(backing.registeredDraggedTypes == [.fileURL])

        // Registration is idempotent, and follows availability back down.
        backing.applyDropRegistration()
        #expect(backing.registeredDraggedTypes == [.fileURL])

        availability = .none
        backing.applyDropRegistration()
        #expect(backing.registeredDraggedTypes.isEmpty)
    }

    @Test("a disconnected agent refuses the drag with the empty operation")
    func disconnectedRefusesTheDrag() {
        let backing = VMDisplayBackingView(frame: .zero)
        backing.dropAvailability = { .disconnected }
        backing.applyDropRegistration()
        let drag = makeFileDrag([URL(fileURLWithPath: "/tmp/a.txt")])

        // The empty operation is what makes the pointer show no accept badge and
        // a release spring back — no custom rejection UI.
        #expect(backing.draggingEntered(drag) == [])
        #expect(backing.draggingUpdated(drag) == [])
    }

    @Test("a reachable agent accepts a file drag with .copy")
    func availableAcceptsFileURLs() {
        let backing = VMDisplayBackingView(frame: .zero)
        backing.dropAvailability = { .available }
        backing.applyDropRegistration()
        let drag = makeFileDrag([URL(fileURLWithPath: "/tmp/a.txt")])

        #expect(backing.draggingEntered(drag) == .copy)
        #expect(backing.draggingUpdated(drag) == .copy)
    }

    @Test("a drag carrying no file URL is refused even when the agent is reachable")
    func refusesNonFileDrags() {
        let backing = VMDisplayBackingView(frame: .zero)
        backing.dropAvailability = { .available }
        backing.applyDropRegistration()

        #expect(backing.draggingEntered(makeTextDrag("hello")) == [])
    }

    @Test("a drop forwards every dragged file URL")
    func dropForwardsTheURLs() {
        let backing = VMDisplayBackingView(frame: .zero)
        backing.dropAvailability = { .available }
        var received: [URL] = []
        backing.onDropFiles = { urls in
            received = urls
            return true
        }
        let dropped = [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.txt")]

        #expect(backing.performDragOperation(makeFileDrag(dropped)))
        #expect(received.map(\.lastPathComponent) == ["a.txt", "b.txt"])
    }

    @Test("a drop re-checks availability, so a session lost mid-drag springs back")
    func dropRechecksAvailability() {
        let backing = VMDisplayBackingView(frame: .zero)
        var availability = DisplayDropAvailability.available
        backing.dropAvailability = { availability }
        var forwarded = false
        backing.onDropFiles = { _ in
            forwarded = true
            return true
        }
        let drag = makeFileDrag([URL(fileURLWithPath: "/tmp/a.txt")])
        #expect(backing.draggingUpdated(drag) == .copy)

        // The guest agent goes away between the last pointer move and the release.
        availability = .disconnected
        #expect(!backing.performDragOperation(drag))
        #expect(!forwarded)
    }

    @Test("a refused send reports the drop as not taken")
    func reportsARefusedSend() {
        let backing = VMDisplayBackingView(frame: .zero)
        backing.dropAvailability = { .available }
        backing.onDropFiles = { _ in false }

        #expect(!backing.performDragOperation(makeFileDrag([URL(fileURLWithPath: "/tmp/a.txt")])))
    }
}
