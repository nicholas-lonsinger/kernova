import Foundation
import KernovaAgentCore
import KernovaKit
import KernovaSynchronization
import KernovaTestSupport
import KernovaWire
import Observation
import Testing
import UniformTypeIdentifiers

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// A take of a guest's drag over: the press it withholds until the guest's
/// catcher is the drag's target, the guest's button held while a Mac session
/// carries the drag, a drag that comes back over the display dropping inside
/// the guest, the delivery a Mac destination's drop asks for, and the offers'
/// release once nothing will pull again.
@Suite("GuestDragTake", .caseScoped)
@MainActor
struct GuestDragTakeTests {
    // MARK: - Doubles

    /// What a take asked the display to do.
    enum DisplayCall: Equatable {
        case nudge(GuestDragNudge)
        case drag(CGPoint)
        case returnToExit
        case beginSession
        case release
        case resumeTracking
    }

    /// A display that records what the take asks of it; each release also
    /// fires `released`, from whichever thread injects it.
    @MainActor
    final class RecordingDisplay: GuestDragDisplay {
        private(set) var calls: [DisplayCall] = []
        var sessionBegins = true
        nonisolated let released = DispatchSemaphore(value: 0)

        func injectNudge(_ nudge: GuestDragNudge) { calls.append(.nudge(nudge)) }
        func injectDrag(at point: CGPoint) { calls.append(.drag(point)) }
        func returnToExitPoint() { calls.append(.returnToExit) }
        func resumeTracking() { calls.append(.resumeTracking) }

        func injectRelease() {
            calls.append(.release)
            released.signal()
        }

        func beginHostSession(carrying take: any GuestDragTaking) -> Bool {
            calls.append(.beginSession)
            return sessionBegins
        }
    }

    /// The guest's side as the take reaches it: each call recorded, each step
    /// and end the test's to deliver. Every `deliver` also fires `delivering`,
    /// so a thread off the main actor can wait for it.
    @MainActor
    final class FakeTransport: GuestDragTransport {
        struct Pull {
            let index: Int
            let destination: URL
            let ended: @MainActor (Result<Void, WireError>) -> Void
            var cancelled = false
        }

        private(set) var events: (@MainActor (GuestDragTakeEvent) -> Void)?
        private(set) var delivery: GuestDragDelivery?
        private(set) var controls: [DragTakeControl] = []
        private(set) var cancels = 0
        private(set) var pulls: [Pull] = []
        /// How many times the take released its offer.
        private(set) var releases = 0
        /// What the guest's first `TARGETED` lists.
        var listed: [OfferedItem] = []
        nonisolated let delivering = DispatchSemaphore(value: 0)
        let changed = AsyncGate()

        func take(delivery: GuestDragDelivery, _ events: @escaping @MainActor (GuestDragTakeEvent) -> Void) {
            self.delivery = delivery
            self.events = events
        }

        func control(_ control: DragTakeControl) {
            controls.append(control)
            if control == .deliver { delivering.signal() }
        }

        func cancel() {
            cancels += 1
        }

        func pull(
            _ item: DraggedOutItem, at index: Int, to destination: URL,
            ended: @escaping @MainActor (Result<Void, WireError>) -> Void
        ) -> @MainActor () -> Void {
            let position = pulls.count
            pulls.append(Pull(index: index, destination: destination, ended: ended))
            changed.notify()
            return { [weak self] in self?.pulls[position].cancelled = true }
        }

        func release() {
            releases += 1
        }

        /// The guest's catcher is the drag's target, listing ``listed``.
        func target() {
            report(.targeted(listed))
        }

        /// The guest's delivering drop named the promises: `items`, as the
        /// real transport hands them on.
        func name(_ items: [DraggedOutItem]) {
            delivery?.named(items)
        }

        /// The guest reports `report`, as the real transport hands it on.
        func report(_ report: DragTakeReport) {
            if report == .delivering || report == .deliverRefused { delivery?.peerAnswered() }
            events?(.report(report))
        }

        /// The take ends as `result`, its delivery settled first as the real
        /// transport settles it: `delivered` is the items a delivery named and
        /// sized.
        func end(_ result: DragTakeResult, delivered: [DraggedOutItem]? = nil) {
            if case .caught? = Optional(result), let delivered {
                delivery?.settle(.delivered(delivered))
            } else {
                delivery?.settle(.undelivered)
            }
            events?(.ended(result))
        }

