import Foundation
import KernovaAgentCore
import KernovaKit
import KernovaSynchronization
import KernovaTestSupport
import KernovaTransferProgress
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
            let progress: (any ItemLandingProgress)?
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
            changed.notify()
        }

        func pull(
            _ item: DraggedOutItem, at index: Int, to destination: URL, progress: (any ItemLandingProgress)?,
            ended: @escaping @MainActor (Result<Void, WireError>) -> Void
        ) -> @MainActor () -> Void {
            let position = pulls.count
            pulls.append(Pull(index: index, destination: destination, progress: progress, ended: ended))
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
    /// The clock the delivery's naming deadline runs on: it fires only when a
    /// test releases it.
    private let clock = GatedEngineClock()

    private static let delivery = DragDelivery(names: [:], sizes: [:])

    private static let file = DraggedOutItem(
        name: Data("a.txt".utf8), type: .plainText, isDirectory: false, sizeEstimate: 4)
    /// A plain file as a take lists it: the guest reads no dragged file before the drop, so unsized.
    private static let unsizedFile = DraggedOutItem(name: Data("a.txt".utf8), type: .plainText, isDirectory: false)
    nonisolated private static let folder = DraggedOutItem(name: Data("Folder".utf8), type: .folder, isDirectory: true)
    private static let promise = DraggedOutItem(
        name: Data("Untitled.jpeg".utf8), type: .jpeg, isDirectory: false, isPromised: true)
    nonisolated private static let namedPromise = DraggedOutItem(
        name: Data("IMG_0042.jpeg".utf8), type: .jpeg, isDirectory: false, isPromised: true, sizeEstimate: 9)

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

    private func makeTake(
        items: [DraggedOutItem] = [Self.file], reporter: ClipboardTransferReporter = ClipboardTransferReporter(),
        revealDelay: TimeInterval = ClipboardTransferOperation.defaultRevealDelay
    ) -> GuestDragTake {
        let running = running
        let finished = finished
        transport.listed = Self.offered(items)
        let take = GuestDragTake(
            transport: transport, display: display,
            reporter: reporter, peerName: "Test VM", progressRevealDelay: revealDelay, clock: clock,
            holds: { running.isRunning },
            onFinished: { _ in finished.count += 1 }, onHostSessionBegan: { _ in })
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

    @Test("a dropped drag of plain files is delivered at the drop, and its readout counts their delivered sizes")
    func plainFilesAreDeliveredAtTheDrop() async throws {
        let reporter = ClipboardTransferReporter()
        reporter.onReportChanged = { [transport] _ in transport.changed.notify() }
        let take = makeTake(items: [Self.unsizedFile], reporter: reporter, revealDelay: 0)
        transport.report(.armed)
        transport.target()
        take.withheldDrag()
        take.hostSessionEnded(dropped: true)

        #expect(take.phase == .carried(.delivering))
        #expect(transport.controls == [.deliver])
        let outcome = OutcomeBox(gate: transport.changed)
        take.writeItem(at: 0, to: URL(fileURLWithPath: "/Users/me/Desktop/a 2.txt")) { outcome.set($0) }
        await Task.yield()
        #expect(transport.pulls.isEmpty)

        transport.report(.delivering)
        #expect(take.phase == .released(at: .catcher))
        transport.end(.caught(Self.delivery), delivered: [Self.file])
        try await transport.changed.wait { !transport.pulls.isEmpty }
        #expect(transport.pulls.first?.destination.path == "/Users/me/Desktop/a 2.txt")
        transport.end(0, .success(()))
        try await transport.changed.wait { outcome.isSet }
        #expect(outcome.error == nil)

        try await transport.changed.wait {
            if case .finished = reporter.report { true } else { false }
        }
        guard case .finished(let finish) = reporter.report, case .completed(let final) = finish.outcome else {
            Issue.record("the readout ended \(reporter.report)"); return
        }
        #expect(final.bytesTransferred == 4)
        #expect(final.totalBytes == 4)
        #expect(transport.releases == 1)
        #expect(finished.count == 1)
    }

    @Test("a dragged file's readout climbs as its bytes land, before its pull ends")
    func readoutClimbsAsBytesLand() async throws {
        let reporter = ClipboardTransferReporter()
        reporter.onReportChanged = { [transport] _ in transport.changed.notify() }
        let take = makeTake(items: [Self.unsizedFile], reporter: reporter, revealDelay: 0)
        transport.report(.armed)
        transport.target()
        take.withheldDrag()
        take.hostSessionEnded(dropped: true)
        let outcome = OutcomeBox(gate: transport.changed)
        take.writeItem(at: 0, to: URL(fileURLWithPath: "/Users/me/Desktop/a 2.txt")) { outcome.set($0) }
        transport.report(.delivering)
        transport.end(.caught(Self.delivery), delivered: [Self.file])
        try await transport.changed.wait { !transport.pulls.isEmpty }

        transport.pulls[0].progress?.advanced(landed: 3, declared: 4)

        try await transport.changed.wait {
            if case .running(let snapshot, _) = reporter.report { snapshot.bytesTransferred == 3 } else { false }
        }
        #expect(!outcome.isSet)
        transport.end(0, .success(()))
        try await transport.changed.wait { outcome.isSet }
    }

    @Test("names that arrive before the naming deadline stop it: the delivery stands and the take goes on")
    func namesBeforeTheDeadlineStopIt() async throws {
        let take = try carriedTake(items: [Self.promise])
        let transport = transport
        let display = display
        let delivery = try #require(transport.delivery)
        let guest = Thread {
            transport.delivering.wait()
            delivery.peerAnswered()
            display.released.wait()
            delivery.settle(.delivered([Self.namedPromise]))
        }
        guest.start()

        #expect(take.filename(forItemAt: 0) == "IMG_0042.jpeg")
        let clock = clock
        #expect(clock.requestedSeconds == [GuestDragDelivery.namingDeadline])
        try await clock.parkedChanged.wait { clock.parked.isEmpty }
        #expect(delivery.settled == .delivered([Self.namedPromise]))
        #expect(transport.cancels == 0)
        #expect(take.phase == .released(at: .catcher))
    }

    // MARK: - The naming deadline

    /// Blocks the calling thread until the delivery's naming deadline is
    /// armed on `clock`, then moves the clock on by `seconds` and lets the
    /// deadline fire.
    nonisolated static func expireDeadline(on clock: GatedEngineClock, advancing seconds: TimeInterval) {
        let armed = DispatchSemaphore(value: 0)
        Task {
            try? await clock.sleepRequested.wait { !clock.parked.isEmpty }
            armed.signal()
        }
        armed.wait()
        clock.advance(seconds: seconds)
        for sleep in clock.parked { clock.release(sleep) }
    }

    @Test(
        "names that never come end the wait at the deadline with the stand-in, call the take off, and fail its writes timed out",
        arguments: [true, false])
    func namesThatNeverComeExpire(guestAnswers: Bool) async throws {
        let take = try carriedTake(items: [Self.promise])
        let transport = transport
        let display = display
        let clock = clock
        let delivery = try #require(transport.delivery)
        // The guest answers and its drop names nothing, or the guest answers
        // nothing at all; either way the deadline is what ends the wait.
        let guest = Thread {
            transport.delivering.wait()
            if guestAnswers {
                delivery.peerAnswered()
                display.released.wait()
            }
            Self.expireDeadline(on: clock, advancing: GuestDragDelivery.namingDeadline)
        }
        guest.start()

        #expect(take.filename(forItemAt: 0) == "Untitled.jpeg")
        #expect(delivery.settled == .expired(after: GuestDragDelivery.namingDeadline))
        #expect(take.phase == (guestAnswers ? .released(at: .catcher) : .carried(.delivering)))
        try await transport.changed.wait { transport.cancels == 1 }

        let outcome = try await write(take, item: 0, to: URL(fileURLWithPath: "/Users/me/Desktop/Untitled.jpeg"))
        #expect(outcome as? GuestDragWriteError == .failed(.timedOut))
        #expect(transport.pulls.isEmpty, "a write pulled for a promise nothing named")

        // A name arriving after the deadline changes nothing.
        transport.name([Self.namedPromise])
        #expect(take.filename(forItemAt: 0) == "Untitled.jpeg")

        // The session ends, and the called-off take's end retires it,
        // releasing the offer.
        take.hostSessionEnded(dropped: true)
        transport.end(.closed(.resetLocally(WireError(.cancelled, debugDetail: "the host called the take off"))))
        #expect(take.phase == .released(at: guestAnswers ? .catcher : .exitPoint))
        #expect(transport.releases == 1)
        #expect(finished.count == 1)
    }

    @Test("every name ask of a take shares one deadline, measured from the first ask")
    func theDeadlineIsShared() async throws {
        let take = try carriedTake(items: [Self.promise, Self.promise])
        let transport = transport
        let display = display
        let clock = clock
        let delivery = try #require(transport.delivery)

        // A first ask off the main thread starts the delivery and the deadline.
        let firstName = Locked<String?>(nil)
        let firstReturned = AsyncGate()
        let first = Thread {
            firstName.withLock { $0 = take.filename(forItemAt: 0) }
            firstReturned.notify()
        }
        first.start()
        try await clock.sleepRequested.wait { clock.parked.count == 1 }
        clock.advance(seconds: GuestDragDelivery.namingDeadline / 2)

        let guest = Thread {
            transport.delivering.wait()
            delivery.peerAnswered()
            display.released.wait()
            Self.expireDeadline(on: clock, advancing: GuestDragDelivery.namingDeadline / 2)
        }
        guest.start()

        // A second ask, on the main thread, waits on the same deadline and
        // injects the release.
        #expect(take.filename(forItemAt: 1) == "Untitled.jpeg")
        try await firstReturned.wait { firstName.withLock { $0 } != nil }
        #expect(firstName.withLock { $0 } == "Untitled.jpeg")
        #expect(clock.requestedSeconds == [GuestDragDelivery.namingDeadline], "a second deadline was armed")
        #expect(delivery.settled == .expired(after: GuestDragDelivery.namingDeadline))
        #expect(display.calls.filter { $0 == .release }.count == 1)
        try await transport.changed.wait { transport.cancels == 1 }
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

    // MARK: - Writing items

    // MARK: - Retiring

    @Test("retiring runs what waits on it once, and at once for what asks after")
    func retirementRunsOnce() throws {
        let take = try carriedTake()
        var ran = 0
        take.whenRetired { ran += 1 }
        take.hostSessionEnded(dropped: false)
        #expect(take.phase == .released(at: .catcher))
        #expect(ran == 0, "retired before the take's stream closed")

        transport.end(.caught(nil))
        #expect(ran == 1)
        #expect(finished.count == 1)
        take.whenRetired { ran += 1 }
        #expect(ran == 2)
        transport.end(.caught(nil))
        #expect(ran == 2)
    }

    @Test("a destination that asked for some items holds the take until a newer session replaces its promises")
    func partiallyAskedTakeRetires() async throws {
        let take = try carriedTake(items: [Self.file, Self.file, Self.file])
        var retired = false
        take.whenRetired { retired = true }
        take.hostSessionEnded(dropped: true)
        transport.end(.caught(nil))
        let folder = URL(fileURLWithPath: "/tmp/drag-out", isDirectory: true)

        _ = take.filename(forItemAt: 0)
        let first = try await write(take, item: 0, to: folder.appendingPathComponent("a.txt")) {
            $0.end(0, .success(()))
        }
        #expect(first == nil)
        // Asked by name, which a destination does before it writes.
        _ = take.filename(forItemAt: 1)
        #expect(!retired, "retired while a destination could still ask")

        take.newerTakeBegan()
        #expect(!retired, "retired before a newer session replaced its promises")
        take.promisesReplaced()
        #expect(!retired, "retired before an item already asked for was written")

        let second = try await write(take, item: 1, to: folder.appendingPathComponent("a 2.txt")) {
            $0.end(1, .success(()))
        }
        #expect(second == nil)
        #expect(retired)
        #expect(transport.releases == 1)
        #expect(finished.count == 1)
        #expect(transport.pulls.count == 2)
    }

    @Test("termination retires a take at once, mid-write, calling off its pull")
    func terminationRetiresMidWrite() async throws {
        let take = try carriedTake(items: [Self.file, Self.file])
        var retired = false
        take.whenRetired { retired = true }
        take.hostSessionEnded(dropped: true)
        transport.report(.delivering)
        transport.end(.caught(Self.delivery), delivered: [Self.file, Self.file])
        take.writeItem(at: 0, to: URL(fileURLWithPath: "/tmp/drag-out/a.txt")) { _ in }
        try await transport.changed.wait { !transport.pulls.isEmpty }

        take.endForTermination()

        #expect(retired)
        #expect(finished.count == 1)
        #expect(transport.releases == 1)
        #expect(transport.pulls[0].cancelled)
        // The take's stream ended with its delivery, before any write could pull.
        #expect(transport.cancels == 0)
        let later = try await write(take, item: 1, to: URL(fileURLWithPath: "/tmp/drag-out/b.txt"))
        #expect((later as? CocoaError)?.code == .userCancelled)
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

    @Test("a pull's error says what the readout reports")
    func failureMapping() {
        #expect(GuestDragTake.failure(for: WireError(.itemOfferStale), owed: 3) == .interrupted(fileCount: 3))
        #expect(
            GuestDragTake.failure(for: WireError(.writeFailed, posixErrno: ENOSPC), owed: 1)
                == .diskFull(needed: nil, available: nil))
        #expect(GuestDragTake.failure(for: WireError(.writeFailed), owed: 1) == .stagingFailed)
        #expect(GuestDragTake.failure(for: WireError(.readFailed), owed: 1) == .sourceUnreadable)
    }
}
