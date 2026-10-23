import AppKit
import Foundation
import KernovaKit
import KernovaSynchronization
import KernovaTestSupport
import Testing
import UniformTypeIdentifiers

/// The guest half of dragging files out of the VM display: which drags the
/// watcher offers and when it withdraws them, how a take is validated, and
/// every step and lifetime path of the catcher — with the event stream, the
/// drag pasteboard and the catcher's window all faked.
@Suite("GuestDragOut", .caseScoped)
@MainActor
struct GuestDragOutTests {
    private let scratch = TestScratchDirectory(prefix: "GuestDragOutTests")

    /// A drag-out over fakes, watching.
    @MainActor
    private struct Rig {
        let input = FakeGuestDragInput()
        let surface = FakeCatcherSurface()
        let peer = FakeGuestDragPeer()
        let dragOut: GuestDragOut

        init(watching: Bool = true) {
            dragOut = GuestDragOut(peer: peer, system: .faked(input: input, surface: surface))
            dragOut.setWatching(watching)
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
    }

    private func file(_ name: String, _ contents: String = "bytes") throws -> URL {
        let directory = scratch.url.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func caught(_ urls: [URL]?, mask: NSDragOperation = [.copy, .move, .generic])
        -> GuestDragCatcher.Drag
    {
        GuestDragCatcher.Drag(sourceMask: mask, fileURLs: urls)
    }

    // MARK: - Which drags are offered

    @Test("a drag of plain files is offered with every item, in order")
    func offersPlainFiles() throws {
        let rig = Rig()
        let first = try file("one.txt")
        let second = try file("two.txt")

        rig.pressAndDrag([fileItem(first), fileItem(second)])

        #expect(rig.peer.events == [.offered(generation: 1, filenames: ["one.txt", "two.txt"])])
    }

    @Test("a folder is offered as one item")
    func offersAFolder() throws {
        let rig = Rig()
        let folder = scratch.url.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: folder.appendingPathComponent("inside.txt"))

        rig.pressAndDrag([fileItem(folder)])

        #expect(rig.peer.events == [.offered(generation: 1, filenames: ["Folder"])])
    }

    @Test("any item that is a file promise keeps the whole drag in the guest")
    func aPromiseKeepsTheDrag() throws {
        let rig = Rig()

        rig.pressAndDrag([fileItem(try file("plain.txt")), promisedFileItem(try file("promised.jpg"))])

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
        let count = ClipboardContent.maxOfferableRepresentations + 1
        let urls = (0..<count).map { URL(fileURLWithPath: "/tmp/item-\($0)") }
        let representations = (0..<count).map { _ in
            ClipboardContent.Representation(uti: "public.data", data: Data([0]))
        }

        let overLimit = ClipboardPasteboardReader.FileIntake(
            representations: representations, skipped: 0)
        #expect(GuestDraggedFiles.offerableContent(overLimit, resolvedFrom: urls) == nil)

        let atLimit = ClipboardPasteboardReader.FileIntake(
            representations: Array(representations.dropLast()), skipped: 0)
        #expect(
            GuestDraggedFiles.offerableContent(atLimit, resolvedFrom: Array(urls.dropLast())) != nil)
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

        #expect(rig.peer.events == [.offered(generation: 1, filenames: ["late.txt"])])
    }

    // MARK: - The baseline

    @Test("what was already on the drag pasteboard when watching started is not a drag")
    func whatWasStandingIsNotADrag() throws {
        let rig = Rig(watching: false)
        rig.input.drag([fileItem(try file("old.txt"))])
        rig.dragOut.setWatching(true)

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

        #expect(rig.input.resolveCount == 1)
        #expect(
            rig.peer.events == [
                .offered(generation: 1, filenames: ["dragged.txt"]), .withdrew(generation: 1),
            ])
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

        #expect(rig.peer.events == [.offered(generation: 1, filenames: ["quick.txt"])])
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

