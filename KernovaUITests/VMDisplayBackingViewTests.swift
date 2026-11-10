import AppKit
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaUI

@Suite("VMDisplayBackingView Tests", .caseScoped)
@MainActor
struct VMDisplayBackingViewTests {
    /// The VM every display in a test moves files through.
    private let host = FakeTransferHost()

    /// A display hosted by ``host``.
    private func makeBacking() -> VMDisplayBackingView {
        let backing = VMDisplayBackingView(frame: .zero)
        let host = self.host
        backing.transferHost = { host }
        return backing
    }

    private func settings(autoResize: Bool, capturesSystemKeys: Bool) -> VMDisplayViewSettings {
        VMDisplayViewSettings(
            automaticallyReconfiguresDisplay: autoResize, capturesSystemKeys: capturesSystemKeys)
    }

    @Test("update carries both settings through to the machine view")
    func updateAppliesSettings() throws {
        let backing = makeBacking()

        backing.update(
            display: nil, isPaused: false, transitionText: nil,
            settings: settings(autoResize: true, capturesSystemKeys: true))
        #expect(backing.machineView.automaticallyReconfiguresDisplay == true)
        #expect(backing.machineView.capturesSystemKeys == true)

        backing.update(
            display: nil, isPaused: false, transitionText: nil,
            settings: settings(autoResize: false, capturesSystemKeys: false))
        #expect(backing.machineView.automaticallyReconfiguresDisplay == false)
        #expect(backing.machineView.capturesSystemKeys == false)
    }

    // MARK: - File drop

    /// A dragging info carrying whatever `pasteboard` holds, from `source`, at
    /// `draggingLocation`.
    private final class StubDraggingInfo: NSObject, NSDraggingInfo {
        let draggingPasteboard: NSPasteboard
        let draggingSource: Any?
        var draggingLocation: NSPoint = .zero
        @MainActor init(pasteboard: NSPasteboard, source: Any? = nil) {
            self.draggingPasteboard = pasteboard
            self.draggingSource = source
        }

        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggedImageLocation: NSPoint { .zero }
        var draggedImage: NSImage? { nil }
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

