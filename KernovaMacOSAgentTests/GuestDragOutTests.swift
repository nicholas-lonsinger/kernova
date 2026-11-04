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

        /// Where every drag's called-in promises land.
        var promiseFolders: URL {
            staging.root.url.appendingPathComponent(GuestDragPromises.stagingLabel, isDirectory: true)
        }

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

        /// The guest's drag manager brings a drag of `items` into the catcher,
        /// and any read of its files the entry started comes back.
        @discardableResult
        func enter(_ items: [GuestDragItem]?, mask: NSDragOperation = [.copy, .move, .generic]) -> NSDragOperation {
            let operation = catcher.draggingEntered(GuestDragCatcher.Drag(sourceMask: mask, items: items))
            input.deliverResolves()
            return operation
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

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Which drags are offered

    @Test("a drag of plain files is offered under a fresh token, listing no items and reading no file")
    func offersADragInProgress() throws {
        let rig = Rig()

        rig.pressAndDrag([fileItem(try file("one.txt")), fileItem(try file("two.txt"))])

        let token = try rig.token()
        #expect(token.count == 16)
        #expect(rig.peer.events == [.offered(token: token)])
        #expect(try #require(rig.peer.offers.first).items.isEmpty)
        #expect(rig.input.resolved.isEmpty)
    }

    @Test("a drag of files and promises is offered the same way, nothing called in or measured")
    func offersAMixedDrag() throws {
        let rig = Rig()
        let photo = FakePromiseReceiver(names: ["IMG_0001.HEIC"])
        rig.input.receivers = [photo]

        rig.pressAndDrag([
            fileItem(try file("plain.txt")), promiseItem("public.heic", alongside: try file("derivative.jpeg")),
            promiseItem("public.folder"),
        ])

        #expect(rig.peer.events == [.offered(token: try rig.token())])
        #expect(try #require(rig.peer.offers.first).items.isEmpty)
        #expect(!photo.wasCalledIn)
        #expect(rig.input.resolved.isEmpty)
        #expect(rig.input.measured.isEmpty)
    }

    @Test("an item's promise wins over the derivative file URL it also carries")
    func aPromiseWinsOverItsFileURL() throws {
        let derivative = try file("derivative.jpeg")
        let pasteboard = FakeReadPasteboard()
        pasteboard.setItems([promiseItem("public.heic", alongside: derivative)])

        #expect(GuestDraggedItems.items(on: pasteboard) == [.promise(uti: "public.heic")])
    }

    @Test("a promise that names no promised type keeps the whole drag in the guest")
    func anUntypedPromiseKeepsTheDrag() throws {
        let rig = Rig()

        rig.pressAndDrag([fileItem(try file("plain.txt")), promiseItem(nil, alongside: try file("promised.jpg"))])

        #expect(rig.peer.events.isEmpty)
    }

    @Test("any item without a file URL keeps the whole drag in the guest")
    func aNonFileItemKeepsTheDrag() throws {
        let rig = Rig()

        rig.pressAndDrag([
            fileItem(try file("plain.txt")),
            FakePasteboardItem([(type: .string, data: Data("just text".utf8))]),
        ])

        #expect(rig.peer.events.isEmpty)
    }

    @Test("a drag the offer limit would cut short is not offered")
    func overTheOfferLimitIsNotOffered() {
        let limit = ClipboardContent.maxOfferableRepresentations
        let files = (0..<limit).map { GuestDragItem.file(URL(fileURLWithPath: "/tmp/item-\($0)")) }
        let intake = ClipboardPasteboardReader.FileIntake(
            representations: files.map { _ in ClipboardContent.Representation(uti: "public.data", data: Data([0])) },
            skipped: 0)

        #expect(GuestDraggedItems.offerItems(files, resolvedFiles: intake)?.count == limit)
        // A promise counts toward the limit like a file.
        #expect(GuestDraggedItems.offerItems(files + [.promise(uti: "public.heic")], resolvedFiles: intake) == nil)
    }

    @Test("a drag pasteboard that is still empty is read again on the next tick")
    func anEmptyPasteboardIsReadAgain() throws {
        let rig = Rig()
        rig.input.press()
        rig.input.drag([])
        rig.input.fireTick()
        #expect(rig.peer.events.isEmpty)

        rig.input.drag([fileItem(try file("late.txt"))])
        rig.input.fireTick()

        #expect(rig.peer.events == [.offered(token: try rig.token())])
    }

    @Test("the live input resolves a folder without reading inside it")
    func theLiveResolveReadsNoFolder() async throws {
        let tree = try folder("Tree", files: ["a.txt": "alpha", "b.txt": "beta"])
        let input = SystemGuestDragInput()

        let intake = await withCheckedContinuation { continuation in
            input.resolveFiles([tree]) { continuation.resume(returning: $0) }
        }

        let representation = try #require(intake.representations.first)
        #expect(representation.isDirectory)
        #expect(representation.byteCount == 0)
    }

    @Test("a drag pasteboard that stops qualifying withdraws the offer, and one qualifying again is offered afresh")
    func aDragThatStopsQualifyingIsWithdrawn() throws {
        let rig = Rig()
        rig.pressAndDrag([fileItem(try file("first.txt"))])

        rig.input.drag([FakePasteboardItem([(type: .string, data: Data("just text".utf8))])])
        rig.input.fireTick()
        rig.input.drag([fileItem(try file("second.txt"))])
        rig.input.fireTick()

        let first = try rig.token(0)
        let second = try rig.token(1)
        #expect(first != second)
        #expect(rig.peer.events == [.offered(token: first), .withdrew(token: first), .offered(token: second)])
    }

    @Test("a drag whose items change keeps its one offer, whether or not the change count moves")
    func aChangingDragKeepsItsOffer() throws {
        let rig = Rig()
        rig.pressAndDrag([fileItem(try file("first.txt"))])

        rig.input.drag([fileItem(try file("second.txt"))])
        rig.input.fireTick()
        rig.input.fill([fileItem(try file("second.txt")), fileItem(try file("third.txt"))])
        rig.input.fireTick()

        #expect(rig.peer.events == [.offered(token: try rig.token())])
    }

    // MARK: - The baseline

    @Test("what was already on the drag pasteboard when watching started is not a drag")
    func whatWasStandingIsNotADrag() throws {
        let rig = Rig(usable: false)
        rig.input.drag([fileItem(try file("old.txt"))])
        rig.dragOut.setUsable(true)

        rig.input.press()
        rig.input.fireTick()

        #expect(rig.peer.events.isEmpty)
    }

    @Test("a press with no drag of its own does not offer the previous press's drag again")
    func thePreviousPressEndIsTheBaseline() throws {
        let rig = Rig()
        rig.pressAndDrag([fileItem(try file("dragged.txt"))])
        rig.releaseAndTick()

        rig.input.press()
        rig.input.fireTick()

        let token = try rig.token()
        #expect(rig.peer.events == [.offered(token: token), .withdrew(token: token)])
    }

    @Test("a drag written before its press is heard of is still this press's drag")
    func aDragAheadOfItsMonitorEventIsSeen() throws {
        let rig = Rig()
        rig.input.press()
        rig.releaseAndTick()

        // The monitor's event arrives after the fact, so the drag's own write
        // can land first: a baseline read when the press is heard of would
        // swallow it.
        rig.input.isPrimaryButtonHeld = true
        rig.input.drag([fileItem(try file("quick.txt"))])
        rig.input.press()
        rig.input.fireTick()

        #expect(rig.peer.events == [.offered(token: try rig.token())])
    }

    // MARK: - Press end and withdrawal

    @Test("the press ending withdraws its offer and stops the timer")
    func pressEndWithdraws() throws {
        let rig = Rig()
        #expect(!rig.input.isTicking)
        rig.pressAndDrag([fileItem(try file("dragged.txt"))])
        #expect(rig.input.isTicking)
        #expect(rig.input.tickInterval == GuestDragWatcher.tickInterval)

        rig.releaseAndTick()

        #expect(rig.peer.events.last == .withdrew(token: try rig.token()))
        #expect(!rig.input.isTicking)
    }

    @Test("a taken offer is never withdrawn when its press ends")
    func aTakenOfferIsNotWithdrawn() throws {
        let rig = Rig()
        rig.pressAndDrag([fileItem(try file("taken.txt"))])
        try rig.take(1)

        rig.releaseAndTick()

        #expect(!rig.peer.events.contains(.withdrew(token: try rig.token())))
    }

    @Test("an offer that ended is neither withdrawn nor offered again in its press")
    func anEndedOfferIsLeftAlone() throws {
        let rig = Rig()
        let url = try file("ended.txt")
        rig.pressAndDrag([fileItem(url)])
        rig.dragOut.offerEnded(try rig.token())

        rig.input.drag([fileItem(url)])
        rig.input.fireTick()
        rig.releaseAndTick()

        #expect(rig.peer.events == [.offered(token: try rig.token())])
    }

    @Test("DRAG going unusable withdraws an untaken offer, drops the monitor and ends the App Nap hold")
    func stoppingReleasesEverything() throws {
        let rig = Rig()
        #expect(rig.input.isHoldingActivity)
        #expect(rig.input.isObservingPresses)
        rig.pressAndDrag([fileItem(try file("dragged.txt"))])

        rig.dragOut.setUsable(false)

        #expect(rig.peer.events.last == .withdrew(token: try rig.token()))
        #expect(!rig.input.isHoldingActivity)
        #expect(!rig.input.isObservingPresses)
        #expect(!rig.input.isTicking)
    }

    // MARK: - Answering a take

    @Test("a take arms the catcher and reports ARMED, then TARGETED listing the items the drag entered it with")
    func aTakeIsTargetedOnceItsItemsAreRead() throws {
        let urls = [try file("one.txt"), try file("two.txt", "four")]
        let rig = Rig()
        rig.pressAndDrag(urls.map(fileItem))

        let id = try rig.take(1)

        #expect(rig.surface.isShown)
        #expect(rig.surface.shownItems == items(urls))
        #expect(rig.peer.answers(to: id) == [.armed])

        // TARGETED waits for the entry's read of the drag's files.
        #expect(rig.catcher.draggingEntered(dragged(urls)) == .copy)
        #expect(rig.peer.answers(to: id) == [.armed])
        #expect(rig.input.resolved == [urls])
        rig.input.deliverResolves()

        #expect(rig.peer.answers(to: id) == [.armed, .targeted(names(urls))])
        let listed = try #require(rig.peer.targeted(id).first).compactMap(\.representations.first)
        #expect(listed.map(\.storage) == [.file, .file])
        #expect(listed.map(\.promised) == [false, false])
        #expect(listed.map(\.sizeEstimate) == [5, 4])
        #expect(rig.peer.offers.count == 1)
    }

    @Test("a take naming a token this side never offered is refused DRAG_NOT_CURRENT and shows nothing")
    func aTakeOfAStaleTokenIsNotCurrent() throws {
        let rig = Rig()
        rig.pressAndDrag([fileItem(try file("dragged.txt"))])

        rig.dragOut.take(takeID(1), token: Data(repeating: 7, count: 16))

        #expect(rig.peer.answers(to: takeID(1)) == [.refused(.dragNotCurrent)])
        #expect(rig.surface.showCount == 0)
    }

    @Test("a take of an earlier press's drag is refused DRAG_NOT_CURRENT")
    func aTakeOfAnEarlierPressFails() throws {
        let rig = Rig()
        rig.pressAndDrag([fileItem(try file("dragged.txt"))])
        rig.releaseAndTick()
        rig.input.press()

        let id = try rig.take(1)

        #expect(rig.peer.answers(to: id) == [.refused(.dragNotCurrent)])
        #expect(rig.surface.showCount == 0)
    }

    @Test("a take after the button came up is refused DRAG_PRESS_OVER, before any tick saw it")
    func aTakeWithTheButtonUpIsPressOver() throws {
        let rig = Rig()
        rig.pressAndDrag([fileItem(try file("dragged.txt"))])
        rig.input.release()

        let id = try rig.take(1)

        #expect(rig.peer.answers(to: id) == [.refused(.dragPressOver)])
        #expect(rig.surface.showCount == 0)
    }

    @Test("a second take of the same drag is refused without touching the first")
    func aRepeatedTakeFails() throws {
        let rig = Rig()
        rig.pressAndDrag([fileItem(try file("dragged.txt"))])
        let first = try rig.take(1)

        let second = try rig.take(2)

        #expect(rig.surface.isShown)
        #expect(rig.peer.answers(to: first) == [.armed])
        #expect(rig.peer.answers(to: second) == [.refused(.dragNotCurrent)])
    }

    @Test("a take while not watching is refused DRAG_NOT_CURRENT")
    func aTakeWhileNotWatchingFails() {
        let rig = Rig(usable: false)

        rig.dragOut.take(takeID(1), token: Data(repeating: 1, count: 16))

        #expect(rig.peer.answers(to: takeID(1)) == [.refused(.dragNotCurrent)])
        #expect(rig.surface.showCount == 0)
    }

    @Test("no screen to cover refuses the take")
    func noScreenRefusesTheTake() throws {
        let rig = Rig()
        rig.surface.hasScreen = false
        rig.pressAndDrag([fileItem(try file("dragged.txt"))])

        let id = try rig.take(1)

        #expect(rig.peer.answers(to: id) == [.refused(.dragNotCurrent)])
        #expect(!rig.surface.isShown)
    }

    // MARK: - What a take carries

    @Test(
        "a drag its source is still filling goes out whole: the take carries what the catcher sees, not the watcher's early read"
    )
    func aDragStillFillingGoesOutWhole() throws {
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

        #expect(rig.peer.answers(to: id) == [.armed, .targeted(names(urls))])
        #expect(rig.surface.shownItems == items(urls))
        let served = rig.dragOut.served
        #expect(served.content(request(try rig.token(), item: 2)) == .success(.tree(path: urls[2].path)))
        #expect(rig.catcher.draggingUpdated(GuestDragCatcher.Drag(sourceMask: .copy, items: entered)) == .copy)
        #expect(rig.peer.offers.count == 1)
        #expect(!rig.peer.events.contains(.withdrew(token: try rig.token())))
    }

    @Test("the drag's items are read once, however often it enters before the read is back")
    func theItemsAreReadOnce() throws {
        let urls = [try file("one.txt")]
        let rig = Rig()
        rig.pressAndDrag(urls.map(fileItem))
        let id = try rig.take(1)

        _ = rig.catcher.draggingEntered(dragged(urls))
        _ = rig.catcher.draggingUpdated(dragged(urls))
        rig.catcher.draggingExited()
        _ = rig.catcher.draggingEntered(dragged(urls))
        rig.input.deliverResolves()

        #expect(rig.input.resolved == [urls])
        #expect(rig.peer.answers(to: id) == [.armed, .targeted(names(urls))])
    }

    @Test("items that cannot go out refuse the take DRAG_NOT_CURRENT and take the surface down")
    func itemsThatCannotGoOutAreRefused() throws {
        let gone = scratch.url.appendingPathComponent("gone.txt")
        let urls = [try file("plain.txt"), gone]
        let rig = Rig()
        rig.pressAndDrag(urls.map(fileItem))
        let id = try rig.take(1)

        #expect(rig.enter(items(urls)) == .copy)

        #expect(rig.peer.answers(to: id) == [.armed, .refused(.dragNotCurrent)])
        #expect(!rig.surface.isShown)
        #expect(
            failureCode(rig.dragOut.served.content(request(try rig.token(), item: 0))) == .itemRepresentationUnavailable
        )
    }

    @Test("a read that comes back after its take ended reports nothing and shows nothing")
    func aReadAfterTheTakeEndedIsDropped() throws {
        let urls = [try file("one.txt")]
        let rig = Rig()
        rig.pressAndDrag(urls.map(fileItem))
        let id = try rig.take(1)
        _ = rig.catcher.draggingEntered(dragged(urls))

        rig.dragOut.cancelled(id)
        rig.input.deliverResolves()

        #expect(rig.peer.answers(to: id) == [.armed])
        #expect(!rig.surface.isShown)
        #expect(rig.surface.showCount == 1)
        #expect(
            failureCode(rig.dragOut.served.content(request(try rig.token(), item: 0)))
                == .itemRepresentationUnavailable)
    }

    @Test("a read that comes back after its offer ended serves nothing, however the take's end is heard")
    func aReadAfterTheOfferEndedServesNothing() throws {
        let urls = [try file("one.txt")]
        let rig = Rig()
        rig.pressAndDrag(urls.map(fileItem))
        let id = try rig.take(1)
        let token = try rig.token()
        _ = rig.catcher.draggingEntered(dragged(urls))

        // The offer's end is heard before the take's cancel.
        rig.dragOut.offerEnded(token)
        rig.input.deliverResolves()
        rig.dragOut.cancelled(id)

        #expect(failureCode(rig.dragOut.served.content(request(token, item: 0))) == .itemRepresentationUnavailable)
    }

    @Test("a read that comes back into a newer take is dropped, and the newer take carries its own drag")
    func aReadIntoANewerTakeIsDropped() throws {
        let first = [try file("first.txt")]
        let second = [try file("second.txt")]
        let rig = Rig()
        rig.pressAndDrag(first.map(fileItem))
        let earlier = try rig.take(1)
        _ = rig.catcher.draggingEntered(dragged(first))
        // A new press before any tick saw the release.
        rig.pressAndDrag(second.map(fileItem))
        let later = try rig.take(2, offer: 1)
        _ = rig.catcher.draggingEntered(dragged(second))

        rig.input.deliverResolves()

        #expect(rig.peer.answers(to: earlier) == [.armed, .refused(.dragNotCurrent)])
        #expect(rig.peer.answers(to: later) == [.armed, .targeted(names(second))])
        #expect(rig.surface.shownItems == items(second))
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
            rig.peer.answers(to: takeID(1)) == [.armed, .targeted(names(urls)), .caught(folderSizes: nil)])
        #expect(!rig.surface.isShown)
        #expect(!rig.peer.events.contains(.withdrew(token: try rig.token())))
    }

    @Test("re-entering after leaving reports nothing more")
    func reEntryReportsNothingMore() throws {
        let urls = [try file("one.txt")]
        let rig = try targetedRig(urls)

        rig.catcher.draggingExited()
        #expect(rig.enter(items(urls)) == .copy)

        #expect(rig.peer.answers(to: takeID(1)) == [.armed, .targeted(names(urls))])
        #expect(rig.input.resolved.count == 1)
    }

    @Test("a drag that carries anything but plain file URLs and promises is refused")
    func aNonFileDragIsRefused() throws {
        let rig = try takenRig([try file("taken.txt")])

        #expect(rig.catcher.draggingUpdated(dragged(nil)) == [])

        #expect(rig.peer.answers(to: takeID(1)) == [.armed, .refused(.dragNotCurrent)])
        #expect(!rig.surface.isShown)
    }

    @Test("a source that does not allow a copy is refused, never answered move or generic")
    func aSourceWithoutCopyIsRefused() throws {
        let urls = [try file("taken.txt")]
        let rig = try takenRig(urls)

        #expect(rig.enter(items(urls), mask: [.move, .generic, .delete]) == [])

        #expect(rig.peer.answers(to: takeID(1)) == [.armed, .refused(.dragNotCurrent)])
        #expect(!rig.surface.isShown)
        #expect(rig.input.resolved.isEmpty)
        // Nothing is left armed to answer a later callback with anything at all.
        #expect(rig.catcher.draggingUpdated(dragged(urls)) == [])
        #expect(!rig.catcher.performDragOperation())
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
            rig.peer.answers(to: takeID(1)) == [.armed, .targeted(names(urls)), .refused(.dragNotCurrent)])
    }

    // MARK: - Drag-back-in

    @Test(
        "standing the catcher down hides it, reports STOOD_DOWN, refuses its callbacks; the press ending then ends the take RETURNED"
    )
    func aStoodDownCatcherReturnsTheDrag() throws {
        let urls = [try file("one.txt")]
        let rig = try targetedRig(urls)

        rig.dragOut.control(takeID(1), .catcher(shown: false))

        #expect(!rig.surface.isShown)
        #expect(rig.catcher.draggingUpdated(dragged(urls)) == [])
        #expect(!rig.catcher.performDragOperation())
        rig.releaseAndTick()
        #expect(
            rig.peer.answers(to: takeID(1)) == [.armed, .targeted(names(urls)), .stoodDown, .returned])
    }

    @Test("the drag ending with the catcher stood down ends the take RETURNED")
    func aDragEndingStoodDownReturns() throws {
        let urls = [try file("one.txt")]
        let rig = try takenRig(urls)
        rig.dragOut.control(takeID(1), .catcher(shown: false))

        rig.catcher.draggingEnded()

        #expect(rig.peer.answers(to: takeID(1)) == [.armed, .stoodDown, .returned])
    }

    @Test("showing the catcher again arms it afresh with what the take carries, and entering reports TARGETED again")
    func showingAgainArmsAfresh() throws {
        let urls = [try file("one.txt")]
        let rig = try targetedRig(urls)
        rig.dragOut.control(takeID(1), .catcher(shown: false))

        rig.dragOut.control(takeID(1), .catcher(shown: true))

        #expect(rig.surface.isShown)
        #expect(rig.surface.shownItems == items(urls))
        #expect(rig.enter(items(urls)) == .copy)
        #expect(rig.input.resolved.count == 1)
        #expect(
            rig.peer.answers(to: takeID(1)) == [
                .armed, .targeted(names(urls)), .stoodDown, .armed, .targeted(names(urls)),
            ])
    }

    @Test("a read that comes back while the catcher is stood down reports TARGETED only once the drag enters again")
    func aReadWhileStoodDownWaitsForTheNextShowing() throws {
        let urls = [try file("one.txt"), try file("two.txt")]
        let rig = Rig()
        rig.input.press()
        rig.input.drag([fileItem(urls[0])])
        rig.input.fireTick()
        try rig.take(1)
        _ = rig.catcher.draggingEntered(dragged(urls))
        rig.dragOut.control(takeID(1), .catcher(shown: false))

        rig.input.deliverResolves()
        #expect(rig.peer.answers(to: takeID(1)) == [.armed, .stoodDown])
        #expect(rig.surface.showCount == 1)

        rig.dragOut.control(takeID(1), .catcher(shown: true))
        #expect(rig.surface.shownItems == items(urls))
        #expect(rig.enter(items(urls)) == .copy)
        #expect(rig.peer.answers(to: takeID(1)) == [.armed, .stoodDown, .armed, .targeted(names(urls))])
    }

    @Test("a later showing holding other items than the take carries refuses it DRAG_NOT_CURRENT before TARGETED")
    func aLaterShowingWithOtherItemsIsRefused() throws {
        let urls = [try file("one.txt")]
        let rig = try targetedRig(urls)
        rig.dragOut.control(takeID(1), .catcher(shown: false))
        rig.dragOut.control(takeID(1), .catcher(shown: true))

        #expect(rig.enter(items([try file("other.txt")])) == [])

        #expect(
            rig.peer.answers(to: takeID(1)) == [
                .armed, .targeted(names(urls)), .stoodDown, .armed, .refused(.dragNotCurrent),
            ])
        #expect(!rig.surface.isShown)
    }

    // MARK: - Every path that takes the surface down

    @Test("the drag ending before it reached the catcher refuses the take DRAG_PRESS_OVER")
    func draggingEndedBeforeTheCatcherRefuses() throws {
        let rig = try takenRig([try file("one.txt")])

        rig.catcher.draggingEnded()

        #expect(!rig.surface.isShown)
        #expect(rig.peer.answers(to: takeID(1)) == [.armed, .refused(.dragPressOver)])
    }

    @Test("the drag ending on a target without a drop refuses the take DRAG_PRESS_OVER")
    func draggingEndedAfterTargetedRefuses() throws {
        let urls = [try file("one.txt")]
        let rig = try targetedRig(urls)

        rig.catcher.draggingEnded()

        #expect(!rig.surface.isShown)
        #expect(
            rig.peer.answers(to: takeID(1)) == [.armed, .targeted(names(urls)), .refused(.dragPressOver)])
    }

    @Test("the drag ending after the drop takes the surface down quietly")
    func draggingEndedAfterTheDropIsQuiet() throws {
        let urls = [try file("one.txt")]
        let rig = try targetedRig(urls)
        _ = rig.catcher.performDragOperation()

        rig.catcher.draggingEnded()

        #expect(!rig.surface.isShown)
        #expect(
            rig.peer.answers(to: takeID(1)) == [.armed, .targeted(names(urls)), .caught(folderSizes: nil)])
    }

    @Test(
        "the host calling the take off takes the surface down and answers nothing more, before or after TARGETED",
        arguments: [false, true])
    func aCancelledTakeComesDown(targeted: Bool) throws {
        let urls = [try file("one.txt")]
        let rig = try takenRig(urls)
        if targeted { rig.enter(items(urls)) }

        rig.dragOut.cancelled(takeID(1))

        #expect(!rig.surface.isShown)
        // Nothing is left armed for a late callback to answer.
        #expect(rig.catcher.draggingEntered(dragged(urls)) == [])
        #expect(rig.peer.answers(to: takeID(1)) == (targeted ? [.armed, .targeted(names(urls))] : [.armed]))
    }

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

    @Test("an offer ending leaves the surface to the take's own end")
    func anOfferEndingLeavesItUp() throws {
        let rig = try takenRig([try file("one.txt")])

        rig.dragOut.offerEnded(try rig.token())
        rig.dragOut.offerEnded(Data(repeating: 9, count: 16))

        #expect(rig.surface.isShown)
    }

    @Test("the session peer stopping takes the surface down")
    func stopTakesItDown() throws {
        let rig = try takenRig([try file("one.txt")])

        rig.dragOut.stop()

        #expect(!rig.surface.isShown)
    }

    @Test("the press ending before the catcher is the drag's target refuses the take DRAG_PRESS_OVER")
    func pressEndBeforeEntryIsPressOver() throws {
        let rig = try takenRig([try file("one.txt")])

        rig.releaseAndTick()

        #expect(!rig.surface.isShown)
        #expect(rig.peer.answers(to: takeID(1)) == [.armed, .refused(.dragPressOver)])
    }

    @Test("the press ending after the drag left the surface takes it down")
    func pressEndAfterExitTakesItDown() throws {
        let urls = [try file("one.txt")]
        let rig = try targetedRig(urls)
        rig.catcher.draggingExited()

        rig.releaseAndTick()

        #expect(!rig.surface.isShown)
        #expect(
            rig.peer.answers(to: takeID(1)) == [.armed, .targeted(names(urls)), .refused(.dragPressOver)])
    }

    @Test("a click on the catcher before the drag reached it refuses the take DRAG_PRESS_OVER")
    func aClickBeforeTheDragRefuses() throws {
        let rig = try takenRig([try file("one.txt")])

        rig.catcher.surfaceClicked()

        #expect(!rig.surface.isShown)
        #expect(rig.peer.answers(to: takeID(1)) == [.armed, .refused(.dragPressOver)])
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
            rig.peer.answers(to: takeID(1)) == [.armed, .targeted(names(urls)), .refused(.dragPressOver)])
        // The next press's take arms as the first did.
        let next = [try file("two.txt")]
        rig.pressAndDrag(next.map(fileItem))
        let id = try rig.take(2, offer: 1)
        #expect(rig.surface.isShown)
        #expect(rig.enter(items(next)) == .copy)
        #expect(rig.peer.answers(to: id) == [.armed, .targeted(names(next))])
    }

    @Test("a click on a catcher that refused after TARGETED takes it down without another answer")
    func aClickTakesARefusingCatcherDown() throws {
        let urls = [try file("one.txt")]
        let rig = try targetedRig(urls)
        _ = rig.catcher.draggingUpdated(dragged(urls, mask: [.move]))

        rig.catcher.surfaceClicked()

        #expect(!rig.surface.isShown)
        #expect(
            rig.peer.answers(to: takeID(1)) == [.armed, .targeted(names(urls)), .refused(.dragNotCurrent)])
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
    /// asked it to deliver when `delivering`.
    private func drop(_ rig: Rig, _ items: [GuestDragItem], delivering: Bool = true) {
        rig.enter(items)
        if delivering { rig.dragOut.control(takeID(1), .deliver) }
        let receivers = rig.input.receivers
        _ = rig.catcher.performDragOperation(receivers: { receivers })
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

    @Test("DELIVER is answered DELIVERING while the drag is on the catcher, and DELIVER_REFUSED before it is")
    func deliverIsAnsweredByWhereTheDragIs() throws {
        let urls = [try file("one.txt")]
        let rig = try takenRig(urls)

        rig.dragOut.control(takeID(1), .deliver)
        rig.enter(items(urls))
        rig.dragOut.control(takeID(1), .deliver)

        #expect(
            rig.peer.answers(to: takeID(1)) == [.armed, .deliverRefused, .targeted(names(urls)), .delivering])
    }

    @Test("a drop the host did not ask to deliver calls nothing in and ends CAUGHT delivering nothing")
    func aPlainDropCallsNothingIn() throws {
        let photo = FakePromiseReceiver(names: ["IMG_0001.HEIC"])
        let (rig, items) = try promiseRig(["public.heic"], receivers: [photo])
        try rig.take(1)

        drop(rig, items, delivering: false)

        #expect(!photo.wasCalledIn)
        #expect(
            rig.peer.answers(to: takeID(1)) == [
                .armed, .targeted(["plain.txt", "Untitled.heic"]), .caught(folderSizes: nil),
            ])
        #expect(rig.peer.offers.count == 1)
        #expect(!exists(rig.promiseFolders))
    }

    @Test(
        "a delivering drop calls the promises in and names them in order, each unlike every other name ignoring case"
    )
    func aDeliveringDropNamesThePromises() throws {
        let photo = FakePromiseReceiver(names: ["IMG_0001.HEIC"])
        let burst = FakePromiseReceiver(names: ["IMG_0002.JPG", "IMG_0003.JPG"])
        let copy = FakePromiseReceiver(names: ["img_0002.jpg"])
        let (rig, items) = try promiseRig(
            ["public.heic", "public.jpeg", "public.jpeg"], receivers: [photo, burst, copy], plain: "img_0001.heic")
        try rig.take(1)

        drop(rig, items)

        let folder = try #require(photo.destination)
        #expect(burst.destination == folder)
        #expect(copy.destination == folder)
        #expect(folder.deletingLastPathComponent().path == rig.promiseFolders.path)
        // A receiver naming several files goes out under its first.
        #expect(
            rig.peer.answers(to: takeID(1)) == [
                .armed, .targeted(["img_0001.heic", "Untitled.heic", "Untitled.jpeg", "Untitled.jpeg"]), .delivering,
                .named(["IMG_0001 2.HEIC", "IMG_0002.JPG", "img_0002 2.jpg"]), .caught(folderSizes: []),
            ])
        let listed = try #require(rig.peer.targeted(takeID(1)).first).compactMap(\.representations.first)
        #expect(listed.map(\.promised) == [false, true, true, true])
        // The taken offer carries the drag on: offered once, never withdrawn,
        // even once the press ends.
        rig.releaseAndTick()
        #expect(rig.peer.offers.count == 1)
        #expect(!rig.peer.events.contains(.withdrew(token: try rig.token())))
    }

    @Test("a delivering drop sizes each unpromised folder, in order, after naming the promises")
    func aDeliveringDropSizesTheFolders() throws {
        let note = try file("note.txt", "four")
        let tree = try folder("Tree", files: ["a.txt": "alpha", "b.txt": "bravo!"])
        let album = try folder("Album", files: ["c.txt": "charlie"])
        let photo = FakePromiseReceiver(names: ["IMG_0001.HEIC"])
        let rig = Rig()
        rig.input.receivers = [photo]
        rig.pressAndDrag([fileItem(note), fileItem(tree), promiseItem("public.heic"), fileItem(album)])
        try rig.take(1)
        drop(rig, [.file(note), .file(tree), .promise(uti: "public.heic"), .file(album)])

        let listed = try #require(rig.peer.targeted(takeID(1)).first).compactMap(\.representations.first)
        #expect(listed.map(\.storage) == [.file, .folder, .file, .folder])
        #expect(listed.map(\.sizeEstimate) == [4, 0, 0, 0])
        #expect(rig.input.measured.map { $0.keys.sorted() } == [[1, 3]])
        let sizes = [tree, album].map { UInt64(ClipboardArchive.estimatedByteCount(at: $0)) }
        #expect(sizes.allSatisfy { $0 > 0 })
        #expect(
            Array(rig.peer.answers(to: takeID(1)).suffix(2)) == [
                .named(["IMG_0001.HEIC"]), .caught(folderSizes: sizes),
            ])
        #expect(rig.peer.offers.count == 1)
    }

    @Test("a delivering drop of folders and no promises names nothing and sizes the folders")
    func aDeliveringDropOfFoldersNamesNothing() throws {
        let tree = try folder("Tree", files: ["a.txt": "alpha"])
        let rig = try takenRig([tree])

        drop(rig, [.file(tree)])

        #expect(
            Array(rig.peer.answers(to: takeID(1)).suffix(2)) == [
                .named([]), .caught(folderSizes: [UInt64(ClipboardArchive.estimatedByteCount(at: tree))]),
            ])
    }

    @Test("a delivering drop of plain files alone ends CAUGHT delivering nothing")
    func aDeliveringDropOfFilesAddsNothing() throws {
        let urls = [try file("one.txt")]
        let rig = try takenRig(urls)

        drop(rig, items(urls))

        #expect(rig.input.measured.isEmpty)
        #expect(
            rig.peer.answers(to: takeID(1)) == [
                .armed, .targeted(names(urls)), .delivering, .caught(folderSizes: nil),
            ])
    }

    @Test("a promise naming no file as it is called in ends the take CAUGHT delivering nothing")
    func aPromiseNamingNothingDeliversNothing() async throws {
        let unnamed = FakePromiseReceiver(names: [])
        let (rig, items) = try promiseRig(["public.heic"], receivers: [unnamed])
        try rig.take(1)

        drop(rig, items)

        #expect(unnamed.wasCalledIn)
        #expect(rig.peer.answers(to: takeID(1)).last == .caught(folderSizes: nil))
        #expect(!rig.peer.answers(to: takeID(1)).contains { if case .named = $0 { true } else { false } })
        #expect(!rig.peer.events.contains(.withdrew(token: try rig.token())))
        #expect(
            failureCode(rig.dragOut.served.content(request(try rig.token(), item: 1)))
                == .itemRepresentationUnavailable)
        // Its source may still write, so the folder goes only once it has.
        let folder = try #require(unnamed.destination)
        #expect(exists(folder))
        try unnamed.write("IMG_0001.HEIC", contents: Data(count: 8))
        await rig.dragOut.promisesForTesting.waitForFolderRemovalsForTesting()
        #expect(!exists(folder))
    }

    @Test("a drag carrying another count of promises than its promised items calls none in")
    func aPromiseCountMismatchCallsNothingIn() throws {
        let only = FakePromiseReceiver(names: ["IMG_0001.HEIC"])
        let (rig, items) = try promiseRig(["public.heic", "public.jpeg"], receivers: [only])
        try rig.take(1)

        drop(rig, items)

        #expect(!only.wasCalledIn)
        #expect(rig.peer.answers(to: takeID(1)).last == .caught(folderSizes: nil))
        #expect(!exists(rig.promiseFolders))
    }

    @Test("a drag that stays in the guest calls nothing in")
    func aDragInTheGuestCallsNothingIn() throws {
        let photo = FakePromiseReceiver(names: ["IMG_0001.HEIC"])
        let (rig, _) = try promiseRig(["public.heic"], receivers: [photo])

        rig.releaseAndTick()

        #expect(!photo.wasCalledIn)
        #expect(rig.peer.answerCount == 0)
        #expect(!exists(rig.promiseFolders))
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
    ) async throws -> Task<Result<ItemContent, WireError>, Never> {
        let served = rig.dragOut.served
        let request = request(token, item: item)
        let probe = PullProbe()
        let task = Task {
            await offCooperativePool {
                probe.markStarted()
                return served.content(request)
            }
        }
        try await probe.started.wait { probe.isStarted }
        return task
    }

    private func failureCode(_ result: Result<ItemContent, WireError>) -> ErrorCode? {
        guard case .failure(let error) = result else { return nil }
        return error.code
    }

    @Test("an offer serves nothing until a take carries it, then each plain file from where it is")
    func filesAreServedOnceCarried() throws {
        let one = try file("one.txt")
        let tree = try folder("Tree", files: ["a.txt": "alpha"])
        let rig = try takenRig([one, tree])
        let token = try rig.token()
        let served = rig.dragOut.served
        #expect(failureCode(served.content(request(token, item: 0))) == .itemRepresentationUnavailable)

        rig.enter(items([one, tree]))

        #expect(served.content(request(token, item: 0)) == .success(.tree(path: one.path)))
        #expect(served.content(request(token, item: 1)) == .success(.tree(path: tree.path)))
        #expect(failureCode(served.content(request(token, item: 2))) == .itemRepresentationUnavailable)
        #expect(
            failureCode(served.content(request(Data(repeating: 3, count: 16), item: 0)))
                == .itemRepresentationUnavailable)
    }

    @Test("a promise not called in serves nothing, and an ended offer serves nothing more")
    func anUncalledPromiseServesNothing() throws {
        let (rig, items) = try promiseRig(
            ["public.heic"], receivers: [FakePromiseReceiver(names: ["IMG_0001.HEIC"])])
        try rig.take(1)
        rig.enter(items)
        let token = try rig.token()
        let served = rig.dragOut.served

        #expect(failureCode(served.content(request(token, item: 1))) == .itemRepresentationUnavailable)
        #expect(served.content(request(token, item: 0)).map { _ in true } == .success(true))

        rig.dragOut.offerEnded(token)

        #expect(failureCode(served.content(request(token, item: 0))) == .itemRepresentationUnavailable)
    }

    @Test("a pull of a called-in promise waits until its source writes the named file, then serves it")
    func aPromisePullWaitsForItsFile() async throws {
        let photo = FakePromiseReceiver(names: ["IMG_0001.HEIC"])
        let (rig, items) = try deliveredRig(["public.heic"], receivers: [photo])
        let folder = try #require(photo.destination)
        let token = try rig.token()

        let pull = try await startPull(rig, token: token, item: 1)
        try photo.write("IMG_0001.HEIC", contents: Data(count: 1_234))

        #expect(await pull.value == .success(.tree(path: folder.appendingPathComponent("IMG_0001.HEIC").path)))
        // The taken offer's plain file is still served from where it is.
        let plain = try #require(items[0].fileURL)
        #expect(rig.dragOut.served.content(request(token, item: 0)) == .success(.tree(path: plain.path)))
    }

    @Test("a promise naming several files is served as its first, whatever order they land in")
    func aSeveralFilePromiseServesItsFirstFile() async throws {
        let burst = FakePromiseReceiver(names: ["IMG_0002.JPG", "IMG_0003.JPG"])
        let (rig, _) = try deliveredRig(["public.jpeg"], receivers: [burst])
        let folder = try #require(burst.destination)

        let pull = try await startPull(rig, token: try rig.token(), item: 1)
        try burst.write("IMG_0003.JPG", contents: Data(count: 3))
        try burst.write("IMG_0002.JPG", contents: Data(count: 2))

        #expect(await pull.value == .success(.tree(path: folder.appendingPathComponent("IMG_0002.JPG").path)))
        #expect(rig.peer.answers(to: takeID(1)).contains(.named(["IMG_0002.JPG"])))
    }

    @Test("a promise naming several files whose first fails is unavailable, whatever the others do")
    func aSeveralFilePromiseWithoutItsFirstFileIsUnavailable() async throws {
        let burst = FakePromiseReceiver(names: ["IMG_0002.JPG", "IMG_0003.JPG"])
        let (rig, _) = try deliveredRig(["public.jpeg"], receivers: [burst])

        let pull = try await startPull(rig, token: try rig.token(), item: 1)
        try burst.fail("IMG_0002.JPG")
        try burst.write("IMG_0003.JPG", contents: Data(count: 3))

        #expect(failureCode(await pull.value) == .itemRepresentationUnavailable)
    }

    @Test("a promise its source failed to write is unavailable")
    func aFailedPromiseIsUnavailable() async throws {
        let photo = FakePromiseReceiver(names: ["IMG_0001.HEIC"])
        let (rig, _) = try deliveredRig(["public.heic"], receivers: [photo])

        let pull = try await startPull(rig, token: try rig.token(), item: 1)
        try photo.fail("IMG_0001.HEIC")

        #expect(failureCode(await pull.value) == .itemRepresentationUnavailable)
    }

    @Test("a promised folder is served once its folder lands, and a file in its place is unavailable")
    func aPromisedFolderMustLandAsAFolder() async throws {
        let album = FakePromiseReceiver(names: ["Album"])
        let (rig, _) = try deliveredRig(["public.folder"], receivers: [album])
        let folder = try #require(album.destination)
        let pull = try await startPull(rig, token: try rig.token(), item: 1)
        try album.writeFolder("Album")
        #expect(await pull.value == .success(.tree(path: folder.appendingPathComponent("Album").path)))

        let flat = FakePromiseReceiver(names: ["Album"])
        let (other, _) = try deliveredRig(["public.folder"], receivers: [flat])
        let refused = try await startPull(other, token: try other.token(), item: 1)
        try flat.write("Album", contents: Data("not a folder".utf8))
        #expect(failureCode(await refused.value) == .itemRepresentationUnavailable)
    }

    @Test("the offer ending while a pull waits on its promise answers the pull unavailable")
    func anOfferEndingFailsAWaitingPull() async throws {
        let photo = FakePromiseReceiver(names: ["IMG_0001.HEIC"])
        let (rig, _) = try deliveredRig(["public.heic"], receivers: [photo])
        let token = try rig.token()

        let pull = try await startPull(rig, token: token, item: 1)
        rig.dragOut.offerEnded(token)

        #expect(failureCode(await pull.value) == .itemRepresentationUnavailable)
    }

    // MARK: - Letting the promises go

    @Test(
        "the taken offer ending removes the promises' folder once every file has landed, whichever comes first",
        arguments: [true, false])
    func theFolderGoesOnceTheOfferAndFilesAreDone(offerFirst: Bool) async throws {
        let photo = FakePromiseReceiver(names: ["IMG_0001.HEIC"])
        let (rig, _) = try deliveredRig(["public.heic"], receivers: [photo])
        let token = try rig.token()
        let folder = try #require(photo.destination)
        #expect(exists(folder))

        if offerFirst {
            rig.dragOut.offerEnded(token)
            #expect(exists(folder))
            try photo.write("IMG_0001.HEIC", contents: Data(count: 8))
        } else {
            // A pull waits for the landing, so once it is answered the file
            // has landed — and the open offer keeps the folder.
            let pull = try await startPull(rig, token: token, item: 1)
            try photo.write("IMG_0001.HEIC", contents: Data(count: 8))
            #expect(await pull.value == .success(.tree(path: folder.appendingPathComponent("IMG_0001.HEIC").path)))
            await rig.dragOut.promisesForTesting.waitForFolderRemovalsForTesting()
            #expect(exists(folder))
            rig.dragOut.offerEnded(token)
        }

        await rig.dragOut.promisesForTesting.waitForFolderRemovalsForTesting()
        #expect(!exists(folder))
    }

    @Test("the session peer stopping removes the promises' folder once its files have landed, telling the host nothing")
    func stopWaitsForTheFiles() async throws {
        let photo = FakePromiseReceiver(names: ["IMG_0001.HEIC"])
        let (rig, _) = try deliveredRig(["public.heic"], receivers: [photo])
        let folder = try #require(photo.destination)

        rig.dragOut.stop()
        #expect(exists(folder))
        let reported = rig.peer.events
        try photo.write("IMG_0001.HEIC", contents: Data(count: 8))

        await rig.dragOut.promisesForTesting.waitForFolderRemovalsForTesting()
        #expect(!exists(folder))
        #expect(rig.peer.events == reported)
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
        let catcher = GuestDragCatcher(
            peer: peer, makeSurface: { _ in FakeCatcherSurface() }, carry: { _, done in done(nil) })
        let icons = FakeGuestDragTypeIcons()
        let panel = GuestDragCatcherPanel(catcher: catcher, typeIcon: icons.icon(for:))
        panel.layOut(items: items, over: screen)
        let window = panel.windowForTesting
        window.contentView?.layoutSubtreeIfNeeded()
        return (window, icons)
    }

    private func hud(
        in window: NSPanel
    ) throws -> (box: NSVisualEffectView, icon: NSImageView, label: NSTextField, name: NSTextField) {
        let box = try #require(window.contentView?.subviews.compactMap { $0 as? NSVisualEffectView }.first)
        let icon = try #require(box.subviews.compactMap { $0 as? NSImageView }.first)
        let labels = box.subviews.compactMap { $0 as? NSTextField }
        try #require(labels.count == 2)
        return (box, icon, labels[0], labels[1])
    }

    @Test(
        "the catcher's box sits at the screen's center",
        arguments: [
            NSRect(x: 0, y: 0, width: 1440, height: 900),
            NSRect(x: 1440, y: -82, width: 1511, height: 983),
        ])
    func catcherHUDSitsAtTheCenter(screen: NSRect) throws {
        let (window, _) = catcherWindow(over: screen)
        let content = try #require(window.contentView)
        let (box, icon, label, name) = try hud(in: window)
        let middle = NSPoint(x: content.bounds.midX, y: content.bounds.midY)
        let halfPixel = 0.5 / window.backingScaleFactor

        #expect(label.stringValue == "Copy to Mac")
        #expect(box.material == .hudWindow)
        #expect(box.state == .active)
        #expect(abs(box.frame.midX - middle.x) <= halfPixel)
        #expect(abs(box.frame.midY - middle.y) <= halfPixel)
        #expect(icon.frame.size == NSSize(width: 128, height: 128))
        #expect(abs(box.bounds.maxY - icon.frame.maxY - 24) < 0.5)
        #expect(abs(icon.frame.minY - label.frame.maxY - 10) < 0.5)
        #expect(abs(label.frame.minY - name.frame.maxY - 4) < 0.5)
        #expect(abs(name.frame.minY - 24) < 0.5)
        for row in [icon, label, name] as [NSView] {
            #expect(abs(row.frame.midX - box.bounds.midX) <= halfPixel)
            #expect(row.frame.minX >= 23.5)
        }
    }

    @Test("the box names one item, or counts several")
    func catcherHUDNamesTheItems() throws {
        let one = catcherWindow(for: [try file("one.txt")])
        #expect(try hud(in: one.window).name.stringValue == "one.txt")
        #expect(one.icons.asked == [.plainText])
        #expect(try hud(in: one.window).icon.image === one.icons.images.last)

        let three = catcherWindow(for: [try file("one.txt"), try file("two.txt"), try file("three.txt")])
        #expect(try hud(in: three.window).name.stringValue == "3 items")
        #expect(three.icons.asked.isEmpty)

        let mixed = catcherWindow(items: [.file(try file("one.txt")), .promise(uti: "public.heic")])
        #expect(try hud(in: mixed.window).name.stringValue == "2 items")
        #expect(mixed.icons.asked.isEmpty)
    }

    @Test("the box shows one promise, which has no name yet, as its promised type and that type's description")
    func catcherHUDShowsOnePromise() throws {
        let one = catcherWindow(items: [.promise(uti: UTType.heic.identifier)])

        #expect(one.icons.asked == [.heic])
        #expect(try hud(in: one.window).icon.image === one.icons.images.last)
        #expect(try hud(in: one.window).name.stringValue == UTType.heic.localizedDescription)
    }

    @Test("a long name truncates in the middle at the name line's widest")
    func catcherHUDTruncatesALongName() throws {
        let name = String(repeating: "a rather long name for one dragged photo ", count: 4) + ".heic"
        let (window, _) = catcherWindow(for: [URL(fileURLWithPath: "/\(name)")])
        let (box, _, _, nameLabel) = try hud(in: window)

        #expect(abs(nameLabel.alignmentRect(forFrame: nameLabel.frame).width - 272) < 0.5)
        #expect(nameLabel.lineBreakMode == .byTruncatingMiddle)
        #expect(abs(box.frame.width - (272 + 48)) < 0.5)
    }

    @Test("a name wider than the icon but within the name line's widest shows whole, widening the box")
    func catcherHUDWidensForAName() throws {
        let (window, _) = catcherWindow(for: [URL(fileURLWithPath: "/Quarterly report draft, final v3.txt")])
        let (box, icon, _, nameLabel) = try hud(in: window)
        let whole = nameLabel.intrinsicContentSize.width
        try #require(whole > icon.frame.width && whole < 272)

        #expect(abs(nameLabel.alignmentRect(forFrame: nameLabel.frame).width - whole) < 0.5)
        #expect(abs(box.frame.width - (whole + 48)) < 0.5)
    }

    @Test(
        "the box's icon comes from the item's name alone, never the file",
        arguments: [
            ("photo.heic", false, UTType.heic), ("Folder", true, .folder), ("Tool.app", true, .applicationBundle),
            ("README", false, .data), ("archive.unknownext", false, UTType(filenameExtension: "unknownext") ?? .data),
        ])
    func iconComesFromTheName(name: String, isDirectory: Bool, type: UTType) throws {
        // Under a directory that does not exist: any read of the item finds
        // nothing, so a type that matches the name came from the name.
        let missing = URL(fileURLWithPath: "/\(UUID().uuidString)", isDirectory: true)
        let url = missing.appendingPathComponent(name, isDirectory: isDirectory)
        let (window, icons) = catcherWindow(for: [url])

        #expect(icons.asked == [type])
        #expect(try hud(in: window).name.stringValue == name)
    }

    @Test("a point on the box hit-tests to the catcher's own view")
    func catcherHUDTakesNoHits() throws {
        let (window, _) = catcherWindow()
        let content = try #require(window.contentView)
        let (box, _, label, _) = try hud(in: window)
        let labelCenter = box.convert(NSPoint(x: label.frame.midX, y: label.frame.midY), to: content)

        #expect(content.hitTest(NSPoint(x: box.frame.midX, y: box.frame.midY)) === content)
        #expect(content.hitTest(labelCenter) === content)
    }

    @Test("the box takes the guest's appearance, light or dark")
    func catcherHUDFollowsAppearance() throws {
        let (window, _) = catcherWindow()
        let (box, _, label, _) = try hud(in: window)
        #expect(box.appearance == nil)
        #expect(label.appearance == nil)
        #expect(label.textColor == .labelColor)

        func resolved(_ color: NSColor, in appearance: NSAppearance) -> NSColor? {
            var resolved: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                resolved = color.usingColorSpace(.sRGB)
            }
            return resolved
        }
        var seen: [NSColor] = []
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            window.appearance = appearance
            // Inside the effect view AppKit hands its content the vibrant
            // variant of the window's appearance.
            let modes: [NSAppearance.Name] = [.aqua, .darkAqua]
            #expect(box.effectiveAppearance.bestMatch(from: modes) == name)
            #expect(label.effectiveAppearance.bestMatch(from: modes) == name)
            let labelColor = try #require(resolved(label.textColor ?? .clear, in: label.effectiveAppearance))
            #expect(labelColor == resolved(.labelColor, in: label.effectiveAppearance))
            seen.append(labelColor)
        }
        #expect(seen[0] != seen[1])
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
