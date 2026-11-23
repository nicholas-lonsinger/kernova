import AppKit
import Foundation
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaKit
import KernovaSynchronization
import KernovaTestSupport
import KernovaWire
import Testing
import UniformTypeIdentifiers

/// The guest half of dragging files out of the VM display: when the watcher
/// offers a drag and withdraws it, how a take is answered and what it carries,
/// how a delivering drop names the promises and sizes the folders, what the
/// host's pulls are served from, and every lifetime path of the catcher — with
/// the event stream, the drag pasteboard and the catcher's window all faked.
@Suite("GuestDragOut", .caseScoped)
@MainActor
struct GuestDragOutTests {
    private let scratch = TestScratchDirectory(prefix: "GuestDragOutTests")

    /// A drag-out over fakes, watching while `usable`.
    @MainActor
    private struct Rig {
        let input = FakeGuestDragInput()
        let surface = FakeCatcherSurface()
        let peer = FakeGuestDragPeer()
        let staging = TestStagingRoot()
        let dragOut: GuestDragOut

        init(usable: Bool = true) {
            dragOut = GuestDragOut(
                peer: peer, system: .faked(input: input, surface: surface), stagingRoot: staging.root)
            dragOut.setUsable(usable)
        }

        var catcher: GuestDragCatcher { dragOut.catcherForTesting }

        /// A press that drags `items`, read by the first tick.
        func pressAndDrag(_ items: [FakePasteboardItem]) {
            input.press()
            input.drag(items)
            input.fireTick()
        }

        /// The button comes up and the next tick sees it.
        func releaseAndTick() {
            input.release()
            input.fireTick()
        }

        /// The token of the `index`th offer.
        func token(_ index: Int = 0) throws -> Data {
            try #require(peer.token(index))
        }

        /// The host takes the `index`th offer, as take `stream`.
        @discardableResult
        func take(_ stream: UInt32, offer index: Int = 0) throws -> DragTakeID {
            let id = takeID(stream)
            dragOut.take(id, token: try token(index))
            return id
        }

        /// The guest's drag manager brings a drag of `items` into the catcher.
        @discardableResult
        func enter(_ items: [GuestDragItem]?) -> NSDragOperation {
            catcher.draggingEntered(GuestDragCatcher.Drag(sourceMask: [.copy, .move, .generic], items: items))
        }
    }

    private static func takeID(_ stream: UInt32) -> DragTakeID {
        DragTakeID(generation: ConnectionGeneration(rawValue: 1), stream: StreamID(rawValue: stream))
    }

    private func takeID(_ stream: UInt32) -> DragTakeID { Self.takeID(stream) }

    private func file(_ name: String, _ contents: String = "bytes") throws -> URL {
        let directory = scratch.url.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func folder(_ name: String, files: [String: String]) throws -> URL {
        let url = scratch.url.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (file, contents) in files {
            try Data(contents.utf8).write(to: url.appendingPathComponent(file))
        }
        return url
    }

    /// One drag callback's view of a drag of `urls`, or of anything else when
    /// nil.
    private func dragged(_ urls: [URL]?, mask: NSDragOperation = [.copy, .move, .generic])
        -> GuestDragCatcher.Drag
    {
        GuestDragCatcher.Drag(sourceMask: mask, items: urls?.map(GuestDragItem.file))
    }

    private func items(_ urls: [URL]) -> [GuestDragItem] {
        urls.map(GuestDragItem.file)
    }

    private func names(_ urls: [URL]) -> [String] {
        urls.map(\.lastPathComponent)
    }

    // MARK: - What a take carries

    @Test(
        "a drag its source is still filling goes out whole: the take carries what the catcher sees, not the watcher's early read"
    )
    func aDragStillFillingGoesOutWhole() async throws {
        let urls = [try file("IMG_0001.JPG"), try file("IMG_0002.JPG"), try file("IMG_0003.JPG", "third")]
        let rig = Rig()
        rig.input.press()
        rig.input.drag(urls.prefix(2).map(fileItem))
        rig.input.fireTick()
        let id = try rig.take(1)
        // The box shows what the pasteboard held as the take claimed the drag.
        #expect(rig.surface.shownItems == items(Array(urls.prefix(2))))

        // The source goes on writing the drag it began, the change count
        // unmoved, so no tick reads it again.
        let count = rig.input.pasteboard.changeCount
        rig.input.fill(urls.map(fileItem))
        rig.input.fireTick()
        #expect(rig.input.pasteboard.changeCount == count)

        // The catcher reads the drag as its live surface does, off the drag's
        // own pasteboard.
        let entered = try #require(GuestDraggedItems.items(on: rig.input.dragPasteboard))
        #expect(rig.enter(entered) == .copy)

        #expect(rig.peer.answers(to: id) == [.armed, .listed(names(urls)), .targeted])
        #expect(rig.surface.shownItems == items(urls))
        let served = rig.dragOut.served
        #expect(try await serve(served, request(try rig.token(), item: 2)) == .success(.tree(path: urls[2].path)))
        #expect(rig.catcher.draggingUpdated(GuestDragCatcher.Drag(sourceMask: .copy, items: entered)) == .copy)
        #expect(rig.peer.offers.count == 1)
        #expect(!rig.peer.events.contains(.withdrew(token: try rig.token())))
    }

    // MARK: - The catcher's steps

    /// A rig whose drag of `urls` the host has taken as take 1.
    private func takenRig(_ urls: [URL]) throws -> Rig {
        let rig = Rig()
        rig.pressAndDrag(urls.map(fileItem))
        try rig.take(1)
        return rig
    }

    /// A rig whose drag of `urls` the host has taken as take 1, which the
    /// catcher reported targeted.
    private func targetedRig(_ urls: [URL]) throws -> Rig {
        let rig = try takenRig(urls)
        rig.enter(items(urls))
        return rig
    }

    @Test("a taken drag reports each step once, ends CAUGHT on the drop, and comes down at the end, never withdrawn")
    func theTakeSteps() throws {
        let urls = [try file("one.txt"), try file("two.txt")]
        let rig = try takenRig(urls)

        #expect(rig.enter(items(urls)) == .copy)
        #expect(rig.catcher.draggingUpdated(dragged(urls)) == .copy)
        #expect(rig.catcher.performDragOperation())
        // The drop's release is the host's; the press ending before the drop
        // concludes leaves the surface for the conclusion to take down.
        rig.releaseAndTick()
        #expect(rig.surface.isShown)
        rig.catcher.concludeDragOperation()

        #expect(
            rig.peer.answers(to: takeID(1)) == [.armed, .listed(names(urls)), .targeted, .caught(sizes: nil)])
        #expect(!rig.surface.isShown)
        #expect(!rig.peer.events.contains(.withdrew(token: try rig.token())))
    }