    private func makeTextDrag(_ text: String, source: Any? = nil) -> StubDraggingInfo {
        let pasteboard = NSPasteboard(name: .init("VMDisplayBackingViewTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return StubDraggingInfo(pasteboard: pasteboard, source: source)
    }

    @Test("the display follows its host's availability by itself")
    func registrationFollowsTheHost() async throws {
        let backing = makeBacking()
        #expect(backing.registeredDraggedTypes.isEmpty)

        host.displayDropAvailability = .disconnected
        // The observation's pass is queued on main by the change itself.
        await drainMainQueue()
        #expect(backing.registeredDraggedTypes.contains(.fileURL))

        host.displayDropAvailability = .none
        await drainMainQueue()
        #expect(backing.registeredDraggedTypes.isEmpty)
    }

    // MARK: - Files dragged out of a VM

    @Test("files dragged out of this same VM go back into the guest, the promises unread")
    func carriesItsOwnDragOutIntoTheGuest() throws {
        let backing = makeBacking()
        // The drop goes to the guest over its display, not the drop channel.
        host.displayDropAvailability = .disconnected
        var pushes: [Bool] = []
        backing.applyRejectCursor = { pushes.append($0) }
        var promisesRead = false
        backing.promiseSource = DisplayDropPromiseSource(
            carriesPromises: { _ in
                promisesRead = true
                return true
            },
            receivers: { _ in
                promisesRead = true
                return []
            })
        let take = FakeTake(items: [])
        take.carriesOverDisplay = true
        let drag = makeTextDrag("promise", source: DisplayDragOutSource(vmID: host.id, take: take))
        drag.draggingLocation = NSPoint(x: 30, y: 40)
        let point = backing.machineView.convert(drag.draggingLocation, from: nil)

        #expect(backing.draggingEntered(drag) == .copy)
        #expect(backing.draggingUpdated(drag) == .copy)
        backing.draggingExited(drag)
        #expect(backing.draggingEntered(drag) == .copy)
        #expect(backing.performDragOperation(drag))

        #expect(
            take.events == [
                .hostSessionOver(point), .hostSessionOver(point), .hostSessionLeft,
                .hostSessionOver(point), .hostSessionDropped(point),
            ])
        #expect(pushes.allSatisfy { !$0 })
        #expect(!promisesRead)
        // The guest's own drag lands its promises itself: nothing names them.
        #expect(!take.events.contains(.namedItemsForInAppDestination))
    }

    @Test("files dragged out of another VM take the promise path")
    func acceptsAnotherVMsDragOut() throws {
        let backing = makeBacking()
        host.displayDropAvailability = .available
        backing.promiseSource = makePromiseSource([StubPromiseReceiver(fileNames: ["a.txt"])])
        let source = DisplayDragOutSource(vmID: UUID(), take: FakeTake(items: []))

        #expect(backing.draggingEntered(makeTextDrag("promise", source: source)) == .copy)
    }

    @Test("another VM's drag out whose promised items could not be named is refused, nothing called in")
    func unnamedDragOutIsRefused() throws {
        let backing = makeBacking()
        host.displayDropAvailability = .available
        let receiver = StubPromiseReceiver(fileNames: ["File.jpeg"])
        backing.promiseSource = makePromiseSource([receiver])
        let take = FakeTake(items: [])
        take.onNameItems = { false }
        var offered = false
        host.onDrop = { _, _ in
            offered = true
            return true
        }
        let drag = makeTextDrag("promise", source: DisplayDragOutSource(vmID: UUID(), take: take))

        #expect(!backing.performDragOperation(drag))

        #expect(!offered)
        #expect(receiver.destination == nil)
        #expect(take.events == [.namedItemsForInAppDestination])
    }

    @Test("a drag carrying no file URL is refused even when the agent is reachable")
    func refusesNonFileDrags() throws {
        let backing = makeBacking()
        host.displayDropAvailability = .available
        backing.applyDropRegistration()

        #expect(backing.draggingEntered(makeTextDrag("hello")) == [])
    }

    @Test("a file promise's types are registered alongside concrete file URLs")
    func registersPromiseTypes() throws {
        let backing = makeBacking()
        host.displayDropAvailability = .available

        backing.applyDropRegistration()

        for promised in NSFilePromiseReceiver.readableDraggedTypes {
            #expect(backing.registeredDraggedTypes.contains(.init(promised)))
        }
    }

    // MARK: - The reject cursor

    @Test("a refused drag shows the not-allowed cursor, and leaving clears it")
    func refusedDragShowsTheRejectCursor() throws {
        let backing = makeBacking()
        host.displayDropAvailability = .disconnected
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

    @Test("availability changing mid-drag flips the cursor on the next update")
    func cursorFollowsAvailabilityMidDrag() throws {
        let backing = makeBacking()
        host.displayDropAvailability = .disconnected
        var pushes: [Bool] = []
        backing.applyRejectCursor = { pushes.append($0) }
        let drag = makeFileDrag([URL(fileURLWithPath: "/tmp/a.txt")])

        // A drag that began while the VM was paused, over a VM that then resumes.
        #expect(backing.draggingEntered(drag) == [])
        host.displayDropAvailability = .available
        #expect(backing.draggingUpdated(drag) == .copy)
        #expect(pushes == [true, false])

        // …and back, when the agent goes away under the same drag.
        host.displayDropAvailability = .disconnected
        #expect(backing.draggingUpdated(drag) == [])
        #expect(pushes == [true, false, true])

        // The drop itself is the last thing that can leave a cursor pushed.
        backing.draggingEnded(drag)
        #expect(pushes == [true, false, true, false])
    }

    // MARK: - File promises

    /// A promise source that records where it is called in to, and writes nothing.
    @MainActor
    private final class StubPromiseReceiver: FilePromiseReceiving {
        let fileNames: [String]
        let fileTypes: [String] = []
        /// Where it was called in to, once it was.
        private(set) var destination: URL?

        init(fileNames: [String]) {
            self.fileNames = fileNames
        }

        func receivePromisedFiles(
            atDestination destination: URL, options: [AnyHashable: Any],
            operationQueue: OperationQueue, reader: @escaping (URL, (any Error)?) -> Void
        ) {
            self.destination = destination
        }
    }

    private func makePromiseSource(_ receivers: [any FilePromiseReceiving])
        -> DisplayDropPromiseSource
    {
        DisplayDropPromiseSource(carriesPromises: { _ in true }, receivers: { _ in receivers })
    }

    @Test("a promise drag hands the host its receivers in drag order, none called in")
    func promiseDragHandsOverItsReceivers() throws {
        let backing = makeBacking()
        host.displayDropAvailability = .available
        let receivers = [StubPromiseReceiver(fileNames: ["a.png"]), StubPromiseReceiver(fileNames: ["b.png"])]
        backing.promiseSource = makePromiseSource(receivers)
        var handed: [any FilePromiseReceiving] = []
        host.onDrop = { _, promises in
            handed = promises
            return true
        }

        #expect(backing.performDragOperation(makeTextDrag("promise")))

        #expect(handed.map { ObjectIdentifier($0) } == receivers.map { ObjectIdentifier($0) })
        #expect(receivers.allSatisfy { $0.destination == nil })
    }
}