    @Test("changed items withdraw the offer and offer the new ones")
    func changedItemsReplaceTheOffer() throws {
        let rig = Rig()
        rig.pressAndDrag([fileItem(try file("first.txt"))])

        rig.input.drag([fileItem(try file("second.txt"))])
        rig.input.fireTick()
        rig.input.deliverResolves()

        #expect(
            rig.peer.events == [
                .offered(generation: 1, filenames: ["first.txt"]), .withdrew(generation: 1),
                .offered(generation: 2, filenames: ["second.txt"]),
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
        #expect(rig.peer.events == [.offered(generation: 1, filenames: ["same.txt"])])
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

        #expect(rig.peer.events.last == .withdrew(generation: 1))
        #expect(!rig.input.isTicking)
    }

    @Test("a taken offer is never withdrawn when its press ends")
    func aTakenOfferIsNotWithdrawn() throws {
        let rig = Rig()
        rig.pressAndDrag([fileItem(try file("taken.txt"))])
        rig.dragOut.take(generation: 1)

        rig.releaseAndTick()

        #expect(!rig.peer.events.contains(.withdrew(generation: 1)))
    }

    @Test("an offer the host completed is neither withdrawn nor offered again in its press")
    func aCompletedOfferIsLeftAlone() throws {
        let rig = Rig()
        let url = try file("completed.txt")
        rig.pressAndDrag([fileItem(url)])
        rig.dragOut.complete(generation: 1)

        rig.input.drag([fileItem(url)])
        rig.input.fireTick()
        rig.releaseAndTick()

        #expect(rig.peer.events == [.offered(generation: 1, filenames: ["completed.txt"])])
    }

    @Test("stopping withdraws an untaken offer, drops the monitor and ends the App Nap hold")
    func stoppingReleasesEverything() throws {
        let rig = Rig()
        #expect(rig.input.isHoldingActivity)
        #expect(rig.input.isObservingPresses)
        rig.pressAndDrag([fileItem(try file("dragged.txt"))])

        rig.dragOut.setWatching(false)

        #expect(rig.peer.events.last == .withdrew(generation: 1))
        #expect(!rig.input.isHoldingActivity)
        #expect(!rig.input.isObservingPresses)
        #expect(!rig.input.isTicking)
    }

    // MARK: - Folder sizes

    private func folder(_ name: String, files: [String: String]) throws -> URL {
        let url = scratch.url.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (file, contents) in files {
            try Data(contents.utf8).write(to: url.appendingPathComponent(file))
        }
        return url
    }

    @Test("the live input offers a folder without reading inside it, and measures it only when asked")
    func theLiveOfferReadsNoFolder() async throws {
        let tree = try folder("Tree", files: ["a.txt": "alpha", "b.txt": "beta"])
        let measured = Locked<[URL]>([])
        let input = SystemGuestDragInput(measureFolder: { url in
            measured.withLock { $0.append(url) }
            return 1_234
        })

        let intake = await withCheckedContinuation { continuation in
            input.resolveFiles([tree]) { continuation.resume(returning: $0) }
        }

        let representation = try #require(intake.representations.first)
        #expect(representation.isDirectory)
        #expect(representation.byteCount == 0)
        #expect(measured.withLock { $0 }.isEmpty)

        let sizes = await withCheckedContinuation { continuation in
            input.measureFolders([0: tree]) { continuation.resume(returning: $0) }
        }
        #expect(sizes == [0: 1_234])
        #expect(measured.withLock { $0 } == [tree])
    }

    @Test("a drag carrying a folder measures it once the take is accepted, and sends its size after armed")
    func folderSizesFollowTheTake() throws {
        let rig = Rig()
        let tree = try folder("Tree", files: ["a.txt": "alpha"])
        rig.pressAndDrag([fileItem(try file("loose.txt")), fileItem(tree)])
        #expect(rig.input.pendingMeasureFolders.isEmpty)

        rig.dragOut.take(generation: 1)

        #expect(rig.input.pendingMeasureFolders.map { $0.keys.sorted() } == [[1]])
        rig.input.deliverMeasures(size: 4_096)
        #expect(
            rig.peer.events.suffix(2) == [
                .handOff(generation: 1, step: .armed),
                .sized(generation: 1, folderByteCounts: [1: 4_096]),
            ])
        #expect(rig.peer.outboundContent(generation: 1)?.representations[1].byteCount == 4_096)
    }