        /// Ends pull `position` with `result`.
        func end(_ position: Int, _ result: Result<Void, WireError>) {
            pulls[position].ended(result)
        }
    }

    /// The condition a take holds under, standing in for the VM's status.
    @MainActor
    @Observable
    final class RunningFlag {
        var isRunning = true
    }

    /// How many times the take reported itself finished.
    @MainActor
    final class FinishedFlag {
        var count = 0
    }

    private let display = RecordingDisplay()
    private let transport = FakeTransport()
    private let running = RunningFlag()
    private let finished = FinishedFlag()

    private static let delivery = DragDelivery(names: [:], folderSizes: [:])

    private static let file = DraggedOutItem(
        name: Data("a.txt".utf8), type: .plainText, isDirectory: false, sizeEstimate: 4)
    private static let folder = DraggedOutItem(name: Data("Folder".utf8), type: .folder, isDirectory: true)
    private static let promise = DraggedOutItem(
        name: Data("Untitled.jpeg".utf8), type: .jpeg, isDirectory: false, isPromised: true)
    private static let namedPromise = DraggedOutItem(
        name: Data("IMG_0042.jpeg".utf8), type: .jpeg, isDirectory: false, isPromised: true, sizeEstimate: 9)
    private static let sizedFolder = DraggedOutItem(
        name: Data("Folder".utf8), type: .folder, isDirectory: true, sizeEstimate: 4096)

    /// What a take carrying `items` lists them as.
    static func offered(_ items: [DraggedOutItem]) -> [OfferedItem] {
        items.map { item in
            var representation = Representation()
            representation.type = TypeDescriptor(appleUTI: item.type.identifier)
            representation.storage = item.isDirectory ? .folder : .file
            representation.name = item.name
            representation.promised = item.isPromised
            representation.sizeEstimate = item.sizeEstimate
            var offered = OfferedItem()
            offered.representations = [representation]
            return offered
        }
    }

    private func makeTake(items: [DraggedOutItem] = [Self.file]) -> GuestDragTake {
        let running = running
        let finished = finished
        transport.listed = Self.offered(items)
        let take = GuestDragTake(
            transport: transport, display: display,
            reporter: ClipboardTransferReporter(), peerName: "Test VM", holds: { running.isRunning },
            onFinished: { _ in finished.count += 1 })
        take.begin()
        return take
    }

    /// A take whose guest catcher is the drag's target.
    private func readyTake(items: [DraggedOutItem] = [Self.file]) throws -> GuestDragTake {
        let take = makeTake(items: items)
        transport.report(.armed)
        transport.target()
        try #require(take.phase == .ready)
        return take
    }

    /// A take a Mac session carries off the display, the catcher its target.
    private func carriedTake(items: [DraggedOutItem] = [Self.file]) throws -> GuestDragTake {
        let take = try readyTake(items: items)
        take.withheldDrag()
        try #require(take.phase == .carried(.outside(targeted: true)))
        return take
    }

    /// Writes item `index` to `destination` and returns the write's outcome
    /// once `end` ends its pull.
    private func write(
        _ take: GuestDragTake, item index: Int, to destination: URL,
        ending end: (FakeTransport) throws -> Void = { _ in }
    ) async throws -> (any Error)? {
        let pulls = transport.pulls.count
        let outcome = OutcomeBox(gate: transport.changed)
        take.writeItem(at: index, to: destination) { error in outcome.set(error) }
        try await transport.changed.wait { transport.pulls.count > pulls || outcome.isSet }
        try end(transport)
        try await transport.changed.wait { outcome.isSet }
        return outcome.error
    }

    /// One write's outcome, announced on `gate`.
    final class OutcomeBox: Sendable {
        private let state = Locked<(set: Bool, error: (any Error)?)>((false, nil))
        private let changed: AsyncGate

        init(gate: AsyncGate) { changed = gate }

        var isSet: Bool { state.withLock { $0.set } }
        var error: (any Error)? { state.withLock { $0.error } }

