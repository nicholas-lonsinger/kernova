import AppKit
import Foundation
import KernovaKit
import KernovaTestSupport
import Synchronization
import Testing

@testable import KernovaCore
@testable import KernovaUI

/// The VM screen's half of taking a guest drag over: which physical events
/// reach the guest, which are withheld for the take, and what it injects.
@Suite("VMDisplayMachineView", .caseScoped)
@MainActor
struct VMDisplayMachineViewTests {
    /// A machine view that records what it would hand the guest, and the Mac
    /// drag sessions it would begin, instead of doing either.
    @MainActor
    final class RecordingMachineView: VMDisplayMachineView {
        struct Forwarded: Equatable {
            let type: NSEvent.EventType
            let location: NSPoint
        }

        private(set) var forwarded: [Forwarded] = []
        private(set) var sessions: [(items: [NSDraggingItem], event: NSEvent)] = []

        override func forward(_ event: NSEvent) {
            forwarded.append(
                Forwarded(type: event.type, location: convert(event.locationInWindow, from: nil)))
        }

        override func startDraggingSession(
            with items: [NSDraggingItem], event: NSEvent, source: any NSDraggingSource
        ) -> Bool {
            sessions.append((items, event))
            return true
        }
    }

    private let host = FakeTransferHost()

    /// A 200×100 display hosted by ``host``, its center at (100, 50).
    private func makeView() -> RecordingMachineView {
        let view = RecordingMachineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let host = self.host
        view.transferHost = { host }
        return view
    }

    private func event(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat = 50) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func makeTake() -> FakeTake {
        FakeTake(items: [.declared("a.txt"), .declared("Photos", uti: "public.folder", isDirectory: true, at: 1)])
    }

    // MARK: - Asking to take over