    @Test(
        "a refusal after TARGETED ends the take and keeps the surface up to refuse the drop",
        arguments: [false, true])
    func aRefusalAfterTargetedKeepsTheSurface(otherItems: Bool) throws {
        let urls = [try file("taken.txt")]
        let rig = try targetedRig(urls)

        let refused =
            otherItems ? dragged([try file("other.txt")]) : dragged(urls, mask: [.move, .generic])
        #expect(rig.catcher.draggingUpdated(refused) == [])

        #expect(rig.surface.isShown)
        // A release the host injected drops here and is refused, so nothing
        // moves.
        #expect(rig.catcher.draggingUpdated(dragged(urls)) == [])
        #expect(!rig.catcher.performDragOperation())
        // The press ending under the surface leaves it for the drag's end.
        rig.releaseAndTick()
        #expect(rig.surface.isShown)

        rig.catcher.draggingEnded()

        #expect(!rig.surface.isShown)
        #expect(
            rig.peer.answers(to: takeID(1)) == [.armed, .listed(names(urls)), .targeted, .refused(.dragNotCurrent)])
    }

    // MARK: - Every path that takes the surface down

    @Test("a cancel of a take this side refused after TARGETED leaves the surface up to refuse the drop")
    func aCancelAfterARefusalKeepsTheSurface() throws {
        let urls = [try file("one.txt")]
        let rig = try targetedRig(urls)
        _ = rig.catcher.draggingUpdated(dragged(urls, mask: [.move]))

        rig.dragOut.cancelled(takeID(1))

        #expect(rig.surface.isShown)
        rig.catcher.draggingEnded()
        #expect(!rig.surface.isShown)
    }

    @Test("a click on a catcher that outlived its drag takes it down, and the next take arms afresh")
    func aClickTakesAStrandedCatcherDown() throws {
        let urls = [try file("one.txt")]
        // Entered, so its press ending leaves it waiting for the drop.
        let rig = try targetedRig(urls)
        rig.releaseAndTick()
        #expect(rig.surface.isShown)

        rig.catcher.surfaceClicked()

        #expect(!rig.surface.isShown)
        #expect(
            rig.peer.answers(to: takeID(1)) == [.armed, .listed(names(urls)), .targeted, .refused(.dragPressOver)])
        // The next press's take arms as the first did.
        let next = [try file("two.txt")]
        rig.pressAndDrag(next.map(fileItem))
        let id = try rig.take(2, offer: 1)
        #expect(rig.surface.isShown)
        #expect(rig.enter(items(next)) == .copy)
        #expect(rig.peer.answers(to: id) == [.armed, .listed(names(next)), .targeted])
    }

    // MARK: - Delivering at the catch

    /// A rig pressing a drag of a plain file named `plain` and then a promise
    /// of each of `promised`, whose pasteboard holds `receivers`.
    private func promiseRig(
        _ promised: [String], receivers: [FakePromiseReceiver], plain: String = "plain.txt"
    ) throws -> (rig: Rig, items: [GuestDragItem]) {
        let plain = try file(plain)
        let rig = Rig()
        rig.input.receivers = receivers
        rig.pressAndDrag([fileItem(plain)] + promised.map { promiseItem($0) })
        let items = [GuestDragItem.file(plain)] + promised.map { GuestDragItem.promise(uti: $0) }
        return (rig, items)
    }

    /// Drops the drag `items` take 1 carries on the catcher, the host having
    /// asked it to deliver, its promises read off `drop` — by default one
    /// calling each promise in through the rig's receivers.
    private func drop(
        _ rig: Rig, _ items: [GuestDragItem], drop: FakeGuestDragDrop? = nil
    ) {
        rig.enter(items)
        rig.dragOut.control(takeID(1), .deliver)
        _ = rig.catcher.performDragOperation(drop: drop ?? FakeGuestDragDrop(items, receivers: rig.input.receivers))
        rig.catcher.concludeDragOperation()
    }

    /// A promise rig the host took as take 1 and asked to deliver at the drop.
    private func deliveredRig(
        _ promised: [String], receivers: [FakePromiseReceiver]
    ) throws -> (rig: Rig, items: [GuestDragItem]) {
        let (rig, items) = try promiseRig(promised, receivers: receivers)
        try rig.take(1)
        drop(rig, items)
        return (rig, items)
    }

    // MARK: - Receiving the whole drop at once

    /// A promise rig the host took as take 1 whose drag of a plain file and a
    /// promise of each of `promised` is dropped to deliver, its first promised
    /// item offering the whole-drop exchange; with the drop and the folder its
    /// paste location names.
    private func wholeDropRig(
        _ promised: [String], receivers: [FakePromiseReceiver] = []
    ) throws -> (rig: Rig, drop: FakeGuestDragDrop, folder: URL) {
        let (rig, items) = try promiseRig(
            promised, receivers: receivers.isEmpty ? promised.map { _ in FakePromiseReceiver(names: []) } : receivers)
        try rig.take(1)
        let wholeDrop = FakeGuestDragDrop(items, offering: [1], receivers: rig.input.receivers)
        drop(rig, items, drop: wholeDrop)
        return (rig, wholeDrop, try #require(rig.input.watchedFolder))
    }

    /// Writes `name` into `folder` as the drag's source places a finished
    /// file, whole in one step.
    @discardableResult
    private func place(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 7, count: 8).write(to: url)
        return url
    }

    @Test("a whole drop relays each file only once its coordinated read is granted, naming the drag once all are")
    func aWholeDropRelaysOnlyGrantedFiles() async throws {
        let (rig, _, folder) = try wholeDropRig(["public.jpeg", "public.jpeg"])
        let token = try rig.token()
        let served = rig.dragOut.served
        let first = try place("IMG_00001.jpg", in: folder)
        let second = try place("IMG_00002.jpg", in: folder)

        rig.input.appear(["IMG_00001.jpg", "IMG_00002.jpg"])

        #expect(rig.input.coordinationsWaiting.map(\.lastPathComponent) == ["IMG_00001.jpg", "IMG_00002.jpg"])
        #expect(failureCode(try await serve(served, request(token, item: 1))) == .itemRepresentationUnavailable)
        rig.input.grant("IMG_00001.jpg")
        // One of two granted: still nothing named, nothing relayed.
        #expect(!rig.peer.answers(to: takeID(1)).contains { if case .named = $0 { true } else { false } })
        #expect(failureCode(try await serve(served, request(token, item: 1))) == .itemRepresentationUnavailable)

        rig.input.grant("IMG_00002.jpg")

        #expect(
            Array(rig.peer.answers(to: takeID(1)).suffix(2)) == [
                .named(["IMG_00001.jpg", "IMG_00002.jpg"]), .caught(sizes: [5, 8, 8]),
            ])
        #expect(try await serve(served, request(token, item: 1)) == .success(.tree(path: first.path)))
        #expect(try await serve(served, request(token, item: 2)) == .success(.tree(path: second.path)))
        #expect(rig.input.watchedFolder == nil)
    }

    // MARK: - What the host's pulls are served from

    /// A pull of item `item` of the offer of `token`.
    private func request(_ token: Data, item: UInt32) -> PullRequest {
        var request = PullRequest()
        request.token = token
        request.item = item
        return request
    }

    /// Starts a pull of item `item` of the offer of `token` on a queue of its
    /// own, as a pull's queue serves it, returning once the call is under way.
    private func startPull(
        _ rig: Rig, token: Data, item: UInt32
    ) async throws -> BlockingCall<Result<ItemContent, WireError>> {
        let served = rig.dragOut.served
        let request = request(token, item: item)
        let probe = PullProbe()
        let pull = BlockingCall {
            probe.markStarted()
            return served.content(request)
        }
        try await probe.started.wait { probe.isStarted }
        return pull
    }

    /// `served`'s answer to `request`, served off the main actor as a pull's
    /// queue serves it: a promise's serve waits on its landing, and a serve
    /// that never answers would hold the main thread every main-actor test
    /// needs.
    private func serve(
        _ served: GuestDragServedOffers, _ request: PullRequest, fileID: String = #fileID, line: Int = #line
    ) async throws -> Result<ItemContent, WireError> {
        try await offCooperativePool(fileID: fileID, line: line) { served.content(request) }
    }

    private func failureCode(_ result: Result<ItemContent, WireError>) -> ErrorCode? {
        guard case .failure(let error) = result else { return nil }
        return error.code
    }

    @Test("an offer serves nothing until a take carries it, then each plain file from where it is")
    func filesAreServedOnceCarried() async throws {
        let one = try file("one.txt")
        let tree = try folder("Tree", files: ["a.txt": "alpha"])
        let rig = try takenRig([one, tree])
        let token = try rig.token()
        let served = rig.dragOut.served
        #expect(failureCode(try await serve(served, request(token, item: 0))) == .itemRepresentationUnavailable)

        rig.enter(items([one, tree]))

        #expect(try await serve(served, request(token, item: 0)) == .success(.tree(path: one.path)))
        #expect(try await serve(served, request(token, item: 1)) == .success(.tree(path: tree.path)))
        #expect(failureCode(try await serve(served, request(token, item: 2))) == .itemRepresentationUnavailable)
        #expect(
            failureCode(try await serve(served, request(Data(repeating: 3, count: 16), item: 0)))
                == .itemRepresentationUnavailable)
    }

    @Test("a promise naming several files whose first fails is unavailable, whatever the others do")
    func aSeveralFilePromiseWithoutItsFirstFileIsUnavailable() async throws {
        let burst = FakePromiseReceiver(names: ["IMG_0002.JPG", "IMG_0003.JPG"])
        let (rig, _) = try deliveredRig(["public.jpeg"], receivers: [burst])

        let pull = try await startPull(rig, token: try rig.token(), item: 1)
        try burst.fail("IMG_0002.JPG")
        try burst.write("IMG_0003.JPG", contents: Data(count: 3))

        #expect(failureCode(try await pull.returned()) == .itemRepresentationUnavailable)
    }

    @Test("the offer ending while a pull waits on its promise answers the pull unavailable")
    func anOfferEndingFailsAWaitingPull() async throws {
        let photo = FakePromiseReceiver(names: ["IMG_0001.HEIC"])
        let (rig, _) = try deliveredRig(["public.heic"], receivers: [photo])
        let token = try rig.token()

        let pull = try await startPull(rig, token: token, item: 1)
        rig.dragOut.offerEnded(token)

        #expect(failureCode(try await pull.returned()) == .itemRepresentationUnavailable)
    }

    // MARK: - The catcher's window

    /// The live catcher window laid out over `screen` for `urls`, never
    /// ordered front.
    private func catcherWindow(
        for urls: [URL] = [URL(fileURLWithPath: "/one.txt")],
        over screen: NSRect = NSRect(x: 0, y: 0, width: 1440, height: 900)
    ) -> (window: NSPanel, icons: FakeGuestDragTypeIcons) {
        catcherWindow(items: urls.map(GuestDragItem.file), over: screen)
    }

    /// The live catcher window laid out over `screen` for `items`, never
    /// ordered front.
    private func catcherWindow(
        items: [GuestDragItem], over screen: NSRect = NSRect(x: 0, y: 0, width: 1440, height: 900)
    ) -> (window: NSPanel, icons: FakeGuestDragTypeIcons) {
        let peer = FakeGuestDragPeer()
        let catcher = GuestDragCatcher(peer: peer, makeSurface: { _ in FakeCatcherSurface() })
        let icons = FakeGuestDragTypeIcons()
        let panel = GuestDragCatcherPanel(catcher: catcher, typeIcon: icons.icon(for:))
        panel.layOut(items: items, over: screen)
        let window = panel.windowForTesting
        window.contentView?.layoutSubtreeIfNeeded()
        return (window, icons)
    }
}

/// Tells a test that a pull it started off the main actor is under way.
private final class PullProbe: Sendable {
    let started = AsyncGate()
    private let state = Locked(false)

    var isStarted: Bool { state.withLock { $0 } }

    func markStarted() {
        state.withLock { $0 = true }
        started.notify()
    }
}