        func set(_ error: (any Error)?) {
            state.withLock { $0 = (true, error) }
            changed.notify()
        }
    }

    // MARK: - The handshake gates the release

    @Test("nothing nudges before the catcher is armed; ARMED nudges a pointer stopped past the edge")
    func armedNudgesAStoppedPointer() {
        let take = makeTake()
        take.withheldDrag()
        #expect(display.calls.isEmpty)

        // No physical event follows: the pointer stopped dead past the edge.
        transport.report(.armed)
        #expect(take.phase == .handingOff(armed: true))
        #expect(display.calls == [.nudge(.exitPoint)])

        take.withheldDrag()
        #expect(display.calls == [.nudge(.exitPoint), .nudge(.offset)])
        transport.target()
        #expect(take.phase == .ready)
    }

    @Test("TARGETED alone readies the take: no release goes in before it, whatever the press does")
    func noReleaseBeforeTargeted() {
        let take = makeTake()
        transport.report(.armed)
        take.withheldDrag()
        take.withheldMouseUp()

        #expect(take.phase == .abandoned)
        #expect(!display.calls.contains(.release))
        #expect(display.calls.suffix(2) == [.returnToExit, .resumeTracking])
        #expect(transport.cancels == 1)
    }

    @Test("a Mac session begins from ready and the guest's button stays held while it runs")
    func sessionKeepsTheButtonHeld() throws {
        let take = try readyTake()
        take.withheldDrag()

        #expect(take.phase == .carried(.outside(targeted: true)))
        #expect(display.calls.last == .beginSession)
        #expect(!display.calls.contains(.release))
    }

    @Test("the button coming up once the catcher is the target releases onto it, with no delivery")
    func readyMouseUpReleases() throws {
        let take = try readyTake()
        take.withheldMouseUp()

        #expect(take.phase == .released(at: .catcher))
        #expect(display.calls.last == .release)
        #expect(transport.controls.isEmpty)
    }

    @Test("a refused take hands the press back, looking again for a drag, and injects no release")
    func refusedTakeHandsBack() {
        let take = makeTake()
        transport.end(.refused(WireError(.dragPressOver)))

        #expect(take.phase == .abandoned)
        #expect(display.calls == [.returnToExit, .resumeTracking])
        #expect(transport.cancels == 0)
        #expect(transport.releases == 1)
        #expect(finished.count == 1)
    }

    @Test("a Mac session that does not begin releases onto the catcher")
    func sessionThatDoesNotBeginReleases() throws {
        display.sessionBegins = false
        let take = try readyTake()
        take.withheldDrag()

        #expect(take.phase == .released(at: .catcher))
        #expect(display.calls.suffix(2) == [.beginSession, .release])
    }

    @Test("a session that ends with nothing taking it releases onto the catcher and asks no delivery")
    func undroppedSessionReleases() throws {
        let take = try carriedTake(items: [Self.promise])
        take.hostSessionEnded(dropped: false)

        #expect(take.phase == .released(at: .catcher))
        #expect(transport.controls.isEmpty)
        #expect(finished.count == 0)
        transport.end(.caught(nil))
        #expect(transport.releases == 1)
        #expect(finished.count == 1)
    }

    // MARK: - Drag-back-in

    @Test("the session coming back over the display stands the catcher down and moves the guest pointer with it")
    func sessionOverTheDisplayReturnsTheDrag() throws {
        let take = try carriedTake()
        let point = CGPoint(x: 120, y: 80)

        #expect(take.hostSession(over: display, at: point))
        #expect(take.phase == .carried(.inside))
        #expect(take.sessionOverDisplay)
        #expect(transport.controls == [.catcher(shown: false)])
        #expect(display.calls.last == .drag(point))

        let next = CGPoint(x: 130, y: 90)
        #expect(take.hostSession(over: display, at: next))
        #expect(transport.controls == [.catcher(shown: false)])
        #expect(display.calls.last == .drag(next))
    }

