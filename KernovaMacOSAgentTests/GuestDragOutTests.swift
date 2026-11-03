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

/// The guest half of dragging files out of the VM display: which drags the
/// watcher offers and when it withdraws them, how a take is answered, how a
/// drag of promises is called in and offered again under its names, what the
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

        /// Where every drag's called-in promises land.
        var promiseFolders: URL {
            staging.root.url.appendingPathComponent(GuestDragPromises.stagingLabel, isDirectory: true)
        }

        /// A press that drags `items`, read by the first tick and resolved.
        func pressAndDrag(_ items: [FakePasteboardItem]) {
            input.press()
            input.drag(items)
            input.fireTick()
            input.deliverResolves()
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

    private func caught(_ urls: [URL]?, mask: NSDragOperation = [.copy, .move, .generic])
        -> GuestDragCatcher.Drag
    {
        caught(items: urls?.map(GuestDragItem.file), mask: mask)
    }

    private func caught(items: [GuestDragItem]?, mask: NSDragOperation = [.copy, .move, .generic])
        -> GuestDragCatcher.Drag
    {
        GuestDragCatcher.Drag(sourceMask: mask, items: items)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Which drags are offered

    @Test("a drag of plain files is offered under a fresh token, each item named by its file, not promised")
    func offersPlainFiles() throws {
        let rig = Rig()
        let first = try file("one.txt")
        let second = try file("two.txt")

        rig.pressAndDrag([fileItem(first), fileItem(second)])

        let token = try rig.token()
        #expect(token.count == 16)
        #expect(rig.peer.events == [.offered(token: token, names: ["one.txt", "two.txt"])])
        let representations = try #require(rig.peer.offers.first).items.map { $0.representations }
        #expect(representations.map(\.count) == [1, 1])
        #expect(representations.map { $0[0].storage } == [.file, .file])
        #expect(representations.map { $0[0].promised } == [false, false])
    }

    @Test("a folder is offered as one FOLDER item named by the folder")
    func offersAFolder() throws {
        let rig = Rig()
        let folder = try folder("Folder", files: ["inside.txt": "inside"])

        rig.pressAndDrag([fileItem(folder)])

        #expect(rig.peer.events == [.offered(token: try rig.token(), names: ["Folder"])])
        let representation = try #require(rig.peer.offers.first?.items.first?.representations.first)
        #expect(representation.storage == .folder)
        #expect(!representation.promised)
    }

    @Test("an item's promise wins over the derivative file URL it also carries")
    func aPromiseWinsOverItsFileURL() throws {
        let derivative = try file("derivative.jpeg")
        let pasteboard = FakeReadPasteboard()
        pasteboard.setItems([promiseItem("public.heic", alongside: derivative)])

        #expect(GuestDraggedItems.items(on: pasteboard) == [.promise(uti: "public.heic")])
    }

    @Test("a drag of files and promises is offered in order, each promise under a stand-in name, none called in")
    func offersAMixedDrag() throws {
        let rig = Rig()
        let plain = try file("plain.txt")

        rig.pressAndDrag([
            fileItem(plain), promiseItem("public.heic", alongside: try file("derivative.jpeg")),
            promiseItem("public.folder"),
        ])

        #expect(
            rig.peer.events == [
                .offered(token: try rig.token(), names: ["plain.txt", "Untitled.heic", "Untitled"])
            ])
        let representations = try #require(rig.peer.offers.first).items.compactMap(\.representations.first)
        #expect(representations.map(\.storage) == [.file, .file, .folder])
        #expect(representations.map(\.promised) == [false, true, true])
        #expect(rig.input.receiverReads == 0)
    }

    @Test("a promise that names no promised type keeps the whole drag in the guest")
    func anUntypedPromiseKeepsTheDrag() throws {
        let rig = Rig()

        rig.pressAndDrag([fileItem(try file("plain.txt")), promiseItem(nil, alongside: try file("promised.jpg"))])

        #expect(rig.input.resolveCount == 0)
        #expect(rig.peer.events.isEmpty)
    }

    @Test("any item without a file URL keeps the whole drag in the guest")
    func aNonFileItemKeepsTheDrag() throws {
        let rig = Rig()

        rig.pressAndDrag([
            fileItem(try file("plain.txt")),
            FakePasteboardItem([(type: .string, data: Data("just text".utf8))]),
        ])

        #expect(rig.input.resolveCount == 0)
        #expect(rig.peer.events.isEmpty)
    }

    @Test("an item that cannot be read keeps the whole drag in the guest, and is not walked again")
    func anUnreadableItemKeepsTheDrag() throws {
        let rig = Rig()
        let gone = scratch.url.appendingPathComponent("gone.txt")

        rig.pressAndDrag([fileItem(try file("plain.txt")), fileItem(gone)])
        // The press is re-read every tick, but the same items are not resolved
        // a second time.
        rig.input.fireTick()

        #expect(rig.input.resolveCount == 1)
        #expect(rig.input.pendingResolveCount == 0)
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
        #expect(rig.input.resolveCount == 0)

        rig.input.drag([fileItem(try file("late.txt"))])
        rig.input.fireTick()
        rig.input.deliverResolves()

        #expect(rig.peer.events == [.offered(token: try rig.token(), names: ["late.txt"])])
    }

    @Test("the live input offers a folder without reading inside it")
    func theLiveOfferReadsNoFolder() async throws {
        let tree = try folder("Tree", files: ["a.txt": "alpha", "b.txt": "beta"])
        let input = SystemGuestDragInput()

        let intake = await withCheckedContinuation { continuation in
            input.resolveFiles([tree]) { continuation.resume(returning: $0) }
        }

        let representation = try #require(intake.representations.first)
        #expect(representation.isDirectory)
        #expect(representation.byteCount == 0)
    }

    // MARK: - The baseline

    @Test("what was already on the drag pasteboard when watching started is not a drag")
    func whatWasStandingIsNotADrag() throws {
        let rig = Rig(usable: false)
        rig.input.drag([fileItem(try file("old.txt"))])
        rig.dragOut.setUsable(true)

        rig.input.press()
        rig.input.fireTick()

        #expect(rig.input.resolveCount == 0)
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
        #expect(rig.input.resolveCount == 1)
        #expect(rig.peer.events == [.offered(token: token, names: ["dragged.txt"]), .withdrew(token: token)])
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
        rig.input.deliverResolves()

        #expect(rig.peer.events == [.offered(token: try rig.token(), names: ["quick.txt"])])
    }

    // MARK: - Stale results and changed items

    @Test("a resolve that returns after its press ended offers nothing")
    func aResolveAfterThePressEndedIsDropped() throws {
        let rig = Rig()
        rig.input.press()
        rig.input.drag([fileItem(try file("slow.txt"))])
        rig.input.fireTick()
        rig.releaseAndTick()

        rig.input.deliverResolves()

        #expect(rig.peer.events.isEmpty)
    }

    @Test("a resolve that returns once the button is up offers nothing, before any tick sees it")
    func aResolveAfterTheButtonCameUpIsDropped() throws {
        let rig = Rig()
        rig.input.press()
        rig.input.drag([fileItem(try file("slow.txt"))])
        rig.input.fireTick()
        rig.input.release()

        rig.input.deliverResolves()

        #expect(rig.peer.events.isEmpty)
    }

    @Test("a resolve that returns into a newer press offers nothing")
    func aResolveIntoANewerPressIsDropped() throws {
        let rig = Rig()
        rig.input.press()
        rig.input.drag([fileItem(try file("slow.txt"))])
        rig.input.fireTick()
        // A release and a new press both inside one tick interval.
        rig.input.press()

        rig.input.deliverResolves()

        #expect(rig.peer.events.isEmpty)
    }

    @Test("changed items withdraw the offer and offer the new ones under a new token")
    func changedItemsReplaceTheOffer() throws {
        let rig = Rig()
        rig.pressAndDrag([fileItem(try file("first.txt"))])

        rig.input.drag([fileItem(try file("second.txt"))])
        rig.input.fireTick()
        rig.input.deliverResolves()

        let first = try rig.token(0)
        let second = try rig.token(1)
        #expect(first != second)
        #expect(
            rig.peer.events == [
                .offered(token: first, names: ["first.txt"]), .withdrew(token: first),
                .offered(token: second, names: ["second.txt"]),
            ])
    }

    @Test("an offered drag is read again only when the count moves, and the same items keep it")
    func theSameItemsKeepTheOffer() throws {
        let rig = Rig()
        let url = try file("same.txt")
        rig.pressAndDrag([fileItem(url)])
        rig.input.fireTick()
        rig.input.drag([fileItem(url)])
        rig.input.fireTick()

        #expect(rig.input.resolveCount == 1)
        #expect(rig.peer.events == [.offered(token: try rig.token(), names: ["same.txt"])])
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

        #expect(rig.peer.events == [.offered(token: try rig.token(), names: ["ended.txt"])])
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

    @Test("a take of plain files arms the catcher and is answered TAKEN once the catcher is the drag's target")
    func aTakeIsTakenOnceTargeted() throws {
        let urls = [try file("one.txt"), try file("two.txt")]
        let rig = Rig()
        rig.pressAndDrag(urls.map(fileItem))

        let id = try rig.take(1)

        #expect(rig.surface.isShown)
        #expect(rig.surface.shownItems == urls.map(GuestDragItem.file))
        #expect(rig.peer.answers(to: id).isEmpty)

        #expect(rig.dragOut.catcherForTesting.draggingEntered(caught(urls)) == .copy)
        #expect(rig.peer.answers(to: id) == [.taken])
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
        #expect(rig.peer.answers(to: first).isEmpty)
        #expect(rig.peer.answers(to: second) == [.refused(.dragNotCurrent)])
    }

    @Test("a take while not watching is refused DRAG_NOT_CURRENT")
    func aTakeWhileNotWatchingFails() {
        let rig = Rig(usable: false)

        rig.dragOut.take(takeID(1), token: Data(repeating: 1, count: 16))

        #expect(rig.peer.answers(to: takeID(1)) == [.refused(.dragNotCurrent)])
        #expect(rig.surface.showCount == 0)
    }

    // MARK: - The catcher's steps

    /// A rig whose drag of `urls` the host has taken as take 1.
    private func takenRig(_ urls: [URL]) throws -> Rig {
        let rig = Rig()
        rig.pressAndDrag(urls.map(fileItem))
        try rig.take(1)
        return rig
    }

    @Test("a taken drag is answered once, caught on the drop, and comes down at the end, never withdrawn")
    func theTakeSteps() throws {
        let urls = [try file("one.txt"), try file("two.txt")]
        let rig = try takenRig(urls)
        let catcher = rig.dragOut.catcherForTesting

        #expect(catcher.draggingEntered(caught(urls)) == .copy)
        #expect(catcher.draggingUpdated(caught(urls)) == .copy)
        #expect(catcher.performDragOperation())
        // The drop's release is the host's; the press ending before the drop
        // concludes leaves the surface for the conclusion to take down.
        rig.releaseAndTick()
        #expect(rig.surface.isShown)
        catcher.concludeDragOperation()

        #expect(rig.peer.answers(to: takeID(1)) == [.taken])
        #expect(!rig.surface.isShown)
        #expect(!rig.peer.events.contains(.withdrew(token: try rig.token())))
    }

    @Test("re-entering after leaving answers nothing more")
    func reEntryAnswersNothingMore() throws {
        let urls = [try file("one.txt")]
        let rig = try takenRig(urls)
        let catcher = rig.dragOut.catcherForTesting

        _ = catcher.draggingEntered(caught(urls))
        catcher.draggingExited()
        #expect(catcher.draggingEntered(caught(urls)) == .copy)

        #expect(rig.peer.answers(to: takeID(1)) == [.taken])
    }

    @Test("a drag holding other items is refused DRAG_NOT_CURRENT and takes the surface down")
    func otherItemsAreRefused() throws {
        let rig = try takenRig([try file("taken.txt")])
        let catcher = rig.dragOut.catcherForTesting

        #expect(catcher.draggingEntered(caught([try file("other.txt")])) == [])

        #expect(rig.peer.answers(to: takeID(1)) == [.refused(.dragNotCurrent)])
        #expect(!rig.surface.isShown)
    }

    @Test("a drag that carries no plain file URLs is refused")
    func aNonFileDragIsRefused() throws {
        let rig = try takenRig([try file("taken.txt")])
        let catcher = rig.dragOut.catcherForTesting

        #expect(catcher.draggingUpdated(caught(nil)) == [])

        #expect(rig.peer.answers(to: takeID(1)) == [.refused(.dragNotCurrent)])
        #expect(!rig.surface.isShown)
    }

    @Test("a source that does not allow a copy is refused, never answered move or generic")
    func aSourceWithoutCopyIsRefused() throws {
        let urls = [try file("taken.txt")]
        let rig = try takenRig(urls)
        let catcher = rig.dragOut.catcherForTesting

        #expect(catcher.draggingEntered(caught(urls, mask: [.move, .generic, .delete])) == [])

        #expect(rig.peer.answers(to: takeID(1)) == [.refused(.dragNotCurrent)])
        #expect(!rig.surface.isShown)
        // Nothing is left armed to answer a later callback with anything at all.
        #expect(catcher.draggingUpdated(caught(urls)) == [])
        #expect(!catcher.performDragOperation())
    }

    @Test(
        "a refusal after TAKEN answers nothing more and keeps the surface up to refuse the drop",
        arguments: [false, true])
    func aRefusalAfterTakenKeepsTheSurface(otherItems: Bool) throws {
        let urls = [try file("taken.txt")]
        let rig = try takenRig(urls)
        let catcher = rig.dragOut.catcherForTesting
        #expect(catcher.draggingEntered(caught(urls)) == .copy)

        let refused =
            otherItems ? caught([try file("other.txt")]) : caught(urls, mask: [.move, .generic])
        #expect(catcher.draggingUpdated(refused) == [])

        #expect(rig.surface.isShown)
        // A release the host injected drops here and is refused, so nothing
        // moves.
        #expect(catcher.draggingUpdated(caught(urls)) == [])
        #expect(!catcher.performDragOperation())
        // The press ending under the surface leaves it for the drag's end.
        rig.releaseAndTick()
        #expect(rig.surface.isShown)

        catcher.draggingEnded()

        #expect(!rig.surface.isShown)
        #expect(rig.peer.answers(to: takeID(1)) == [.taken])
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

    // MARK: - Every path that takes the surface down

    @Test("the drag ending before it reached the catcher refuses the take DRAG_PRESS_OVER")
    func draggingEndedBeforeTheCatcherRefuses() throws {
        let rig = try takenRig([try file("one.txt")])

        rig.dragOut.catcherForTesting.draggingEnded()

        #expect(!rig.surface.isShown)
        #expect(rig.peer.answers(to: takeID(1)) == [.refused(.dragPressOver)])
    }

    @Test("the drag ending without a drop after TAKEN takes the surface down, answering nothing more")
    func draggingEndedAfterTakenIsQuiet() throws {
        let urls = [try file("one.txt")]
        let rig = try takenRig(urls)
        let catcher = rig.dragOut.catcherForTesting
        _ = catcher.draggingEntered(caught(urls))

        catcher.draggingEnded()

        #expect(!rig.surface.isShown)
        #expect(rig.peer.answers(to: takeID(1)) == [.taken])
    }

    @Test("the drag ending after the drop takes the surface down quietly")
    func draggingEndedAfterTheDropIsQuiet() throws {
        let urls = [try file("one.txt")]
        let rig = try takenRig(urls)
        let catcher = rig.dragOut.catcherForTesting
        _ = catcher.draggingEntered(caught(urls))
        _ = catcher.performDragOperation()

        catcher.draggingEnded()

        #expect(!rig.surface.isShown)
        #expect(rig.peer.answers(to: takeID(1)) == [.taken])
    }

    @Test("the offer ending before TAKEN takes the surface down and answers nothing")
    func anOfferEndedBeforeTakenTakesItDown() throws {
        let urls = [try file("one.txt")]
        let rig = try takenRig(urls)

        rig.dragOut.offerEnded(try rig.token())

        #expect(!rig.surface.isShown)
        #expect(rig.peer.answerCount == 0)
        // Nothing is left armed for a late callback to answer.
        #expect(rig.dragOut.catcherForTesting.draggingEntered(caught(urls)) == [])
        #expect(rig.peer.answerCount == 0)
    }

    @Test("the offer ending after TAKEN leaves the surface up until the drag ends", arguments: [true, false])
    func anOfferEndedAfterTakenLeavesItUp(dropped: Bool) throws {
        let urls = [try file("one.txt")]
        let rig = try takenRig(urls)
        let catcher = rig.dragOut.catcherForTesting
        #expect(catcher.draggingEntered(caught(urls)) == .copy)

        rig.dragOut.offerEnded(try rig.token())

        #expect(rig.surface.isShown)
        // The host's release may already be on its way: it lands here.
        #expect(catcher.draggingUpdated(caught(urls)) == .copy)
        if dropped {
            #expect(catcher.performDragOperation())
            catcher.concludeDragOperation()
        } else {
            catcher.draggingEnded()
        }

        #expect(!rig.surface.isShown)
        #expect(rig.peer.answers(to: takeID(1)) == [.taken])
    }

    @Test("another offer ending leaves the surface up")
    func anotherOfferEndingLeavesItUp() throws {
        let rig = try takenRig([try file("one.txt")])

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
        #expect(rig.peer.answers(to: takeID(1)) == [.refused(.dragPressOver)])
    }

    @Test("the press ending after the drag left the surface takes it down")
    func pressEndAfterExitTakesItDown() throws {
        let urls = [try file("one.txt")]
        let rig = try takenRig(urls)
        let catcher = rig.dragOut.catcherForTesting
        _ = catcher.draggingEntered(caught(urls))
        catcher.draggingExited()

        rig.releaseAndTick()

        #expect(!rig.surface.isShown)
        #expect(rig.peer.answers(to: takeID(1)) == [.taken])
    }

    @Test("a click on the catcher before the drag reached it refuses the take DRAG_PRESS_OVER")
    func aClickBeforeTheDragRefuses() throws {
        let rig = try takenRig([try file("one.txt")])

        rig.dragOut.catcherForTesting.surfaceClicked()

        #expect(!rig.surface.isShown)
        #expect(rig.peer.answers(to: takeID(1)) == [.refused(.dragPressOver)])
    }

    @Test("a click on a catcher that outlived its drag takes it down, and the next take arms afresh")
    func aClickTakesAStrandedCatcherDown() throws {
        let urls = [try file("one.txt")]
        let rig = try takenRig(urls)
        let catcher = rig.dragOut.catcherForTesting
        // Entered, so its press ending leaves it waiting for the drop.
        _ = catcher.draggingEntered(caught(urls))
        rig.releaseAndTick()
        #expect(rig.surface.isShown)

        catcher.surfaceClicked()

        #expect(!rig.surface.isShown)
        #expect(rig.peer.answers(to: takeID(1)) == [.taken])
        // The next press's take arms as the first did.
        let next = [try file("two.txt")]
        rig.pressAndDrag(next.map(fileItem))
        let id = try rig.take(2, offer: 1)
        #expect(rig.surface.isShown)
        #expect(catcher.draggingEntered(caught(next)) == .copy)
        #expect(rig.peer.answers(to: id) == [.taken])
    }

    @Test("a click on a catcher that refused after TAKEN takes it down without another answer")
    func aClickTakesARefusingCatcherDown() throws {
        let urls = [try file("one.txt")]
        let rig = try takenRig(urls)
        let catcher = rig.dragOut.catcherForTesting
        _ = catcher.draggingEntered(caught(urls))
        _ = catcher.draggingUpdated(caught(urls, mask: [.move]))

        catcher.surfaceClicked()

        #expect(!rig.surface.isShown)
        #expect(rig.peer.answers(to: takeID(1)) == [.taken])
    }

    // MARK: - Calling promises in

    /// A rig pressing a drag of a plain file and then a promise of each of
    /// `promised`, whose pasteboard holds `receivers`.
    private func promiseRig(
        _ promised: [String], receivers: [FakePromiseReceiver]
    ) throws -> (rig: Rig, items: [GuestDragItem]) {
        let plain = try file("plain.txt")
        let rig = Rig()
        rig.input.receivers = receivers
        rig.pressAndDrag([fileItem(plain)] + promised.map { promiseItem($0) })
        let items = [GuestDragItem.file(plain)] + promised.map { GuestDragItem.promise(uti: $0) }
        return (rig, items)
    }

    /// A promise rig whose stand-in offer the host took as take 1 and the
    /// core then ended, as it ends a withdrawn offer: the drag is offered
    /// again, named.
    private func calledInRig(
        _ promised: [String], receivers: [FakePromiseReceiver]
    ) throws -> (rig: Rig, items: [GuestDragItem]) {
        let (rig, items) = try promiseRig(promised, receivers: receivers)
        try rig.take(1)
        rig.dragOut.offerEnded(try rig.token(0))
        return (rig, items)
    }

    @Test("a take of a promise drag calls its promises in, withdraws the stand-in offer and offers it again named")
    func aTakeCallsThePromisesIn() throws {
        let photo = FakePromiseReceiver(names: ["IMG_0001.HEIC"])
        let burst = FakePromiseReceiver(names: ["IMG_0002.JPG", "IMG_0003.JPG"])
        let (rig, _) = try promiseRig(["public.heic", "public.jpeg"], receivers: [photo, burst])
        let standIn = try rig.token(0)

        let id = try rig.take(1)

        let folder = try #require(photo.destination)
        #expect(burst.destination == folder)
        #expect(folder.deletingLastPathComponent().path == rig.promiseFolders.path)
        #expect(exists(folder))
        let named = try rig.token(1)
        #expect(named != standIn)
        // A receiver naming several files goes out under its first.
        #expect(
            rig.peer.events == [
                .offered(token: standIn, names: ["plain.txt", "Untitled.heic", "Untitled.jpeg"]),
                .withdrew(token: standIn),
                .offered(token: named, names: ["plain.txt", "IMG_0001.HEIC", "IMG_0002.JPG"]),
            ])
        let representations = try #require(rig.peer.offers.last).items.compactMap(\.representations.first)
        #expect(representations.map(\.promised) == [false, true, true])
        // The withdrawal refuses the take; this side answers nothing, and puts
        // nothing up.
        #expect(rig.peer.answers(to: id).isEmpty)
        #expect(rig.surface.showCount == 0)
    }

    @Test("a take of the named offer arms the catcher and is TAKEN; a take of the stand-in is not current")
    func aTakeOfTheNamedOfferArms() throws {
        let photo = FakePromiseReceiver(names: ["IMG_0001.HEIC"])
        let (rig, items) = try calledInRig(["public.heic"], receivers: [photo])

        let late = takeID(3)
        rig.dragOut.take(late, token: try rig.token(0))
        #expect(rig.peer.answers(to: late) == [.refused(.dragNotCurrent)])

        let id = try rig.take(2, offer: 1)

        #expect(rig.surface.shownItems == items)
        #expect(rig.dragOut.catcherForTesting.draggingEntered(caught(items: items)) == .copy)
        #expect(rig.peer.answers(to: id) == [.taken])
        // Called in once: the named offer's take arms, and calls in nothing more.
        #expect(rig.input.receiverReads == 1)
        #expect(rig.peer.offers.count == 2)
    }

    @Test("a promise naming no file as it is called in keeps the drag in the guest, refusing the take")
    func aPromiseNamingNothingRefusesTheTake() async throws {
        let unnamed = FakePromiseReceiver(names: [])
        let (rig, _) = try promiseRig(["public.heic"], receivers: [unnamed])

        let id = try rig.take(1)

        #expect(unnamed.wasCalledIn)
        #expect(rig.peer.answers(to: id) == [.refused(.dragNotCurrent)])
        #expect(rig.peer.offers.count == 1)
        #expect(!rig.peer.events.contains(.withdrew(token: try rig.token())))
        #expect(rig.surface.showCount == 0)
        // Its source may still write, so the folder goes only once it has.
        let folder = try #require(unnamed.destination)
        rig.dragOut.promisesForTesting.waitForFolderRemovalsForTesting()
        #expect(exists(folder))
        try unnamed.write("IMG_0001.HEIC", contents: Data(count: 8))
        await drainMainQueue()
        rig.dragOut.promisesForTesting.waitForFolderRemovalsForTesting()
        #expect(!exists(folder))
    }

    @Test("a drag carrying another count of promises than its promised items calls none in")
    func aPromiseCountMismatchCallsNothingIn() throws {
        let only = FakePromiseReceiver(names: ["IMG_0001.HEIC"])
        let (rig, _) = try promiseRig(["public.heic", "public.jpeg"], receivers: [only])

        let id = try rig.take(1)

        #expect(!only.wasCalledIn)
        #expect(rig.peer.answers(to: id) == [.refused(.dragNotCurrent)])
        #expect(rig.peer.offers.count == 1)
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

    @Test("a pull of a plain file is served from the file's own folder, by its name")
    func aFileIsServedInPlace() throws {
        let rig = Rig()
        let one = try file("one.txt")
        let tree = try folder("Tree", files: ["a.txt": "alpha"])
        rig.pressAndDrag([fileItem(one), fileItem(tree)])
        let token = try rig.token()
        let served = rig.dragOut.served

        #expect(
            served.content(request(token, item: 0))
                == .success(.tree(directory: one.deletingLastPathComponent().path, name: Array("one.txt".utf8))))
        #expect(
            served.content(request(token, item: 1))
                == .success(.tree(directory: tree.deletingLastPathComponent().path, name: Array("Tree".utf8))))
        #expect(failureCode(served.content(request(token, item: 2))) == .itemRepresentationUnavailable)
        #expect(
            failureCode(served.content(request(Data(repeating: 3, count: 16), item: 0)))
                == .itemRepresentationUnavailable)
    }

    @Test("a promise not called in serves nothing, and an ended offer serves nothing more")
    func anUncalledPromiseServesNothing() throws {
        let (rig, _) = try promiseRig(["public.heic"], receivers: [FakePromiseReceiver(names: ["IMG_0001.HEIC"])])
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
        let (rig, _) = try calledInRig(["public.heic"], receivers: [photo])
        let folder = try #require(photo.destination)

        let pull = try await startPull(rig, token: try rig.token(1), item: 1)
        try photo.write("IMG_0001.HEIC", contents: Data(count: 1_234))

        #expect(await pull.value == .success(.tree(directory: folder.path, name: Array("IMG_0001.HEIC".utf8))))
    }

    @Test("a receiver naming several files serves the one it was named by, whatever order they land in")
    func aSeveralFileReceiverServesItsNamedFile() async throws {
        let burst = FakePromiseReceiver(names: ["IMG_0002.JPG", "IMG_0003.JPG"])
        let (rig, _) = try calledInRig(["public.jpeg"], receivers: [burst])
        let folder = try #require(burst.destination)

        let pull = try await startPull(rig, token: try rig.token(1), item: 1)
        try burst.write("IMG_0003.JPG", contents: Data(count: 3))
        try burst.write("IMG_0002.JPG", contents: Data(count: 2))

        #expect(await pull.value == .success(.tree(directory: folder.path, name: Array("IMG_0002.JPG".utf8))))
    }

    @Test("a receiver naming several files whose named file never lands is unavailable once its callbacks are in")
    func aSeveralFileReceiverWithoutItsNamedFileIsUnavailable() async throws {
        let burst = FakePromiseReceiver(names: ["IMG_0002.JPG", "IMG_0003.JPG"])
        let (rig, _) = try calledInRig(["public.jpeg"], receivers: [burst])

        let pull = try await startPull(rig, token: try rig.token(1), item: 1)
        // An error from a receiver naming several files pairs with none of
        // them, so it settles nothing by itself.
        try burst.fail("IMG_0002.JPG")
        try burst.write("IMG_0003.JPG", contents: Data(count: 3))

        #expect(failureCode(await pull.value) == .itemRepresentationUnavailable)
    }

    @Test("a promise its source failed to write is unavailable")
    func aFailedPromiseIsUnavailable() async throws {
        let photo = FakePromiseReceiver(names: ["IMG_0001.HEIC"])
        let (rig, _) = try calledInRig(["public.heic"], receivers: [photo])

        let pull = try await startPull(rig, token: try rig.token(1), item: 1)
        try photo.fail("IMG_0001.HEIC")

        #expect(failureCode(await pull.value) == .itemRepresentationUnavailable)
    }

    @Test("a promised folder is served once its folder lands, and a file in its place is unavailable")
    func aPromisedFolderMustLandAsAFolder() async throws {
        let album = FakePromiseReceiver(names: ["Album"])
        let (rig, _) = try calledInRig(["public.folder"], receivers: [album])
        let folder = try #require(album.destination)
        let pull = try await startPull(rig, token: try rig.token(1), item: 1)
        try album.writeFolder("Album")
        #expect(await pull.value == .success(.tree(directory: folder.path, name: Array("Album".utf8))))

        let flat = FakePromiseReceiver(names: ["Album"])
        let (other, _) = try calledInRig(["public.folder"], receivers: [flat])
        let refused = try await startPull(other, token: try other.token(1), item: 1)
        try flat.write("Album", contents: Data("not a folder".utf8))
        #expect(failureCode(await refused.value) == .itemRepresentationUnavailable)
    }

    @Test("the offer ending while a pull waits on its promise answers the pull unavailable")
    func anOfferEndingFailsAWaitingPull() async throws {
        let photo = FakePromiseReceiver(names: ["IMG_0001.HEIC"])
        let (rig, _) = try calledInRig(["public.heic"], receivers: [photo])
        let named = try rig.token(1)

        let pull = try await startPull(rig, token: named, item: 1)
        rig.dragOut.offerEnded(named)

        #expect(failureCode(await pull.value) == .itemRepresentationUnavailable)
    }

    // MARK: - Letting the promises go

    @Test(
        "the named offer ending removes the promises' folder once every read is in, whichever comes first",
        arguments: [true, false])
    func theFolderGoesOnceTheOfferAndReadsAreDone(offerFirst: Bool) async throws {
        let photo = FakePromiseReceiver(names: ["IMG_0001.HEIC"])
        let (rig, _) = try calledInRig(["public.heic"], receivers: [photo])
        let named = try rig.token(1)
        let folder = try #require(photo.destination)
        // The stand-in offer ending kept the folder: the named one still serves.
        #expect(exists(folder))

        if offerFirst {
            rig.dragOut.offerEnded(named)
            rig.dragOut.promisesForTesting.waitForFolderRemovalsForTesting()
            #expect(exists(folder))
            try photo.write("IMG_0001.HEIC", contents: Data(count: 8))
            await drainMainQueue()
        } else {
            try photo.write("IMG_0001.HEIC", contents: Data(count: 8))
            await drainMainQueue()
            rig.dragOut.promisesForTesting.waitForFolderRemovalsForTesting()
            #expect(exists(folder))
            rig.dragOut.offerEnded(named)
        }

        rig.dragOut.promisesForTesting.waitForFolderRemovalsForTesting()
        #expect(!exists(folder))
    }

    @Test("the session peer stopping removes the promises' folder once its reads are in, telling the host nothing")
    func stopWaitsForTheReads() async throws {
        let photo = FakePromiseReceiver(names: ["IMG_0001.HEIC"])
        let (rig, _) = try calledInRig(["public.heic"], receivers: [photo])
        let folder = try #require(photo.destination)

        rig.dragOut.stop()
        rig.dragOut.promisesForTesting.waitForFolderRemovalsForTesting()
        #expect(exists(folder))
        let reported = rig.peer.events
        try photo.write("IMG_0001.HEIC", contents: Data(count: 8))
        await drainMainQueue()

        rig.dragOut.promisesForTesting.waitForFolderRemovalsForTesting()
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
        let catcher = GuestDragCatcher(peer: peer, makeSurface: { _ in FakeCatcherSurface() })
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