    @Test("an outside drag with no guest drag on offer is forwarded, and asks again each time")
    func outsideDragWithoutAnOfferIsForwarded() throws {
        let view = makeView()

        view.mouseDown(with: try event(.leftMouseDown, x: 50))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 250))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 260))
        view.mouseUp(with: try event(.leftMouseUp, x: 260))

        #expect(host.pressCount == 1)
        // Every outside event asks, so an offer that lands after the pointer
        // left still takes over.
        #expect(host.takeRequests == 2)
        #expect(
            view.forwarded.map(\.type) == [
                .leftMouseDown, .leftMouseDragged, .leftMouseDragged, .leftMouseUp,
            ])
    }

    @Test("a drag inside the display never asks to take over")
    func insideDragNeverAsks() throws {
        let view = makeView()
        host.nextTake = makeTake()

        view.mouseDown(with: try event(.leftMouseDown, x: 50))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 150))

        #expect(host.takeRequests == 0)
        #expect(view.forwarded.map(\.type) == [.leftMouseDown, .leftMouseDragged])
    }

    @Test("an outside drag with an offer is withheld, and so is the rest of the press")
    func takeOverWithholdsThePress() throws {
        let view = makeView()
        let take = makeTake()
        host.nextTake = take

        view.mouseDown(with: try event(.leftMouseDown, x: 50))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 150))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 250))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 260))
        view.mouseUp(with: try event(.leftMouseUp, x: 260))

        // The guest saw the press up to the edge, and nothing after it.
        #expect(view.forwarded.map(\.type) == [.leftMouseDown, .leftMouseDragged])
        #expect(take.events == [.withheldDrag, .withheldMouseUp])
        #expect(host.takeRequests == 1)
    }

    // MARK: - What the take injects

    @Test("nudges go to the center and one point right of it, and the release to the last nudge")
    func injectedEventsLandAtTheCenter() throws {
        let view = makeView()
        let take = makeTake()
        host.nextTake = take
        view.mouseDown(with: try event(.leftMouseDown, x: 50))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 250))
        let before = view.forwarded.count

        view.injectNudge(.center)
        view.injectNudge(.offset)
        view.injectRelease()

        #expect(
            Array(view.forwarded.dropFirst(before)) == [
                .init(type: .leftMouseDragged, location: NSPoint(x: 100, y: 50)),
                .init(type: .leftMouseDragged, location: NSPoint(x: 101, y: 50)),
                .init(type: .leftMouseUp, location: NSPoint(x: 101, y: 50)),
            ])
    }

    @Test("after the release, the physical mouse-up is not a second release")
    func physicalMouseUpAfterTheReleaseIsSwallowed() throws {
        let view = makeView()
        let take = makeTake()
        take.onWithheldMouseUp = { view.injectRelease() }
        host.nextTake = take
        view.mouseDown(with: try event(.leftMouseDown, x: 50))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 250))

        view.mouseUp(with: try event(.leftMouseUp, x: 250))

        #expect(view.forwarded.filter { $0.type == .leftMouseUp }.count == 1)
        #expect(view.forwarded.last == .init(type: .leftMouseUp, location: NSPoint(x: 100, y: 50)))
    }

    @Test("the Mac session begins from the physical drag being withheld, carrying every item")
    func sessionBeginsFromTheWithheldDrag() throws {
        let view = makeView()
        let take = makeTake()
        take.onWithheldDrag = {
            #expect(view.beginHostSession(carrying: take))
            view.injectRelease()
        }
        host.nextTake = take
        view.mouseDown(with: try event(.leftMouseDown, x: 50))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 250))
        let physical = try event(.leftMouseDragged, x: 270, y: 60)

        view.mouseDragged(with: physical)

        let session = try #require(view.sessions.first)
        #expect(session.event === physical)
        #expect(session.items.count == 2)
        // Framed around the pointer, outside the view's own bounds.
        #expect(session.items.allSatisfy { $0.draggingFrame.midX == 270 && $0.draggingFrame.midY == 60 })
        // A later drag of the same press reaches neither the guest nor the take.
        view.mouseDragged(with: try event(.leftMouseDragged, x: 280))
        #expect(take.events == [.withheldDrag])
        #expect(view.forwarded.last?.type == .leftMouseUp)
    }

    @Test("no session begins outside a withheld drag")
    func noSessionWithoutAWithheldDrag() throws {
        let view = makeView()
        let take = makeTake()
        host.nextTake = take
        view.mouseDown(with: try event(.leftMouseDown, x: 50))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 250))

        #expect(!view.beginHostSession(carrying: take))
        #expect(view.sessions.isEmpty)
    }

    // MARK: - A take that fails

    @Test("a take that fails on the mouse-up hands that mouse-up back to the guest")
    func failedTakeForwardsTheMouseUp() throws {
        let view = makeView()
        let take = makeTake()
        take.onWithheldMouseUp = { view.resumeForwarding() }
        host.nextTake = take
        view.mouseDown(with: try event(.leftMouseDown, x: 50))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 250))

        view.mouseUp(with: try event(.leftMouseUp, x: 250))

        #expect(view.forwarded.map(\.type) == [.leftMouseDown, .leftMouseUp])
    }

    @Test("a take that fails mid-press hands the rest of the press back")
    func failedTakeResumesForwarding() throws {
        let view = makeView()
        let take = makeTake()
        host.nextTake = take
        view.mouseDown(with: try event(.leftMouseDown, x: 50))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 250))

        view.resumeForwarding()
        view.mouseDragged(with: try event(.leftMouseDragged, x: 260))
        view.mouseUp(with: try event(.leftMouseUp, x: 260))

        #expect(
            view.forwarded.map(\.type) == [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
        #expect(take.events.isEmpty)
    }

    @Test("a withheld drag that comes back inside the display tells the take, and reaches the guest")
    func pointerReturnReachesTheGuest() throws {
        let view = makeView()
        let take = makeTake()
        take.onPointerReturned = { view.resumeForwarding() }
        host.nextTake = take
        view.mouseDown(with: try event(.leftMouseDown, x: 50))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 250))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 260))

        view.mouseDragged(with: try event(.leftMouseDragged, x: 150))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 140))
        view.mouseUp(with: try event(.leftMouseUp, x: 140))

        #expect(take.events == [.withheldDrag, .pointerReturned])
        #expect(
            view.forwarded == [
                .init(type: .leftMouseDown, location: NSPoint(x: 50, y: 50)),
                .init(type: .leftMouseDragged, location: NSPoint(x: 150, y: 50)),
                .init(type: .leftMouseDragged, location: NSPoint(x: 140, y: 50)),
                .init(type: .leftMouseUp, location: NSPoint(x: 140, y: 50)),
            ])
    }

    @Test("a new press over an unsettled take abandons it")
    func newPressAbandonsTheTake() throws {
        let view = makeView()
        let take = makeTake()
        host.nextTake = take
        view.mouseDown(with: try event(.leftMouseDown, x: 50))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 250))

        view.mouseDown(with: try event(.leftMouseDown, x: 50))

        #expect(take.events == [.displayAbandoned])
        #expect(host.pressCount == 2)
    }
}