    @Test("a drop over the display releases the guest's button there, so the drag lands in the guest")
    func dropOverTheDisplayLandsInTheGuest() async throws {
        let take = try carriedTake(items: [Self.promise])
        let point = CGPoint(x: 50, y: 60)
        _ = take.hostSession(over: display, at: point)
        transport.report(.stoodDown)

        #expect(take.hostSessionDropped(on: display, at: point))
        #expect(take.phase == .released(at: .dropPoint))
        #expect(display.calls.suffix(2) == [.drag(point), .release])
        take.hostSessionEnded(dropped: true)

        #expect(!transport.controls.contains(.deliver))
        let outcome = try await write(take, item: 0, to: URL(fileURLWithPath: "/tmp/drag-out/x.jpeg"))
        #expect(outcome as? GuestDragWriteError == .failed(.transferFailed))
        transport.end(.returned)
        #expect(finished.count == 1)
    }

    @Test("a drop over the display before the catcher reports STOOD_DOWN releases only once it does")
    func dropWaitsForTheCatcherToStandDown() throws {
        let take = try carriedTake()
        let point = CGPoint(x: 50, y: 60)
        _ = take.hostSession(over: display, at: point)

        #expect(take.hostSessionDropped(on: display, at: point))
        #expect(take.phase == .carried(.dropped))
        #expect(display.calls.last == .drag(point))
        take.hostSessionEnded(dropped: true)
        // A step about the catcher that is not its stand-down releases nothing.
        transport.target()
        #expect(!display.calls.contains(.release))

        transport.report(.stoodDown)
        #expect(take.phase == .released(at: .dropPoint))
        #expect(display.calls.suffix(2) == [.drag(point), .release])
    }

    @Test("a stand-down answers only its own: a drop after a second one waits for the second STOOD_DOWN")
    func eachStandDownIsAnswered() throws {
        let take = try carriedTake()
        let point = CGPoint(x: 5, y: 5)
        _ = take.hostSession(over: display, at: point)
        take.hostSessionLeft(display)
        _ = take.hostSession(over: display, at: point)
        transport.report(.stoodDown)

        #expect(take.hostSessionDropped(on: display, at: point))
        #expect(take.phase == .carried(.dropped))
        transport.report(.stoodDown)
        #expect(take.phase == .released(at: .dropPoint))
    }

    @Test("a take that ends while its drop waits on STOOD_DOWN releases at the drop point")
    func dropReleasesWhenTheTakeEnds() throws {
        let take = try carriedTake()
        let point = CGPoint(x: 5, y: 5)
        _ = take.hostSession(over: display, at: point)
        _ = take.hostSessionDropped(on: display, at: point)

        transport.end(.returned)
        #expect(take.phase == .released(at: .dropPoint))
    }

    @Test("leaving the display again shows the catcher; its ARMED nudges, and only the new showing's TARGETED counts")
    func leavingTheDisplayShowsTheCatcherAgain() throws {
        let take = try carriedTake()
        _ = take.hostSession(over: display, at: CGPoint(x: 10, y: 10))
        take.hostSessionLeft(display)

        #expect(take.phase == .carried(.outside(targeted: false)))
        #expect(transport.controls == [.catcher(shown: false), .catcher(shown: true)])
        // A target for the showing since stood down says nothing of the new one.
        transport.target()
        #expect(take.phase == .carried(.outside(targeted: false)))

        let nudgesBefore = display.calls.count { if case .nudge = $0 { true } else { false } }
        transport.report(.armed)
        #expect(display.calls.count { if case .nudge = $0 { true } else { false } } == nudgesBefore + 1)
        take.hostSessionMoved()
        #expect(display.calls.count { if case .nudge = $0 { true } else { false } } == nudgesBefore + 2)
        transport.target()
        #expect(take.phase == .carried(.outside(targeted: true)))
    }

    @Test("a session ended over the display without a drop shows the catcher, and its TARGETED releases onto it")
    func sessionEndedOverTheDisplayReleasesOntoTheCatcher() throws {
        let take = try carriedTake()
        _ = take.hostSession(over: display, at: CGPoint(x: 10, y: 10))
        take.hostSessionEnded(dropped: false)

        #expect(take.phase == .carried(.ended))
        #expect(transport.controls.last == .catcher(shown: true))
        transport.report(.armed)
        transport.target()
        #expect(take.phase == .released(at: .catcher))
    }

