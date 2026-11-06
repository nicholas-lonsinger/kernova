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

    var takeCount: Int { state.withLock { $0.takes.count } }
    var pullCount: Int { state.withLock { $0.pulls.count } }
    var releaseCount: Int { state.withLock { $0.releases.count } }
    var controls: [DragTakeControl] { state.withLock { $0.controls.map(\.control) } }
}
/// DRAG's host owner over the agent hub: the console peer's drag offer read
/// whole, its take, the pulls that fill a Mac destination's promises, and the
/// release that completes the drag.
@Suite("HubDragOut", .caseScoped)
@MainActor
struct HubDragOutTests {
    // MARK: - Doubles

    /// A display whose Mac session always begins; each release also fires
    /// `releases`, from whichever thread injects it.
    @MainActor
    final class SessionDisplay: GuestDragDisplay {
        private(set) var released = false
        nonisolated let releases = DispatchSemaphore(value: 0)
        func injectNudge(_ nudge: GuestDragNudge) {}
        func injectDrag(at point: CGPoint) {}
        func returnToExitPoint() {}
        func injectRelease() {
            released = true
            releases.signal()
        }
        func resumeTracking() {}
        func beginHostSession(carrying take: any GuestDragTaking) -> Bool { true }
    }

    private let scratch = TestScratchDirectory(prefix: "HubDragOutTests")
    private let hub = FakeDragOutHub()
    /// Held here: a take holds its display weakly.
    private let display = SessionDisplay()
    private let dragOut: HubDragOut
    private let peer = PeerHandle(rawValue: 7)
    private let token = Data(repeating: 0xAB, count: 16)
    private let takeID = DragTakeID(generation: ConnectionGeneration(rawValue: 1), stream: StreamID(rawValue: 5))

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        dragOut = HubDragOut(
            sink: ItemSinkAdapter(fileSystem: POSIXTreeFileSystem()), reporter: ClipboardTransferReporter(),
            peerName: { "Test VM" })
        dragOut.hub = hub
    }

    private static func item(
        _ name: String, storage: Representation.Storage, uti: String, promised: Bool = false, size: UInt64 = 0
    ) -> OfferedItem {
        var representation = Representation()
        representation.type = TypeDescriptor(appleUTI: uti)
        representation.storage = storage
        representation.name = Data(name.utf8)
        representation.promised = promised
        representation.sizeEstimate = size
        var item = OfferedItem()
        item.representations = [representation]
        return item
    }

    /// The guest offers a drag under ``token``.
    private func offer() {
        dragOut.consolePeerChanged(peer)
        dragOut.offerReceived(token, from: peer)
    }

    private static let running: @MainActor () -> Bool = { true }

    /// The display takes the current offer over.
    private func takeOffer() throws -> GuestDragTake {
        let take = dragOut.takeGuestDrag(display: display, while: Self.running)
        return try #require(take)
    }

    private static let twoItems = [
        item("notes.txt", storage: .file, uti: "public.plain-text"),
        item("todo.txt", storage: .file, uti: "public.plain-text"),
    ]

    private static let promiseAndFolder = [
        item("Untitled.jpeg", storage: .file, uti: "public.jpeg", promised: true),
        item("Photos", storage: .folder, uti: "public.folder"),
    ]

    /// The take's event `event`, as the hub hands it to DRAG's owner: on the
    /// hub's queue first, then a hop to the main queue.
    private func deliver(_ event: DragTakeEvent) async {
        dragOut.owner.takes(peer, event)
        await MainActorTurn.next()
    }

    /// A take of the current offer of `items`, the hub having opened it and
    /// the guest's catcher its target, carried by a Mac session.
    private func carriedTake(_ items: [OfferedItem] = Self.twoItems) async throws -> GuestDragTake {
        offer()
        let take = try takeOffer()
        try await hub.changed.wait { hub.takeCount == 1 }
        hub.state.withLock { $0.takes[0] }.completion(.success(takeID))
        // The answer hops to the main queue, ahead of the take's events.
        await MainActorTurn.next()
        await deliver(.report(takeID, .armed))
        await deliver(.report(takeID, .targeted(items)))
        try #require(take.phase == .ready)
        take.withheldDrag()
        try #require(take.phase == .carried(.outside(targeted: true)))
        return take
    }

    /// A carried take of plain files whose session a destination took, the
    /// guest's drag caught.
    private func droppedTake() async throws -> GuestDragTake {
        let take = try await carriedTake()
        take.hostSessionEnded(dropped: true)
        await deliver(.ended(takeID, .caught(nil)))
        return take
    }

    // MARK: - The offer

    @Test("a console peer's drag offer is the drag the display may take; its first TARGETED names its items")
    func targetedNamesTheItems() async throws {
        offer()
        #expect(dragOut.offer == GuestDragOffer(peer: peer, token: token))

        let take = try await carriedTake([Self.twoItems[0]] + Self.promiseAndFolder)
        #expect(take.items.map(\.filename) == ["notes.txt", "Untitled.jpeg", "Photos"])
        #expect(take.items.map(\.isDirectory) == [false, false, true])
        #expect(take.items.map(\.isPromised) == [false, true, false])
        #expect(take.items[0].type == .plainText)
    }

    @Test("the offer ending, a new press, or a console move clears the drag on offer")
    func offerIsCleared() async throws {
        offer()
        dragOut.offerEnded(token)
        #expect(dragOut.offer == nil)

        offer()
        dragOut.displayPressBegan()
        #expect(dragOut.offer == nil)

        offer()
        dragOut.consolePeerChanged(PeerHandle(rawValue: 8))
        #expect(dragOut.offer == nil)
    }

    // MARK: - Taking and pulling

    @Test("a take goes to the offer's peer, and the display may not take the same offer twice")
    func takeGoesToThePeer() async throws {
        offer()

        _ = try takeOffer()
        try await hub.changed.wait { hub.takeCount == 1 }

        let sent = hub.state.withLock { $0.takes[0] }
        #expect(sent.token == token)
        #expect(sent.peer == peer)
        #expect(dragOut.takeGuestDrag(display: SessionDisplay(), while: Self.running) == nil)
    }

    @Test("what a take says before the hub names it goes to the take once it does")
    func heldControlsFollowTheID() async throws {
        offer()
        let take = try takeOffer()
        try await hub.changed.wait { hub.takeCount == 1 }
        take.pointerReturned()
        #expect(hub.state.withLock { $0.takeCancels }.isEmpty)

        hub.state.withLock { $0.takes[0] }.completion(.success(takeID))
        try await hub.changed.wait { hub.state.withLock { $0.takeCancels } == [takeID] }
        await deliver(.ended(takeID, .closed(.resetLocally(WireError(.cancelled)))))
        #expect(hub.state.withLock { $0.releases.map(\.token) } == [token])
    }

    @Test("a delivering drop names the promises, then sizes the other items, and every item pulls from the one offer")
    func deliveryNamesThenSizes() async throws {
        let take = try await carriedTake(Self.promiseAndFolder)
        take.hostSessionEnded(dropped: true)
        #expect(hub.controls == [.deliver])
        await deliver(.report(takeID, .delivering))
        #expect(take.phase == .released(at: .catcher))

        await deliver(.report(takeID, .named([Data("IMG_0042.jpeg".utf8)])))
        #expect(take.filename(forItemAt: 0) == "IMG_0042.jpeg")
        for (index, name) in ["IMG_0042.jpeg", "Photos"].enumerated() {
            take.writeItem(at: index, to: scratch.url.appendingPathComponent(name)) { _ in }
        }
        await MainActorTurn.next()
        #expect(hub.pullCount == 0, "a write pulled before the delivery sized the items")

        await deliver(
            .ended(takeID, .caught(DragDelivery(names: [0: Data("IMG_0042.jpeg".utf8)], sizes: [1: 4096]))))
        try await hub.changed.wait { hub.pullCount == 2 }
        let pulls = hub.state.withLock { $0.pulls.map(\.order.request) }
        #expect(pulls.map(\.token) == [token, token])
        #expect(Set(pulls.map(\.item)) == [0, 1])
        #expect(hub.releaseCount == 0, "the offer went before its items were written")
    }

    @Test("a promised name asked on the main thread waits on names the hub's queue gives without it")
    func nameAskOnMainSettlesOffMain() async throws {
        let take = try await carriedTake(Self.promiseAndFolder)
        let owner = dragOut.owner
        let (hub, display, peer, takeID) = (hub, display, peer, takeID)
        // The hub's queue while the ask holds the main thread: the guest
        // answers the ask, and once the release reached it, names the promise
        // and never sizes the folder.
        let hubQueue = Thread {
            hub.delivering.wait()
            owner.takes(peer, .report(takeID, .delivering))
            display.releases.wait()
            owner.takes(peer, .report(takeID, .named([Data("IMG_0042.jpeg".utf8)])))
        }
        hubQueue.start()

        #expect(take.filename(forItemAt: 0) == "IMG_0042.jpeg")
        #expect(take.phase == .released(at: .catcher))
    }

    @Test("a hub that cannot open the take hands the press back")
    func unopenedTakeAbandons() async throws {
        offer()
        let take = try takeOffer()
        try await hub.changed.wait { hub.takeCount == 1 }

        hub.state.withLock { $0.takes[0] }.completion(.failure(WireError(.itemOfferStale)))

        try await waitForChange { take.phase == .abandoned }
    }

    @Test("a promise is filled by a pull of its item to exactly the promise URL")
    func writePullsIntoThePromiseURL() async throws {
        let take = try await droppedTake()
        let destination = scratch.url.appendingPathComponent("notes 2.txt")
        let outcome = TestOutcome()

        take.writeItem(at: 0, to: destination) { error in outcome.set(error) }
        try await hub.changed.wait { hub.pullCount == 1 }

        let pull = hub.state.withLock { $0.pulls[0] }
        #expect(pull.peer == peer)
        #expect(pull.order.request.token == token)
        #expect(pull.order.request.item == 0)
        #expect(pull.order.request.representation == 0)
        #expect(pull.order.request.byteCeiling == .max)
        #expect(pull.order.landing == .exactPath(destination.path))

        let id = ItemPullID(generation: ConnectionGeneration(rawValue: 1), stream: StreamID(rawValue: 9))
        pull.completion(.success(id))
        // The answer hops to the main queue, ahead of the pull's end.
        await MainActorTurn.next()
        dragOut.pullEnded(id, .landed(.named(Data("notes 2.txt".utf8))))

        try await outcome.changed.wait { outcome.isSet }
        #expect(outcome.error == nil)
        #expect(hub.releaseCount == 0)
    }

    @Test("a release completes the drag once every item is written")
    func releaseCompletesTheDrag() async throws {
        let take = try await droppedTake()
        for (index, name) in ["notes.txt", "todo.txt"].enumerated() {
            let outcome = TestOutcome()
            take.writeItem(at: index, to: scratch.url.appendingPathComponent(name)) { outcome.set($0) }
            try await hub.changed.wait { hub.pullCount == index + 1 }
            let id = ItemPullID(
                generation: ConnectionGeneration(rawValue: 1), stream: StreamID(rawValue: UInt32(9 + index)))
            hub.state.withLock { $0.pulls[index] }.completion(.success(id))
            await MainActorTurn.next()
            dragOut.pullEnded(id, .landed(.named(Data(name.utf8))))
            try await outcome.changed.wait { outcome.isSet }
            #expect(outcome.error == nil)
        }

        let release = try #require(hub.state.withLock { $0.releases.first })
        #expect(release.token == token)
        #expect(release.peer == peer)
    }

    @Test("a console move mid-write ends the pull and fails the write interrupted, releasing nothing")
    func consoleMoveMidWrite() async throws {
        let take = try await droppedTake()
        let outcome = TestOutcome()
        take.writeItem(at: 0, to: scratch.url.appendingPathComponent("notes.txt")) { outcome.set($0) }
        try await hub.changed.wait { hub.pullCount == 1 }
        let id = ItemPullID(generation: ConnectionGeneration(rawValue: 1), stream: StreamID(rawValue: 9))
        hub.state.withLock { $0.pulls[0] }.completion(.success(id))
        await MainActorTurn.next()

        // The hub ends the offer it forwarded, then the pull, each CANCELLED.
        dragOut.offerEnded(token)
        try await hub.changed.wait { hub.state.withLock { $0.cancels } == [id] }
        dragOut.pullEnded(id, .closed(.resetLocally(WireError(.cancelled))))

        try await outcome.changed.wait { outcome.isSet }
        #expect(outcome.error as? GuestDragWriteError == .failed(.interrupted(fileCount: 2)))
        #expect(hub.releaseCount == 0)
    }

    @Test("termination retires every live take, calling it off and releasing its offer, before the guest answers")
    func terminationRetiresEveryTake() async throws {
        let take = try await carriedTake()
        var retired = false
        take.whenRetired { retired = true }

        dragOut.endForTermination()

        #expect(retired)
        #expect(take.phase == .unreleased)
        #expect(hub.state.withLock { $0.takeCancels } == [takeID])
        #expect(hub.state.withLock { $0.releases.map(\.token) } == [token])
    }

    @Test("a newer take that begins no Mac session leaves the earlier take's promises; a session's start replaces them")
    func promisesLastUntilANewerSession() async throws {
        let earlier = try await droppedTake()
        var retired = false
        earlier.whenRetired { retired = true }

        dragOut.offerReceived(Data(repeating: 0xCD, count: 16), from: peer)
        let abandoned = try takeOffer()
        abandoned.pointerReturned()
        #expect(abandoned.phase == .abandoned)
        #expect(!retired, "a take that began no session withdrew the earlier take's promises")

        dragOut.offerReceived(Data(repeating: 0xEF, count: 16), from: peer)
        let newer = try takeOffer()
        newer.hostSessionWillBegin()
        #expect(retired)
        #expect(hub.state.withLock { $0.releases.map(\.token) }.contains(token))
    }

    @Test("a take of a token the guest offers again leaves the earlier take of it visible to termination")
    func reusedTokenKeepsBothTakes() async throws {
        let earlier = try await droppedTake()
        var retired = false
        earlier.whenRetired { retired = true }
        offer()
        let newer = try takeOffer()

        dragOut.endForTermination()

        #expect(retired, "termination missed the earlier take of the reused token")
        #expect(newer.phase == .abandoned)
        #expect(hub.state.withLock { $0.releases.map(\.token) } == [token, token])
    }

    @Test("a console move before the guest answers hands the press back")
    func consoleMoveMidHandOff() async throws {
        offer()
        let take = try takeOffer()
        try await hub.changed.wait { hub.takeCount == 1 }

        dragOut.offerEnded(token)

        #expect(take.phase == .abandoned)
        #expect(hub.releaseCount == 0)
        hub.state.withLock { $0.takes[0] }.completion(.success(takeID))
        try await hub.changed.wait { hub.state.withLock { $0.takeCancels } == [takeID] }
    }

    /// One write's outcome, announced on its own gate.
    final class TestOutcome: Sendable {
        private let state = Locked<(set: Bool, error: (any Error)?)>((false, nil))
        let changed = AsyncGate()

        var isSet: Bool { state.withLock { $0.set } }
        var error: (any Error)? { state.withLock { $0.error } }

        func set(_ error: (any Error)?) {
            state.withLock { $0 = (true, error) }
            changed.notify()
        }
    }

    /// One turn of the main queue, which the owner's hops ride.
    enum MainActorTurn {
        static func next() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
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

    @Test("a running guest's drag is one its display may take, whatever the guest's OS")
    func runningGuestsDragIsOffered() async throws {
        let instance = try await makeInstance()

        #expect(instance.displayGuestDrag?.token == token)
        #expect(instance.takeGuestDrag(display: TrackingDisplay()) != nil)
        #expect(instance.displayGuestDrag == nil)
    }

    @Test("with drag and drop off, the display is offered no guest drag")
    func settingOffGates() async throws {
        let instance = try await makeInstance(dropFilesEnabled: false)

        #expect(instance.displayGuestDrag == nil)
        #expect(instance.takeGuestDrag(display: TrackingDisplay()) == nil)
    }

    @Test("a paused VM's display is offered no guest drag")
    func notRunningGates() async throws {
        let instance = try await makeInstance()
        instance.activity.placeForTesting(.suspended)

        #expect(instance.displayGuestDrag == nil)
        #expect(instance.takeGuestDrag(display: TrackingDisplay()) == nil)
    }

    @Test("a take holds only while the VM runs: pausing hands the press back")
    func pausingAbandonsTheTake() async throws {
        let instance = try await makeInstance()
        let display = TrackingDisplay()
        _ = try #require(instance.takeGuestDrag(display: display))

        instance.activity.placeForTesting(.suspended)

        try await display.changed.wait { display.resumed }
    }
}
