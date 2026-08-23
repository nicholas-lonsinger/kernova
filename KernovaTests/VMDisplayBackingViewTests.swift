import AppKit
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("VMDisplayBackingView Tests", .admissionGated)
@MainActor
struct VMDisplayBackingViewTests {
    @Test("update carries automaticallyReconfiguresDisplay through to the machine view")
    func updateAppliesAutoResizeFlag() {
        let backing = VMDisplayBackingView(frame: .zero)
        #expect(backing.machineView.automaticallyReconfiguresDisplay == true)

        backing.update(
            display: nil, isPaused: false, transitionText: nil,
            automaticallyReconfiguresDisplay: false)
        #expect(backing.machineView.automaticallyReconfiguresDisplay == false)

        backing.update(
            display: nil, isPaused: false, transitionText: nil,
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
        #expect(backing.registeredDraggedTypes.contains(.fileURL))

        // Registration is idempotent, and follows availability back down.
        let registered = backing.registeredDraggedTypes
        backing.applyDropRegistration()
        #expect(backing.registeredDraggedTypes == registered)

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

    @Test("a file promise's types are registered alongside concrete file URLs")
    func registersPromiseTypes() {
        let backing = VMDisplayBackingView(frame: .zero)
        backing.dropAvailability = { .available }

        backing.applyDropRegistration()

        for promised in NSFilePromiseReceiver.readableDraggedTypes {
            #expect(backing.registeredDraggedTypes.contains(.init(promised)))
        }
    }

    // MARK: - The reject cursor

    @Test("a refused drag shows the not-allowed cursor, and leaving clears it")
    func refusedDragShowsTheRejectCursor() {
        let backing = VMDisplayBackingView(frame: .zero)
        backing.dropAvailability = { .disconnected }
        var pushes: [Bool] = []
        backing.applyRejectCursor = { pushes.append($0) }
        let drag = makeFileDrag([URL(fileURLWithPath: "/tmp/a.txt")])

        #expect(backing.draggingEntered(drag) == [])
        #expect(pushes == [true])
        // Repeated updates leave the pushed cursor where it is rather than
        // stacking a second one.
        #expect(backing.draggingUpdated(drag) == [])
        #expect(pushes == [true])

        backing.draggingExited(drag)
        #expect(pushes == [true, false])
    }

    @Test("a drag this display accepts pushes no cursor at all")
    func acceptedDragPushesNothing() {
        let backing = VMDisplayBackingView(frame: .zero)
        backing.dropAvailability = { .available }
        var pushes: [Bool] = []
        backing.applyRejectCursor = { pushes.append($0) }

        #expect(backing.draggingEntered(makeFileDrag([URL(fileURLWithPath: "/tmp/a.txt")])) == .copy)
        #expect(pushes.isEmpty)
    }

    @Test("availability changing mid-drag flips the cursor on the next update")
    func cursorFollowsAvailabilityMidDrag() {
        let backing = VMDisplayBackingView(frame: .zero)
        var availability = DisplayDropAvailability.disconnected
        backing.dropAvailability = { availability }
        var pushes: [Bool] = []
        backing.applyRejectCursor = { pushes.append($0) }
        let drag = makeFileDrag([URL(fileURLWithPath: "/tmp/a.txt")])

        // A drag that began while the VM was paused, over a VM that then resumes.
        #expect(backing.draggingEntered(drag) == [])
        availability = .available
        #expect(backing.draggingUpdated(drag) == .copy)
        #expect(pushes == [true, false])

        // …and back, when the agent goes away under the same drag.
        availability = .disconnected
        #expect(backing.draggingUpdated(drag) == [])
        #expect(pushes == [true, false, true])

        // The drop itself is the last thing that can leave a cursor pushed.
        backing.draggingEnded(drag)
        #expect(pushes == [true, false, true, false])
    }

    // MARK: - File promises

    /// A promise source that writes its files where it is asked to, or fails.
    @MainActor
    private final class StubPromiseReceiver: DisplayDropPromiseReceiving {
        struct Failure: Error {}

        let fileNames: [String]
        private let fails: Bool

        init(fileNames: [String], fails: Bool = false) {
            self.fileNames = fileNames
            self.fails = fails
        }

        func receivePromisedFiles(
            atDestination destination: URL, options: [AnyHashable: Any],
            operationQueue: OperationQueue, reader: @escaping (URL, (any Error)?) -> Void
        ) {
            let failure: Failure? = fails ? Failure() : nil
            for name in fileNames {
                let url = destination.appendingPathComponent(name)
                if failure == nil { try? Data("promised".utf8).write(to: url) }
                // The real receiver answers asynchronously; so does this, so the
                // test exercises the wait rather than a synchronous shortcut.
                MainActorBridge.async { reader(url, failure) }
            }
        }
    }

    private func makePromiseSource(_ receivers: [any DisplayDropPromiseReceiving])
        -> DisplayDropPromiseSource
    {
        DisplayDropPromiseSource(carriesPromises: { _ in true }, receivers: { _ in receivers })
    }

    @Test("a drag carrying only promises is accepted")
    func promiseOnlyDragIsAccepted() {
        let backing = VMDisplayBackingView(frame: .zero)
        backing.dropAvailability = { .available }
        backing.promiseSource = makePromiseSource([StubPromiseReceiver(fileNames: ["a.png"])])

        // The pasteboard holds no file URL at all — a Photos drag's shape.
        #expect(backing.draggingEntered(makeTextDrag("hello")) == .copy)
    }

    @Test("a mixed drag is offered once, with the promised files written")
    func mixedPromiseDragIsOfferedTogether() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMDisplayBackingViewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let concrete = scratch.appendingPathComponent("dropped.txt")
        try Data("a".utf8).write(to: concrete)

        let backing = VMDisplayBackingView(frame: .zero)
        backing.dropAvailability = { .available }
        backing.promiseSource = makePromiseSource([
            StubPromiseReceiver(fileNames: ["a.png"]), StubPromiseReceiver(fileNames: ["b.png"]),
        ])
        let gate = AsyncGate()
        var offered: [[URL]] = []
        backing.onDropFiles = { urls in
            offered.append(urls)
            gate.notify()
            return true
        }

        #expect(backing.performDragOperation(makeFileDrag([concrete])))
        try await gate.wait { !offered.isEmpty }

        // One gesture, one offer — so the drop has one readout to report and
        // cancel through.
        #expect(offered.count == 1)
        let files = try #require(offered.first)
        #expect(files.map(\.lastPathComponent) == ["dropped.txt", "a.png", "b.png"])
        // The promised bytes are on disk where the guest's pull will read them.
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test("a promise its source never writes is reported rather than dropped in silence")
    func failedPromiseReportsTheDrop() async throws {
        let backing = VMDisplayBackingView(frame: .zero)
        backing.dropAvailability = { .available }
        backing.promiseSource = makePromiseSource([
            StubPromiseReceiver(fileNames: ["a.png", "b.png"], fails: true)
        ])
        let gate = AsyncGate()
        var offered = false
        var reported = false
        backing.onDropFiles = { _ in
            offered = true
            return true
        }
        backing.onDropUnreadable = {
            reported = true
            gate.notify()
        }

        // The drag is taken: nothing on this side knows yet that the source
        // cannot deliver.
        #expect(backing.performDragOperation(makeTextDrag("promise")))
        try await gate.wait { reported }

        #expect(!offered)
    }
}