    @Test("the pointer coming back before the session hands the press to the guest and calls the take off")
    func pointerReturnBeforeTheSession() throws {
        let take = try readyTake()
        take.pointerReturned()

        #expect(take.phase == .abandoned)
        #expect(display.calls.suffix(2) == [.returnToExit, .resumeTracking])
        #expect(!display.calls.contains(.release))
        #expect(transport.cancels == 1)
        #expect(finished.count == 0)
        transport.end(.closed(.resetLocally(WireError(.cancelled))))
        #expect(transport.releases == 1)
        #expect(finished.count == 1)
    }

    // MARK: - Delivery

    @Test("a dropped drag of plain files releases onto the catcher and pulls from the taken offer")
    func plainFilesNeedNoDelivery() async throws {
        let take = try carriedTake()
        take.hostSessionEnded(dropped: true)

        #expect(take.phase == .released(at: .catcher))
        #expect(transport.controls.isEmpty)
        let outcome = try await write(take, item: 0, to: URL(fileURLWithPath: "/Users/me/Desktop/a 2.txt")) {
            $0.end(0, .success(()))
        }
        #expect(outcome == nil)
        let pull = try #require(transport.pulls.first)
        #expect(pull.destination.path == "/Users/me/Desktop/a 2.txt")
        #expect(transport.releases == 0)
        transport.end(.caught(nil))
        #expect(transport.releases == 1)
        #expect(finished.count == 1)
    }

    @Test("a dropped drag of a promise and a folder releases only on DELIVERING; writes wait for the delivery")
    func promisesAndFoldersAreDeliveredAtTheDrop() async throws {
        let take = try carriedTake(items: [Self.promise, Self.folder])
        take.hostSessionEnded(dropped: true)

        #expect(take.phase == .carried(.delivering))
        #expect(transport.controls == [.deliver])
        #expect(!display.calls.contains(.release))

        let outcome = OutcomeBox(gate: transport.changed)
        take.writeItem(at: 0, to: URL(fileURLWithPath: "/Users/me/Desktop/IMG_0042.jpeg")) { outcome.set($0) }
        await Task.yield()
        #expect(transport.pulls.isEmpty)

        transport.report(.delivering)
        #expect(take.phase == .released(at: .catcher))
        transport.end(.caught(Self.delivery), delivered: [Self.namedPromise, Self.sizedFolder])

        try await transport.changed.wait { !transport.pulls.isEmpty }
        #expect(transport.pulls.first?.destination.lastPathComponent == "IMG_0042.jpeg")
        // The one offer is held until every item is written.
        #expect(transport.releases == 0)
        #expect(take.filename(forItemAt: 0) == "IMG_0042.jpeg")
        #expect(take.filename(forItemAt: 1) == "Folder")
        transport.end(0, .success(()))
        try await transport.changed.wait { outcome.isSet }
        #expect(outcome.error == nil)

        _ = try await write(take, item: 1, to: URL(fileURLWithPath: "/Users/me/Desktop/Folder")) {
            $0.end(1, .success(()))
        }
        #expect(transport.releases == 1)
        #expect(finished.count == 1)
    }

    @Test("a promised item's name asked mid-drop waits on the delivery it starts, released from the waiting thread")
    func aNameAskWaitsOnTheDelivery() throws {
        let take = try carriedTake(items: [Self.promise])
        let transport = transport
        let display = display
        let delivery = try #require(transport.delivery)
        // The guest, answering on a thread of its own while the ask holds the
        // main thread: it waits for the ask, answers, waits for the release,
        // then names the item in the offer its catch names.
        let guest = Thread {
            transport.delivering.wait()
            delivery.peerAnswered()
            display.released.wait()
            delivery.settle(.delivered([Self.namedPromise]))
        }
        guest.start()

        #expect(take.filename(forItemAt: 0) == "IMG_0042.jpeg")
        #expect(transport.controls == [.deliver])
        #expect(take.phase == .released(at: .catcher))
        #expect(take.filename(forItemAt: 0) == "IMG_0042.jpeg")
        #expect(transport.controls == [.deliver])
    }