    @Test("a refused take, or a drag of files alone, measures nothing")
    func nothingIsMeasuredWithoutAFolderTaken() throws {
        let rig = Rig()
        rig.pressAndDrag([fileItem(try folder("Tree", files: ["a.txt": "alpha"]))])
        rig.dragOut.take(generation: 2)
        #expect(rig.input.pendingMeasureFolders.isEmpty)

        let filesOnly = Rig()
        filesOnly.pressAndDrag([fileItem(try file("loose.txt"))])
        filesOnly.dragOut.take(generation: 1)
        #expect(filesOnly.input.pendingMeasureFolders.isEmpty)
    }

    // MARK: - Validating a take

    @Test("a take naming another generation fails as stale and shows nothing")
    func aTakeOfAnotherGenerationFails() throws {
        let rig = Rig()
        rig.pressAndDrag([fileItem(try file("dragged.txt"))])

        rig.dragOut.take(generation: 2)

        #expect(
            rig.peer.handOffs == [
                .handOff(
                    generation: 2,
                    step: .failed(.dragTakeStale, message: GuestDragWatcher.ClaimRefusal.notCurrent.message))
            ])
        #expect(rig.surface.showCount == 0)
    }

    @Test("a take of an earlier press's drag fails as stale")
    func aTakeOfAnEarlierPressFails() throws {
        let rig = Rig()
        rig.pressAndDrag([fileItem(try file("dragged.txt"))])
        rig.releaseAndTick()
        rig.input.press()

        rig.dragOut.take(generation: 1)

        #expect(rig.peer.handOffs.count == 1)
        guard case .handOff(1, .failed(.dragTakeStale, _)) = rig.peer.handOffs.first else {
            Issue.record("Expected a stale failure, got \(rig.peer.handOffs)")
            return
        }
        #expect(rig.surface.showCount == 0)
    }

    @Test("a take after the button came up fails, before any tick saw it")
    func aTakeWithTheButtonUpFails() throws {
        let rig = Rig()
        rig.pressAndDrag([fileItem(try file("dragged.txt"))])
        rig.input.release()

        rig.dragOut.take(generation: 1)

        #expect(
            rig.peer.handOffs == [
                .handOff(
                    generation: 1,
                    step: .failed(.dragTakeStale, message: GuestDragWatcher.ClaimRefusal.pressOver.message))
            ])
        #expect(rig.surface.showCount == 0)
    }

    @Test("a second take of the same drag fails without touching the first")
    func aRepeatedTakeFails() throws {
        let rig = Rig()
        rig.pressAndDrag([fileItem(try file("dragged.txt"))])
        rig.dragOut.take(generation: 1)

        rig.dragOut.take(generation: 1)

        #expect(rig.surface.isShown)
        #expect(rig.peer.handOffs.count == 2)
        guard case .handOff(1, .failed(.dragTakeStale, _)) = rig.peer.handOffs.last else {
            Issue.record("Expected a stale failure, got \(rig.peer.handOffs)")
            return
        }
    }

    @Test("a take while not watching fails as stale")
    func aTakeWhileNotWatchingFails() {
        let rig = Rig(watching: false)

        rig.dragOut.take(generation: 1)

        #expect(rig.peer.handOffs.count == 1)
        #expect(rig.surface.showCount == 0)
    }

    // MARK: - The catcher's steps

    /// A rig whose drag of `urls` the host has taken.
    private func takenRig(_ urls: [URL]) -> Rig {
        let rig = Rig()
        rig.pressAndDrag(urls.map(fileItem))
        rig.dragOut.take(generation: 1)
        return rig
    }

    @Test("a take arms, targets on entry, catches on the drop and comes down at the end")
    func theHandOffSteps() throws {
        let urls = [try file("one.txt"), try file("two.txt")]
        let rig = takenRig(urls)
        #expect(rig.surface.isShown)
        #expect(rig.peer.handOffs == [.handOff(generation: 1, step: .armed)])
        let catcher = rig.dragOut.catcherForTesting

        #expect(catcher.draggingEntered(caught(urls)) == .copy)
        #expect(catcher.draggingUpdated(caught(urls)) == .copy)
        #expect(catcher.performDragOperation())
        // The drop's release is the host's; the press ending before the drop
        // concludes leaves the surface for the conclusion to take down.
        rig.releaseAndTick()
        #expect(rig.surface.isShown)
        catcher.concludeDragOperation()

        #expect(
            rig.peer.handOffs == [
                .handOff(generation: 1, step: .armed), .handOff(generation: 1, step: .targeted),
                .handOff(generation: 1, step: .caught),
            ])
        #expect(!rig.surface.isShown)
        #expect(!rig.peer.events.contains(.withdrew(generation: 1)))
    }

    @Test("re-entering after leaving reports targeted again")
    func reEntryTargetsAgain() throws {
        let urls = [try file("one.txt")]
        let rig = takenRig(urls)
        let catcher = rig.dragOut.catcherForTesting

        _ = catcher.draggingEntered(caught(urls))
        catcher.draggingExited()
        _ = catcher.draggingEntered(caught(urls))

        #expect(
            rig.peer.handOffs == [
                .handOff(generation: 1, step: .armed), .handOff(generation: 1, step: .targeted),
                .handOff(generation: 1, step: .targeted),
            ])
    }

    @Test("a drag holding other items is refused, fails the take and takes the surface down")
    func otherItemsAreRefused() throws {
        let rig = takenRig([try file("taken.txt")])
        let catcher = rig.dragOut.catcherForTesting

        #expect(catcher.draggingEntered(caught([try file("other.txt")])) == [])

        guard case .handOff(1, .failed(.dragTakeRefused, _)) = rig.peer.handOffs.last else {
            Issue.record("Expected a refusal, got \(rig.peer.handOffs)")
            return
        }
        #expect(!rig.surface.isShown)
        #expect(!rig.peer.handOffs.contains(.handOff(generation: 1, step: .targeted)))
    }

    @Test("a drag that carries no plain file URLs is refused")
    func aNonFileDragIsRefused() throws {
        let rig = takenRig([try file("taken.txt")])
        let catcher = rig.dragOut.catcherForTesting

        #expect(catcher.draggingUpdated(caught(nil)) == [])

        guard case .handOff(1, .failed(.dragTakeRefused, _)) = rig.peer.handOffs.last else {
            Issue.record("Expected a refusal, got \(rig.peer.handOffs)")
            return
        }
        #expect(!rig.surface.isShown)
    }

    @Test("a source that does not allow a copy is refused, never answered move or generic")
    func aSourceWithoutCopyIsRefused() throws {
        let urls = [try file("taken.txt")]
        let rig = takenRig(urls)
        let catcher = rig.dragOut.catcherForTesting

        #expect(catcher.draggingEntered(caught(urls, mask: [.move, .generic, .delete])) == [])

        guard case .handOff(1, .failed(.dragTakeRefused, _)) = rig.peer.handOffs.last else {
            Issue.record("Expected a refusal, got \(rig.peer.handOffs)")
            return
        }
        #expect(!rig.surface.isShown)
        // Nothing is left armed to answer a later callback with anything at all.
        #expect(catcher.draggingUpdated(caught(urls)) == [])
        #expect(!catcher.performDragOperation())
    }

    @Test(
        "a refusal after targeted fails the take once and keeps the surface up to refuse the drop",
        arguments: [false, true])
    func aRefusalAfterTargetedKeepsTheSurface(otherItems: Bool) throws {
        let urls = [try file("taken.txt")]
        let rig = takenRig(urls)
        let catcher = rig.dragOut.catcherForTesting
        #expect(catcher.draggingEntered(caught(urls)) == .copy)

        let refused =
            otherItems ? caught([try file("other.txt")]) : caught(urls, mask: [.move, .generic])
        #expect(catcher.draggingUpdated(refused) == [])

        #expect(rig.surface.isShown)
        let failures = rig.peer.handOffs.filter {
            if case .handOff(1, .failed(.dragTakeRefused, _)) = $0 { return true }
            return false
        }
        #expect(failures.count == 1)
        // A release the host injected before it heard the refusal drops here
        // and is refused, so nothing moves.
        #expect(catcher.draggingUpdated(caught(urls)) == [])
        #expect(!catcher.performDragOperation())
        // The press ending under the surface leaves it for the drag's end.
        rig.releaseAndTick()
        #expect(rig.surface.isShown)

        catcher.draggingEnded()

        #expect(!rig.surface.isShown)
        #expect(rig.peer.handOffs.count == 3)
        #expect(!rig.peer.handOffs.contains(.handOff(generation: 1, step: .caught)))
    }

    @Test("no screen to cover fails the take")
    func noScreenFailsTheTake() throws {
        let rig = Rig()
        rig.surface.hasScreen = false
        rig.pressAndDrag([fileItem(try file("dragged.txt"))])

        rig.dragOut.take(generation: 1)

        guard case .handOff(1, .failed(.dragTakeFailed, _)) = rig.peer.handOffs.last else {
            Issue.record("Expected a failure, got \(rig.peer.handOffs)")
            return
        }
        #expect(!rig.peer.handOffs.contains(.handOff(generation: 1, step: .armed)))
    }

    // MARK: - Every path that takes the surface down

    @Test("the drag ending without a drop takes the surface down and fails the take")
    func draggingEndedTakesItDown() throws {
        let urls = [try file("one.txt")]
        let rig = takenRig(urls)
        let catcher = rig.dragOut.catcherForTesting
        _ = catcher.draggingEntered(caught(urls))

        catcher.draggingEnded()

        #expect(!rig.surface.isShown)
        guard case .handOff(1, .failed(.dragTakeFailed, _)) = rig.peer.handOffs.last else {
            Issue.record("Expected a failure, got \(rig.peer.handOffs)")
            return
        }
    }

    @Test("the drag ending after the drop takes the surface down quietly")
    func draggingEndedAfterTheDropIsQuiet() throws {
        let urls = [try file("one.txt")]
        let rig = takenRig(urls)
        let catcher = rig.dragOut.catcherForTesting
        _ = catcher.draggingEntered(caught(urls))
        _ = catcher.performDragOperation()

        catcher.draggingEnded()

        #expect(!rig.surface.isShown)
        #expect(rig.peer.handOffs.last == .handOff(generation: 1, step: .caught))
    }

    @Test("the host completing the drag takes the surface down without a failure")
    func completionTakesItDown() throws {
        let rig = takenRig([try file("one.txt")])

        rig.dragOut.complete(generation: 1)

        #expect(!rig.surface.isShown)
        #expect(rig.peer.handOffs == [.handOff(generation: 1, step: .armed)])
    }

    @Test("the host completing a targeted drag this side did not refuse takes the surface down at once")
    func completionAfterTargetedTakesItDown() throws {
        let urls = [try file("one.txt")]
        let rig = takenRig(urls)
        let catcher = rig.dragOut.catcherForTesting
        _ = catcher.draggingEntered(caught(urls))

        // The host gave the press back without releasing: the user's drag goes
        // on in the guest, past where the surface was.
        rig.dragOut.complete(generation: 1)

        #expect(!rig.surface.isShown)
        #expect(catcher.draggingUpdated(caught(urls)) == [])
        #expect(!catcher.performDragOperation())
        catcher.draggingEnded()
        #expect(
            rig.peer.handOffs == [
                .handOff(generation: 1, step: .armed), .handOff(generation: 1, step: .targeted),
            ])
    }

    @Test("the host completing a drag this side refused after targeted leaves the surface up")
    func completionAfterARefusalLeavesItUp() throws {
        let urls = [try file("one.txt")]
        let rig = takenRig(urls)
        let catcher = rig.dragOut.catcherForTesting
        _ = catcher.draggingEntered(caught(urls))
        #expect(catcher.draggingUpdated(caught(urls, mask: [.move])) == [])

        rig.dragOut.complete(generation: 1)

        #expect(rig.surface.isShown)
        #expect(!catcher.performDragOperation())
        catcher.draggingEnded()
        #expect(!rig.surface.isShown)
        #expect(rig.peer.handOffs.count == 3)
    }

    @Test("completing another drag leaves the surface up")
    func anotherCompletionLeavesItUp() throws {
        let rig = takenRig([try file("one.txt")])

        rig.dragOut.complete(generation: 7)

        #expect(rig.surface.isShown)
    }

    @Test("the connection ending takes the surface down")
    func stopTakesItDown() throws {
        let rig = takenRig([try file("one.txt")])

        rig.dragOut.stop()

        #expect(!rig.surface.isShown)
    }

    @Test("the press ending before the drag entered takes the surface down and fails the take")
    func pressEndBeforeEntryTakesItDown() throws {
        let rig = takenRig([try file("one.txt")])

        rig.releaseAndTick()

        #expect(!rig.surface.isShown)
        guard case .handOff(1, .failed(.dragTakeFailed, _)) = rig.peer.handOffs.last else {
            Issue.record("Expected a failure, got \(rig.peer.handOffs)")
            return
        }
    }

    @Test("the press ending after the drag left the surface takes it down")
    func pressEndAfterExitTakesItDown() throws {
        let urls = [try file("one.txt")]
        let rig = takenRig(urls)
        let catcher = rig.dragOut.catcherForTesting
        _ = catcher.draggingEntered(caught(urls))
        catcher.draggingExited()

        rig.releaseAndTick()

        #expect(!rig.surface.isShown)
    }

    @Test("a click on a catcher that outlived its drag takes it down and fails the take")
    func aClickTakesAStrandedCatcherDown() throws {
        let urls = [try file("one.txt")]
        let rig = takenRig(urls)
        let catcher = rig.dragOut.catcherForTesting
        // Entered, so its press ending leaves it waiting for the drop.
        _ = catcher.draggingEntered(caught(urls))
        rig.releaseAndTick()
        #expect(rig.surface.isShown)

        catcher.surfaceClicked()

        #expect(!rig.surface.isShown)
        guard case .handOff(1, .failed(.dragTakeFailed, _)) = rig.peer.handOffs.last else {
            Issue.record("Expected the take to fail, got \(rig.peer.handOffs)")
            return
        }
        // The next press's take arms as the first did.
        rig.pressAndDrag([fileItem(try file("two.txt"))])
        rig.dragOut.take(generation: 2)
        #expect(rig.surface.isShown)
        #expect(rig.peer.handOffs.last == .handOff(generation: 2, step: .armed))
    }

    @Test("a click on a catcher that refused after targeted takes it down without a second failure")
    func aClickTakesARefusingCatcherDown() throws {
        let urls = [try file("one.txt")]
        let rig = takenRig(urls)
        let catcher = rig.dragOut.catcherForTesting
        _ = catcher.draggingEntered(caught(urls))
        _ = catcher.draggingUpdated(caught(urls, mask: [.move]))
        let reported = rig.peer.handOffs.count

        catcher.surfaceClicked()

        #expect(!rig.surface.isShown)
        #expect(rig.peer.handOffs.count == reported)
    }

    // MARK: - The host's session over this VM's display

    @Test("standing down hides the surface and keeps the take; showing it again arms and re-targets")
    func standDownAndShowAgain() throws {
        let urls = [try file("one.txt")]
        let rig = takenRig(urls)
        let catcher = rig.dragOut.catcherForTesting
        #expect(catcher.draggingEntered(caught(urls)) == .copy)

        rig.dragOut.setCatcherShown(false, generation: 1)

        #expect(!rig.surface.isShown)
        #expect(rig.peer.handOffs.count == 2)

        rig.dragOut.setCatcherShown(true, generation: 1)

        #expect(rig.surface.isShown)
        #expect(catcher.draggingEntered(caught(urls)) == .copy)
        #expect(catcher.performDragOperation())
        #expect(
            rig.peer.handOffs == [
                .handOff(generation: 1, step: .armed), .handOff(generation: 1, step: .targeted),
                .handOff(generation: 1, step: .armed), .handOff(generation: 1, step: .targeted),
                .handOff(generation: 1, step: .caught),
            ])
    }

    @Test("a drag dropped inside the guest while stood down ends the take with its press, failing nothing")
    func aDropInsideTheGuestEndsTheTake() throws {
        let urls = [try file("one.txt")]
        let rig = takenRig(urls)
        let catcher = rig.dragOut.catcherForTesting
        _ = catcher.draggingEntered(caught(urls))
        rig.dragOut.setCatcherShown(false, generation: 1)
        let reported = rig.peer.handOffs

        // The host's release lands on a guest target; the press ends.
        rig.releaseAndTick()

        #expect(!rig.surface.isShown)
        #expect(rig.peer.handOffs == reported)
        // The take is gone: showing it again is refused as stale.
        rig.dragOut.setCatcherShown(true, generation: 1)
        #expect(!rig.surface.isShown)
        guard case .handOff(1, .failed(.dragTakeStale, _)) = rig.peer.handOffs.last else {
            Issue.record("Expected a stale refusal, got \(rig.peer.handOffs)")
            return
        }
    }

    @Test("a drag callback after standing down neither targets nor reports, so the next showing targets afresh")
    func aCallbackWhileStoodDownIsRefusedQuietly() throws {
        let urls = [try file("one.txt")]
        let rig = takenRig(urls)
        let catcher = rig.dragOut.catcherForTesting
        rig.dragOut.setCatcherShown(false, generation: 1)

        #expect(catcher.draggingUpdated(caught(urls)) == [])
        #expect(catcher.draggingEntered(caught(urls, mask: [.move])) == [])
        #expect(!catcher.performDragOperation())
        #expect(rig.peer.handOffs == [.handOff(generation: 1, step: .armed)])

        rig.dragOut.setCatcherShown(true, generation: 1)
        #expect(catcher.draggingEntered(caught(urls)) == .copy)
        #expect(
            rig.peer.handOffs == [
                .handOff(generation: 1, step: .armed), .handOff(generation: 1, step: .armed),
                .handOff(generation: 1, step: .targeted),
            ])
    }

    @Test("showing the catcher again starts untargeted and reports armed once")
    func aShowingStartsUntargeted() throws {
        let urls = [try file("one.txt")]
        let rig = takenRig(urls)
        let catcher = rig.dragOut.catcherForTesting
        _ = catcher.draggingEntered(caught(urls))
        rig.dragOut.setCatcherShown(false, generation: 1)

        rig.dragOut.setCatcherShown(true, generation: 1)
        rig.dragOut.setCatcherShown(true, generation: 1)

        #expect(rig.surface.isShown)
        #expect(
            rig.peer.handOffs == [
                .handOff(generation: 1, step: .armed), .handOff(generation: 1, step: .targeted),
                .handOff(generation: 1, step: .armed),
            ])
        // Untargeted in this showing, a refusal takes the surface down rather
        // than holding it up for a release.
        _ = catcher.draggingEntered(caught(urls, mask: [.move]))
        #expect(!rig.surface.isShown)
        guard case .handOff(1, .failed(.dragTakeRefused, _)) = rig.peer.handOffs.last else {
            Issue.record("Expected a refusal, got \(rig.peer.handOffs)")
            return
        }
    }

    @Test("showing the catcher of a take this side no longer holds refuses it as stale")
    func showingAnUnknownTakeIsStale() throws {
        let rig = takenRig([try file("one.txt")])
        rig.dragOut.complete(generation: 1)

        rig.dragOut.setCatcherShown(false, generation: 1)
        #expect(rig.peer.handOffs == [.handOff(generation: 1, step: .armed)])
        rig.dragOut.setCatcherShown(true, generation: 1)

        guard case .handOff(1, .failed(.dragTakeStale, _)) = rig.peer.handOffs.last else {
            Issue.record("Expected a stale refusal, got \(rig.peer.handOffs)")
            return
        }
        #expect(!rig.surface.isShown)
    }

    @Test("a take refused after targeted stands down, stays down, and the host's completion ends it")
    func aRefusedTakeStaysDown() throws {
        let urls = [try file("one.txt")]
        let rig = takenRig(urls)
        let catcher = rig.dragOut.catcherForTesting
        _ = catcher.draggingEntered(caught(urls))
        _ = catcher.draggingUpdated(caught(urls, mask: [.move]))
        let reported = rig.peer.handOffs.count

        rig.dragOut.setCatcherShown(false, generation: 1)
        rig.dragOut.setCatcherShown(true, generation: 1)

        #expect(!rig.surface.isShown)
        #expect(rig.peer.handOffs.count == reported)
        rig.dragOut.complete(generation: 1)
        // Nothing is left armed: a newer press's take arms afresh.
        rig.releaseAndTick()
        rig.pressAndDrag([fileItem(try file("two.txt"))])
        rig.dragOut.take(generation: 2)
        #expect(rig.peer.handOffs.count == reported + 1)
        #expect(rig.peer.handOffs.last == .handOff(generation: 2, step: .armed))
    }

    @Test("no screen when the catcher is shown again fails the take")
    func noScreenOnShowingAgainFails() throws {
        let rig = takenRig([try file("one.txt")])
        rig.dragOut.setCatcherShown(false, generation: 1)
        rig.surface.hasScreen = false

        rig.dragOut.setCatcherShown(true, generation: 1)

        guard case .handOff(1, .failed(.dragTakeFailed, _)) = rig.peer.handOffs.last else {
            Issue.record("Expected a failure, got \(rig.peer.handOffs)")
            return
        }
    }

    // MARK: - The catcher's window

    /// The live catcher window laid out over `screen` for `urls`, never
    /// ordered front.
    private func catcherWindow(
        for urls: [URL] = [URL(fileURLWithPath: "/one.txt")],
        over screen: NSRect = NSRect(x: 0, y: 0, width: 1440, height: 900)
    ) -> (window: NSPanel, icons: FakeGuestDragTypeIcons) {
        let catcher = GuestDragCatcher(peer: FakeGuestDragPeer(), makeSurface: { _ in FakeCatcherSurface() })
        let icons = FakeGuestDragTypeIcons()
        let panel = GuestDragCatcherPanel(catcher: catcher, typeIcon: icons.icon(for:))
        panel.layOut(fileURLs: urls, over: screen)
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
        "the catcher's box sits centered below the screen's middle, clear of the drag image there",
        arguments: [
            NSRect(x: 0, y: 0, width: 1440, height: 900),
            NSRect(x: 1440, y: -82, width: 1511, height: 983),
        ])
    func catcherHUDSitsBelowTheMiddle(screen: NSRect) throws {
        let (window, _) = catcherWindow(over: screen)
        let content = try #require(window.contentView)
        let (box, icon, label, name) = try hud(in: window)
        let middle = NSPoint(x: content.bounds.midX, y: content.bounds.midY)

        #expect(label.stringValue == "Copy to Mac")
        #expect(box.material == .hudWindow)
        #expect(box.state == .active)
        #expect(abs(box.frame.midX - middle.x) < 0.5)
        // The content view is not flipped: below the middle is a lower y.
        #expect(abs(box.frame.maxY - (middle.y - 72)) < 0.5)
        #expect(icon.frame.size == NSSize(width: 128, height: 128))
        #expect(abs(box.bounds.maxY - icon.frame.maxY - 24) < 0.5)
        #expect(abs(icon.frame.minY - label.frame.maxY - 10) < 0.5)
        #expect(abs(label.frame.minY - name.frame.maxY - 4) < 0.5)
        #expect(abs(name.frame.minY - 24) < 0.5)
        for row in [icon, label, name] as [NSView] {
            #expect(abs(row.frame.midX - box.bounds.midX) < 0.5)
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
    }

    @Test("a long name truncates in the middle at the name line's widest")
    func catcherHUDTruncatesALongName() throws {
        let name = String(repeating: "a rather long name for one dragged photo ", count: 4) + ".heic"
        let (window, _) = catcherWindow(for: [URL(fileURLWithPath: "/\(name)")])
        let (box, _, _, nameLabel) = try hud(in: window)

        #expect(nameLabel.frame.width <= 272)
        #expect(nameLabel.lineBreakMode == .byTruncatingMiddle)
        #expect(box.frame.width <= 272 + 48)
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
