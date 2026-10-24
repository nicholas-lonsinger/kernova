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

    @Test(
        "a drag on the display's edge, the full-screen top row included, is inside",
        arguments: [(x: 200.0, y: 50.0), (x: 0, y: 50), (x: 100, y: 100), (x: 100, y: 0)])
    func edgesAreInside(_ point: (x: Double, y: Double)) throws {
        let view = makeView()
        host.nextTake = makeTake()

        view.mouseDown(with: try event(.leftMouseDown, x: 50))
        view.mouseDragged(with: try event(.leftMouseDragged, x: point.x, y: point.y))

        #expect(host.takeRequests == 0)
        #expect(view.forwarded.map(\.type) == [.leftMouseDown, .leftMouseDragged])
    }

    @Test("a drag one point past the top edge is outside")
    func pastTheTopEdgeIsOutside() throws {
        let view = makeView()
        host.nextTake = makeTake()

        view.mouseDown(with: try event(.leftMouseDown, x: 50))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 100, y: 101))

        #expect(host.takeRequests == 1)
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
        // Released where the last event sent left the guest pointer.
        #expect(view.forwarded.last == .init(type: .leftMouseUp, location: NSPoint(x: 50, y: 50)))
    }

    @Test("the Mac session begins from the physical drag being withheld, carrying every item")
    func sessionBeginsFromTheWithheldDrag() throws {
        let view = makeView()
        let take = makeTake()
        take.onWithheldDrag = { #expect(view.beginHostSession(carrying: take)) }
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
        // A later drag or mouse-up of the same press reaches neither the guest
        // nor the take: the session owns it, and the guest's button stays held.
        view.mouseDragged(with: try event(.leftMouseDragged, x: 280))
        view.mouseUp(with: try event(.leftMouseUp, x: 280))
        #expect(take.events == [.withheldDrag])
        #expect(view.forwarded.map(\.type) == [.leftMouseDown])
    }

    @Test("a new press over a take a session carries ends that take first")
    func newPressEndsACarriedTake() throws {
        let view = makeView()
        let take = makeTake()
        take.onWithheldDrag = { #expect(view.beginHostSession(carrying: take)) }
        host.nextTake = take
        view.mouseDown(with: try event(.leftMouseDown, x: 50))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 250))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 260))

        view.mouseDown(with: try event(.leftMouseDown, x: 60))

        #expect(take.events == [.withheldDrag, .displayAbandoned])
        #expect(view.forwarded.map(\.type) == [.leftMouseDown, .leftMouseDown])
    }

    @Test("session positions move the guest pointer, and the release goes where the last one put it")
    func sessionPositionsLeadTheRelease() throws {
        let view = makeView()
        let take = makeTake()
        host.nextTake = take
        view.mouseDown(with: try event(.leftMouseDown, x: 50))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 250))
        view.injectNudge(.center)
        let before = view.forwarded.count

        view.injectDrag(at: NSPoint(x: 30, y: 40))
        view.injectRelease()

        #expect(
            Array(view.forwarded.dropFirst(before)) == [
                .init(type: .leftMouseDragged, location: NSPoint(x: 30, y: 40)),
                .init(type: .leftMouseUp, location: NSPoint(x: 30, y: 40)),
            ])
    }

    // MARK: - The exit point

    @Test("returning to the exit point drags the guest pointer back to the last forwarded event")
    func returnToTheLastForwardedEvent() throws {
        let view = makeView()
        let take = makeTake()
        host.nextTake = take
        view.mouseDown(with: try event(.leftMouseDown, x: 50))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 190, y: 70))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 250))
        view.injectNudge(.center)
        let before = view.forwarded.count

        view.returnToExitPoint()
        view.injectRelease()

        #expect(
            Array(view.forwarded.dropFirst(before)) == [
                .init(type: .leftMouseDragged, location: NSPoint(x: 190, y: 70)),
                .init(type: .leftMouseUp, location: NSPoint(x: 190, y: 70)),
            ])
    }

    @Test("the exit point follows the session's last position over the display")
    func exitPointFollowsTheSession() throws {
        let view = makeView()
        host.nextTake = makeTake()
        view.mouseDown(with: try event(.leftMouseDown, x: 50))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 250))
        view.injectDrag(at: NSPoint(x: 5, y: 6))
        view.injectNudge(.center)
        let before = view.forwarded.count

        view.returnToExitPoint()

        #expect(
            Array(view.forwarded.dropFirst(before)) == [
                .init(type: .leftMouseDragged, location: NSPoint(x: 5, y: 6))
            ])
    }

    @Test("a guest pointer already at the exit point is not moved again")
    func returnWithoutMotionInjectsNothing() throws {
        let view = makeView()
        host.nextTake = makeTake()
        view.mouseDown(with: try event(.leftMouseDown, x: 50))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 250))
        let before = view.forwarded.count

        view.returnToExitPoint()

        #expect(view.forwarded.count == before)
    }

    // MARK: - The park

    /// Presses on the display and drags to `exit` — forwarded there, past the
    /// edge included while no drag is on offer — then takes the drag over.
    private func pressLeaving(at exit: NSPoint, view: RecordingMachineView) throws {
        view.mouseDown(with: try event(.leftMouseDown, x: 50))
        view.mouseDragged(with: try event(.leftMouseDragged, x: exit.x, y: exit.y))
        host.nextTake = makeTake()
        view.mouseDragged(with: try event(.leftMouseDragged, x: 300))
    }

    @Test(
        "a park drags the guest pointer to the exit point held 8 points in from every edge",
        arguments: [
            (exit: NSPoint(x: 150, y: 60), parked: NSPoint(x: 150, y: 60)),
            (exit: NSPoint(x: 3, y: 50), parked: NSPoint(x: 8, y: 50)),
            (exit: NSPoint(x: 250, y: 50), parked: NSPoint(x: 192, y: 50)),
            (exit: NSPoint(x: 100, y: 104), parked: NSPoint(x: 100, y: 92)),
            (exit: NSPoint(x: -20, y: -5), parked: NSPoint(x: 8, y: 8)),
        ])
    func parkHoldsTheExitPointInside(_ spot: (exit: NSPoint, parked: NSPoint)) throws {
        let view = makeView()
        try pressLeaving(at: spot.exit, view: view)
        view.injectNudge(.center)
        let before = view.forwarded.count

        view.parkNearExitPoint()

        #expect(
            Array(view.forwarded.dropFirst(before)) == [
                .init(type: .leftMouseDragged, location: spot.parked)
            ])
    }

    @Test("a release onto the catcher after a park returns to the center first")
    func catcherReleaseAfterAParkLandsAtTheCenter() throws {
        let view = makeView()
        try pressLeaving(at: NSPoint(x: 250, y: 50), view: view)
        view.injectNudge(.offset)
        view.parkNearExitPoint()
        let before = view.forwarded.count

        view.returnToCatcherTarget()
        view.injectRelease()

        #expect(
            Array(view.forwarded.dropFirst(before)) == [
                .init(type: .leftMouseDragged, location: NSPoint(x: 100, y: 50)),
                .init(type: .leftMouseUp, location: NSPoint(x: 100, y: 50)),
            ])
    }

    @Test("a park leaves the exit point exact: the return before a release goes back to it unclamped")
    func parkLeavesTheExitPointExact() throws {
        let view = makeView()
        try pressLeaving(at: NSPoint(x: 250, y: 50), view: view)
        view.parkNearExitPoint()
        let before = view.forwarded.count

        view.returnToExitPoint()
        view.injectRelease()

        #expect(
            Array(view.forwarded.dropFirst(before)) == [
                .init(type: .leftMouseDragged, location: NSPoint(x: 250, y: 50)),
                .init(type: .leftMouseUp, location: NSPoint(x: 250, y: 50)),
            ])
    }

    @Test("a park goes near the session's last position over the display")
    func parkFollowsTheSession() throws {
        let view = makeView()
        try pressLeaving(at: NSPoint(x: 150, y: 60), view: view)
        view.injectDrag(at: NSPoint(x: 197, y: 40))
        let before = view.forwarded.count

        view.parkNearExitPoint()

        #expect(
            Array(view.forwarded.dropFirst(before)) == [
                .init(type: .leftMouseDragged, location: NSPoint(x: 192, y: 40))
            ])
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

    @Test("a promise's name and queue are answered off the main actor, where file coordination asks")
    func answersOffTheMainActor() async {
        let (source, _) = makeSource()

        let answers = await Task.detached {
            let provider = NSFilePromiseProvider(fileType: "public.plain-text", delegate: source)
            provider.userInfo = DisplayDragOutSource.PromisedItem(
                index: 0, filename: "report.txt", source: source)
            return (
                source.filePromiseProvider(provider, fileNameForType: provider.fileType),
                source.operationQueue(for: provider).maxConcurrentOperationCount
            )
        }.value

        #expect(answers.0 == "report.txt")
        #expect(answers.1 == 1)
    }

    /// A session holding its items' images, which hands out a fresh item for
    /// each one on every pass, as `NSDraggingSession` does, and keeps what the
    /// pass left on it.
    ///
    /// A fresh item each pass because an `NSDraggingItem` keeps the components
    /// it first produced: neither a new provider nor `setDraggingFrame` after
    /// a read changes what `imageComponents` returns.
    @MainActor
    final class FakeImageSession: DraggingItemImageSetting {
        private var frames: [NSRect]
        private var providers: [(() -> [NSDraggingImageComponent])?]

        init(items: [NSDraggingItem]) {
            frames = items.map(\.draggingFrame)
            providers = items.map(\.imageComponentsProvider)
        }

        func forEachDraggingItem(_ body: (NSDraggingItem, Int) -> Void) {
            for index in providers.indices {
                let item = NSDraggingItem(pasteboardWriter: "item" as NSString)
                item.draggingFrame = frames[index]
                item.imageComponentsProvider = providers[index]
                body(item, index)
                frames[index] = item.draggingFrame
                providers[index] = item.imageComponentsProvider
            }
        }

        /// What each item draws now: its components' contents, by identity.
        var drawn: [[ObjectIdentifier]] {
            providers.map { provider in
                (provider?() ?? []).compactMap { $0.contents.map { ObjectIdentifier($0 as AnyObject) } }
            }
        }
    }

    @Test("the session's images hide while it is over its display and come back each time it leaves")
    func imagesFollowTheDisplay() throws {
        let (source, take) = makeSource()
        let session = FakeImageSession(items: source.draggingItems(centeredAt: .zero))
        let original = session.drawn
        #expect(original.count == 2)
        #expect(original.allSatisfy { !$0.isEmpty })

        source.followImages(of: session)
        #expect(session.drawn == original)

        for _ in 0..<2 {
            take.sessionOverDisplay = true
            #expect(session.drawn.allSatisfy { $0.isEmpty })

            take.sessionOverDisplay = false
            #expect(session.drawn == original)
        }
    }

    @Test(
        "following the images applies the take's state at once, over its display or off it",
        arguments: [true, false])
    func followingAppliesTheStateAtOnce(over: Bool) throws {
        let (source, take) = makeSource()
        let session = FakeImageSession(items: source.draggingItems(centeredAt: .zero))
        let original = session.drawn
        take.sessionOverDisplay = over

        source.followImages(of: session)

        #expect(session.drawn == (over ? original.map { _ in [] } : original))
    }

    @Test("the session ending stops its images following the take before the take hears the end")
    func endingClearsTheHookFirst() throws {
        let (source, take) = makeSource()
        let session = FakeImageSession(items: source.draggingItems(centeredAt: .zero))
        source.followImages(of: session)
        take.sessionOverDisplay = true
        take.onHostSessionEnded = { take.sessionOverDisplay = false }

        source.sessionEnded(dropped: false)

        #expect(take.events.last == .hostSessionEnded(dropped: false))
        #expect(take.sessionOverDisplayChanged == nil)
        #expect(session.drawn.allSatisfy { $0.isEmpty })
        take.sessionOverDisplay = true
        take.sessionOverDisplay = false
        #expect(session.drawn.allSatisfy { $0.isEmpty })
    }

    @Test("writes run one at a time, off the main queue")
    func writesRunSerially() throws {
        let (source, _) = makeSource()
        let queue = source.operationQueue(for: try #require(try providers(of: source).first))

        #expect(queue.maxConcurrentOperationCount == 1)
        #expect(queue !== OperationQueue.main)
    }
}