    @Test("a name ask waits for the names alone: the folder sizes after them hold no writer and no main thread")
    func aNameAskWaitsForNamesAlone() async throws {
        let take = try carriedTake(items: [Self.promise, Self.folder])
        let transport = transport
        let display = display
        let delivery = try #require(transport.delivery)
        let guest = Thread {
            transport.delivering.wait()
            delivery.peerAnswered()
            display.released.wait()
            delivery.named([Self.namedPromise, Self.folder])
        }
        guest.start()

        #expect(take.filename(forItemAt: 0) == "IMG_0042.jpeg")
        #expect(delivery.settled == nil, "the names waited for the folder sizes")
        let outcome = OutcomeBox(gate: transport.changed)
        take.writeItem(at: 1, to: URL(fileURLWithPath: "/Users/me/Desktop/Folder")) { outcome.set($0) }
        await Task.yield()
        #expect(transport.pulls.isEmpty, "a write pulled before the delivery sized the folders")

        transport.end(.caught(Self.delivery), delivered: [Self.namedPromise, Self.sizedFolder])
        try await transport.changed.wait { !transport.pulls.isEmpty }
        #expect(transport.pulls.first?.index == 1)
    }

    @Test("a name asked while the catcher is not the target is the stand-in, and asks no delivery")
    func aNameAskOffTargetIsAStandIn() throws {
        let take = try carriedTake(items: [Self.promise])
        _ = take.hostSession(over: display, at: CGPoint(x: 1, y: 1))
        take.hostSessionLeft(display)

        #expect(take.filename(forItemAt: 0) == "Untitled.jpeg")
        #expect(!transport.controls.contains(.deliver))
        #expect(!take.nameItemsForInAppDestination())
    }

    @Test("DELIVER_REFUSED still releases onto the catcher; a promise nothing delivered then fails unavailable")
    func refusedDeliveryReleasesAnyway() async throws {
        let take = try carriedTake(items: [Self.promise])
        take.hostSessionEnded(dropped: true)
        transport.report(.deliverRefused)
        #expect(take.phase == .released(at: .catcher))

        let outcome = OutcomeBox(gate: transport.changed)
        take.writeItem(at: 0, to: URL(fileURLWithPath: "/tmp/drag-out/x.jpeg")) { outcome.set($0) }
        transport.end(.caught(nil))
        try await transport.changed.wait { outcome.isSet }
        #expect(outcome.error as? GuestDragWriteError == .failed(.peerReported(.dragItemUnavailable)))
        #expect(transport.pulls.isEmpty)
    }

    // MARK: - No timer ends a take

    @Test("a take waiting on the guest waits until the take ends, which releases where the drag left the display")
    func theTakesEndEndsAWait() async throws {
        let take = try carriedTake()
        _ = take.hostSession(over: display, at: CGPoint(x: 1, y: 1))
        take.hostSessionLeft(display)
        take.hostSessionEnded(dropped: true)
        #expect(take.phase == .carried(.ended))

        for _ in 0..<5 { await Task.yield() }
        #expect(take.phase == .carried(.ended))
        #expect(!display.calls.contains(.release))

        transport.end(.closed(.connectionLost))
        #expect(take.phase == .released(at: .exitPoint))
        #expect(display.calls.suffix(2) == [.returnToExit, .release])
    }

    @Test("a delivery the take asked for waits on the guest's answer and nothing else")
    func aDeliveryWaitsOnTheAnswer() async throws {
        let take = try carriedTake(items: [Self.folder])
        take.hostSessionEnded(dropped: true)
        for _ in 0..<5 { await Task.yield() }
        #expect(take.phase == .carried(.delivering))

        transport.end(.refused(WireError(.dragPressOver)))
        #expect(take.phase == .released(at: .exitPoint))
    }

    // MARK: - The take's end

    @Test("the VM stopping mid-hand-off hands the press back")
    func vmStopAbandons() async throws {
        let take = makeTake()
        running.isRunning = false

        try await waitForChange { take.phase == .abandoned }
        #expect(display.calls == [.returnToExit, .resumeTracking])
        #expect(transport.cancels == 1)
    }

    @Test("the VM stopping mid-session calls the take off without a release")
    func vmStopMidSession() async throws {
        let take = try carriedTake()
        running.isRunning = false

        try await waitForChange { take.phase == .unreleased }
        #expect(!display.calls.contains(.release))
        #expect(transport.cancels == 1)
    }

