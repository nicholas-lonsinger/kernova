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
        /// What the guest lists before its first `TARGETED`.
        var listed: [OfferedItem] = []
        /// The error a pull of an item ends with before it opens, as a landing
        /// this Mac refuses ends it; nil pulls it.
        var refusal: (Int) -> WireError? = { _ in nil }
        private var hasListed = false
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
            _ item: DraggedOutItem, at index: Int, to destination: URL,
            ended: @escaping @MainActor (Result<Void, WireError>) -> Void
        ) -> @MainActor () -> Void {
            if let refused = refusal(index) {
                ended(.failure(refused))
                changed.notify()
                return {}
            }
            let position = pulls.count
            pulls.append(Pull(index: index, destination: destination, ended: ended))
            changed.notify()
            return { [weak self] in self?.pulls[position].cancelled = true }
        }

        func release() {
            releases += 1
        }

        /// The guest's catcher is the drag's target, the take having listed
        /// ``listed`` before its first.
        func target() {
            if !hasListed {
                hasListed = true
                report(.listed(listed))
            }
            report(.targeted)
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
    /// The clock each readout's timers, and the deadline tests' naming
    /// deadline, run on: none fires until a test releases it.
    private let clock = GatedEngineClock()
    /// The naming deadline a take's delivery runs unless its test is about
    /// the deadline: a name ask on the main thread holds it at most this long.
    nonisolated private static let heldNaming = GuestDragDelivery.Deadline(
        seconds: mainThreadHoldCap, clock: makePlatformEngineClock())

    private static let file = DraggedOutItem(
        name: Data("a.txt".utf8), type: .plainText, isDirectory: false, sizeEstimate: 4)
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
        revealDelay: TimeInterval = ClipboardTransferOperation.defaultRevealDelay,
        naming: GuestDragDelivery.Deadline = Self.heldNaming
    ) -> GuestDragTake {
        let running = running
        let finished = finished
        transport.listed = Self.offered(items)
        let take = GuestDragTake(
            transport: transport, display: display,
            reporter: reporter, peerName: "Test VM", progressRevealDelay: revealDelay, clock: clock, naming: naming,
            holds: { running.isRunning },
            onFinished: { _ in finished.count += 1 }, onHostSessionBegan: { _ in })
        take.begin()
        return take
    }

    /// A take whose guest catcher is the drag's target.
    private func readyTake(
        items: [DraggedOutItem] = [Self.file], naming: GuestDragDelivery.Deadline = Self.heldNaming
    ) throws -> GuestDragTake {
        let take = makeTake(items: items, naming: naming)
        transport.report(.armed)
        transport.target()
        try #require(take.phase == .ready)
        return take
    }

    /// A take a Mac session carries off the display, the catcher its target.
    private func carriedTake(
        items: [DraggedOutItem] = [Self.file], naming: GuestDragDelivery.Deadline = Self.heldNaming
    ) throws -> GuestDragTake {
        let take = try readyTake(items: items, naming: naming)
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

    // MARK: - Drag-back-in

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

    // MARK: - The naming deadline

    /// The production naming deadline on the suite's gated clock, for a test
    /// whose subject is that deadline.
    private var gatedNaming: GuestDragDelivery.Deadline {
        GuestDragDelivery.Deadline(seconds: GuestDragDelivery.namingDeadline, clock: clock)
    }

    /// Blocks the calling thread until `delivery`'s naming deadline is armed
    /// on `clock`, then moves the clock on by `seconds` and lets the deadline
    /// fire. A deadline never armed within ``mainThreadHoldCap`` settles the
    /// delivery instead, so a name ask holding the main thread ends.
    nonisolated static func expireDeadline(
        of delivery: GuestDragDelivery, on clock: GatedEngineClock, advancing seconds: TimeInterval,
        reportingTo waits: OffTaskWaits
    ) {
        let armed = waits.run {
            try clock.sleepRequested.block(named: "the naming deadline's arming", timeout: mainThreadHoldCap) {
                !clock.parked.isEmpty
            }
        }
        guard armed else { return delivery.settle(.undelivered) }
        clock.advance(seconds: seconds)
        for sleep in clock.parked { clock.release(sleep) }
    }

    @Test(
        "names that never come end the wait at the deadline with the stand-in, call the take off, and fail its writes timed out",
        arguments: [true, false])
    func namesThatNeverComeExpire(guestAnswers: Bool) async throws {
        let take = try carriedTake(items: [Self.promise], naming: gatedNaming)
        let transport = transport
        let display = display
        let clock = clock
        let delivery = try #require(transport.delivery)
        // The guest answers and its drop names nothing, or the guest answers
        // nothing at all; either way the deadline is what ends the wait.
        let waits = OffTaskWaits()
        let guest = Thread {
            waits.run {
                try Backstop("the transport's delivery", timeout: mainThreadHoldCap).wait(for: transport.delivering)
                if guestAnswers {
                    delivery.peerAnswered()
                    try Backstop("the display's release", timeout: mainThreadHoldCap).wait(for: display.released)
                }
            }
            Self.expireDeadline(
                of: delivery, on: clock, advancing: GuestDragDelivery.namingDeadline, reportingTo: waits)
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
}