/// The Mac drag session's side of a taken-over guest drag.
@Suite("DisplayDragOutSource", .caseScoped)
@MainActor
struct DisplayDragOutSourceTests {
    private func makeSource() -> (DisplayDragOutSource, FakeTake) {
        let take = FakeTake(items: [
            .declared("report.txt", uti: "public.plain-text"),
            .declared("Photos", uti: "public.folder", isDirectory: true, at: 1),
        ])
        return (DisplayDragOutSource(vmID: UUID(), take: take), take)
    }

    private func providers(of source: DisplayDragOutSource) throws -> [NSFilePromiseProvider] {
        try source.draggingItems(centeredAt: .zero).map {
            try #require($0.item as? NSFilePromiseProvider)
        }
    }

    @Test("each item is a file promise of its own type, named as the guest named it")
    func promisesCarryTypeAndName() throws {
        let (source, _) = makeSource()

        let providers = try providers(of: source)

        #expect(providers.map(\.fileType) == ["public.plain-text", "public.folder"])
        #expect(
            providers.map { source.filePromiseProvider($0, fileNameForType: $0.fileType) } == [
                "report.txt", "Photos",
            ])
    }

    @Test("writing a promise writes that item to the URL asked for")
    func writeReachesTheTake() throws {
        let (source, take) = makeSource()
        let provider = try #require(try providers(of: source).last)
        let destination = URL(fileURLWithPath: "/tmp/Photos")
        let completed = Mutex<[String]>([])

        source.filePromiseProvider(provider, writePromiseTo: destination) { error in
            completed.withLock { $0.append(error.map { "\($0)" } ?? "ok") }
        }

        #expect(completed.withLock { $0 } == ["ok"])
        #expect(take.writes.withLock { $0.map(\.index) } == [1])
        #expect(take.writes.withLock { $0.map(\.destination) } == [destination])
    }

    @Test("a write that fails hands its error to the destination")
    func writeFailurePassesThrough() throws {
        let (source, take) = makeSource()
        take.writeError.withLock { $0 = CocoaError(.userCancelled) }
        let provider = try #require(try providers(of: source).first)
        let code = Mutex<CocoaError.Code?>(nil)

        source.filePromiseProvider(provider, writePromiseTo: URL(fileURLWithPath: "/tmp/x")) {
            error in code.withLock { $0 = (error as? CocoaError)?.code }
        }

        #expect(code.withLock { $0 } == .userCancelled)
    }

    @Test("writes run one at a time, off the main queue")
    func writesRunSerially() throws {
        let (source, _) = makeSource()
        let queue = source.operationQueue(for: try #require(try providers(of: source).first))

        #expect(queue.maxConcurrentOperationCount == 1)
        #expect(queue !== OperationQueue.main)
    }
}