    @Test("the guest's offer ending mid-hand-off hands the press back without releasing it again")
    func offerEndHandsBack() {
        let take = makeTake()
        take.offerEnded()
        transport.end(.refused(WireError(.dragNotCurrent)))

        #expect(take.phase == .abandoned)
        #expect(transport.releases == 0)
        #expect(finished.count == 1)
    }

    @Test("a take is finished only once its stream closed, whatever it released")
    func finishedWaitsForTheStream() throws {
        let take = try readyTake()
        take.withheldMouseUp()
        #expect(finished.count == 0)
        #expect(transport.releases == 0)

        transport.end(.caught(nil))
        #expect(finished.count == 1)
        #expect(transport.releases == 1)
    }

    // MARK: - Writing items

    @Test("a dropped session holds the offer until every item is written, then releases it")
    func releaseFollowsTheLastWrite() async throws {
        let take = try carriedTake(items: [Self.file, Self.file])
        take.hostSessionEnded(dropped: true)
        transport.end(.caught(nil))
        let folder = URL(fileURLWithPath: "/Volumes/Exchange/Inbox", isDirectory: true)

        let first = try await write(take, item: 0, to: folder.appendingPathComponent("a.txt")) {
            $0.end(0, .success(()))
        }
        #expect(first == nil)
        #expect(transport.releases == 0)

        let second = try await write(take, item: 1, to: folder.appendingPathComponent("a 2.txt")) {
            $0.end(1, .success(()))
        }
        #expect(second == nil)
        #expect(transport.releases == 1)
        #expect(finished.count == 1)
    }

    @Test("a failed pull fails its write and every write after it")
    func failedPullEndsTheWrites() async throws {
        let take = try carriedTake(items: [Self.file, Self.file])
        take.hostSessionEnded(dropped: true)
        transport.end(.caught(nil))
        let folder = URL(fileURLWithPath: "/tmp/drag-out", isDirectory: true)

        let failed = try await write(take, item: 0, to: folder.appendingPathComponent("a.txt")) {
            $0.end(0, .failure(WireError(.itemRepresentationUnavailable)))
        }
        #expect(failed as? GuestDragWriteError == .failed(.peerReported(.dragItemUnavailable)))

        let after = try await write(take, item: 1, to: folder.appendingPathComponent("b.txt"))
        #expect(after as? GuestDragWriteError == .failed(.peerReported(.dragItemUnavailable)))
        #expect(transport.pulls.count == 1)
        #expect(transport.releases == 1)
    }

    @Test("the offer ending mid-write cancels the pull, and the write fails interrupted")
    func offerEndInterruptsTheWrite() async throws {
        let take = try carriedTake()
        take.hostSessionEnded(dropped: true)
        transport.end(.caught(nil))
        let destination = URL(fileURLWithPath: "/tmp/drag-out/a.txt")

        let outcome = try await write(take, item: 0, to: destination) { transport in
            take.offerEnded()
            #expect(transport.pulls[0].cancelled)
            transport.end(0, .failure(WireError(.cancelled)))
        }

        #expect(outcome as? GuestDragWriteError == .failed(.interrupted(fileCount: 1)))
        #expect(transport.releases == 0)
        #expect(finished.count == 1)
    }

    @Test("no item is written before a Mac session carries the drag")
    func noWriteBeforeTheSession() async throws {
        let take = try readyTake()
        let outcome = try await write(take, item: 0, to: URL(fileURLWithPath: "/tmp/drag-out/a.txt"))

        #expect(outcome as? GuestDragWriteError == .failed(.transferFailed))
        #expect(transport.pulls.isEmpty)
    }

    @Test("a pull's error says what the readout reports")
    func failureMapping() {
        #expect(GuestDragTake.failure(for: WireError(.itemOfferStale), owed: 3) == .interrupted(fileCount: 3))
        #expect(
            GuestDragTake.failure(for: WireError(.writeFailed, posixErrno: ENOSPC), owed: 1)
                == .diskFull(needed: nil, available: nil))
        #expect(GuestDragTake.failure(for: WireError(.writeFailed), owed: 1) == .stagingFailed)
        #expect(GuestDragTake.failure(for: WireError(.readFailed), owed: 1) == .sourceUnreadable(nil))
    }
}
