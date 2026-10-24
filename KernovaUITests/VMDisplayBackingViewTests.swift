import AppKit
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaUI

@Suite("VMDisplayBackingView Tests", .caseScoped)
@MainActor
struct VMDisplayBackingViewTests {
    private let stagingRoot = TestStagingRoot()
    private let scratch = TestScratchDirectory(prefix: "VMDisplayBackingViewTests")
    /// The VM every display in a test moves files through.
    private let host = FakeTransferHost()

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
    }

    /// A display hosted by ``host``, whose promise staging has a root of its own.
    private func makeBacking() -> VMDisplayBackingView {
        let backing = VMDisplayBackingView(frame: .zero)
        backing.staging = DropPromiseStaging(root: stagingRoot.root)
        let host = self.host
        backing.transferHost = { host }
        return backing
    }

    private func settings(autoResize: Bool, capturesSystemKeys: Bool) -> VMDisplayViewSettings {
        VMDisplayViewSettings(
            automaticallyReconfiguresDisplay: autoResize, capturesSystemKeys: capturesSystemKeys)
    }

    @Test("update carries both settings through to the machine view")
    func updateAppliesSettings() throws {
        let backing = makeBacking()

        backing.update(
            display: nil, isPaused: false, transitionText: nil,
            settings: settings(autoResize: true, capturesSystemKeys: true))
        #expect(backing.machineView.automaticallyReconfiguresDisplay == true)
        #expect(backing.machineView.capturesSystemKeys == true)

        backing.update(
            display: nil, isPaused: false, transitionText: nil,
            settings: settings(autoResize: false, capturesSystemKeys: false))
        #expect(backing.machineView.automaticallyReconfiguresDisplay == false)
        #expect(backing.machineView.capturesSystemKeys == false)
    }

    @Test("each setting moves on its own")
    func settingsMoveIndependently() throws {
        let backing = makeBacking()

        backing.apply(settings(autoResize: true, capturesSystemKeys: false))
        #expect(backing.machineView.automaticallyReconfiguresDisplay == true)
        #expect(backing.machineView.capturesSystemKeys == false)

        backing.apply(settings(autoResize: true, capturesSystemKeys: true))
        #expect(backing.machineView.automaticallyReconfiguresDisplay == true)
        #expect(backing.machineView.capturesSystemKeys == true)

        backing.apply(settings(autoResize: false, capturesSystemKeys: true))
        #expect(backing.machineView.automaticallyReconfiguresDisplay == false)
        #expect(backing.machineView.capturesSystemKeys == true)
    }

    @Test("apply reaches the machine view without an update pass")
    func applySettingsStandalone() throws {
        let backing = makeBacking()

        backing.apply(settings(autoResize: false, capturesSystemKeys: false))
        #expect(backing.machineView.automaticallyReconfiguresDisplay == false)

        // Re-applying the same values is a no-op, and the next change still lands.
        backing.apply(settings(autoResize: false, capturesSystemKeys: false))
        #expect(backing.machineView.automaticallyReconfiguresDisplay == false)

        backing.apply(settings(autoResize: true, capturesSystemKeys: true))
        #expect(backing.machineView.automaticallyReconfiguresDisplay == true)
        #expect(backing.machineView.capturesSystemKeys == true)
    }

    @Test("detach clears the machine view and leaves the applied settings alone")
    func detachClearsWithoutTouchingTheSettings() throws {
        let backing = makeBacking()
        backing.apply(settings(autoResize: false, capturesSystemKeys: true))

        backing.detach()

        #expect(backing.machineView.virtualMachine == nil)
        #expect(backing.machineView.automaticallyReconfiguresDisplay == false)
        #expect(backing.machineView.capturesSystemKeys == true)
    }

    // MARK: - File drop

    /// A dragging info carrying whatever `pasteboard` holds, from `source`, at
    /// `draggingLocation`.
    private final class StubDraggingInfo: NSObject, NSDraggingInfo {
        let draggingPasteboard: NSPasteboard
        let draggingSource: Any?
        var draggingLocation: NSPoint = .zero
        @MainActor init(pasteboard: NSPasteboard, source: Any? = nil) {
            self.draggingPasteboard = pasteboard
            self.draggingSource = source
        }

        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggedImageLocation: NSPoint { .zero }
        var draggedImage: NSImage? { nil }
        var draggingSequenceNumber: Int { 0 }
        var animatesToDestination: Bool = false
        var numberOfValidItemsForDrop: Int = 0
        var draggingFormation: NSDraggingFormation = .default
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        func enumerateDraggingItems(
            options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
            classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
            using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
        ) {}
        func resetSpringLoading() {}
    }

    /// A uniquely-named pasteboard holding `urls` as file URLs.
    private func makeFileDrag(_ urls: [URL]) -> StubDraggingInfo {
        let pasteboard = NSPasteboard(name: .init("VMDisplayBackingViewTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        return StubDraggingInfo(pasteboard: pasteboard)
    }

    /// A drag shaped the way one out of Photos is: an item advertising both a
    /// file promise and a URL of its own, beside plain file items.
    private func makePromisedURLDrag(promising promised: URL, alongside urls: [URL]) throws
        -> StubDraggingInfo
    {
        let pasteboard = NSPasteboard(name: .init("VMDisplayBackingViewTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(promised.absoluteString, forType: .fileURL)
        item.setString(
            "promise", forType: .init(try #require(NSFilePromiseReceiver.readableDraggedTypes.first))
        )
        pasteboard.writeObjects(([item] as [any NSPasteboardWriting]) + (urls as [NSURL]))
        return StubDraggingInfo(pasteboard: pasteboard)
    }

    private func makeTextDrag(_ text: String, source: Any? = nil) -> StubDraggingInfo {
        let pasteboard = NSPasteboard(name: .init("VMDisplayBackingViewTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return StubDraggingInfo(pasteboard: pasteboard, source: source)
    }

    @Test("the display follows its host's availability by itself")
    func registrationFollowsTheHost() async throws {
        let backing = makeBacking()
        #expect(backing.registeredDraggedTypes.isEmpty)

        host.displayDropAvailability = .disconnected
        // The observation's pass is queued on main by the change itself.
        await drainMainQueue()
        #expect(backing.registeredDraggedTypes.contains(.fileURL))

        host.displayDropAvailability = .none
        await drainMainQueue()
        #expect(backing.registeredDraggedTypes.isEmpty)
    }

    // MARK: - Files dragged out of a VM

    @Test("files dragged out of this same VM that its take does not carry here are refused, with the reject cursor")
    func refusesItsOwnUncarriedDragOut() throws {
        let backing = makeBacking()
        host.displayDropAvailability = .available
        backing.promiseSource = makePromiseSource([StubPromiseReceiver(fileNames: ["a.txt"])])
        var pushes: [Bool] = []
        backing.applyRejectCursor = { pushes.append($0) }
        var offered = false
        host.onDropFiles = { _, _ in
            offered = true
            return true
        }
        let take = FakeTake(items: [])
        let source = DisplayDragOutSource(vmID: host.id, take: take)
        let drag = makeTextDrag("promise", source: source)

        #expect(backing.draggingEntered(drag) == [])
        #expect(pushes == [true])
        #expect(!backing.performDragOperation(drag))
        #expect(!offered)
        #expect(take.events == [.hostSessionOver(.zero), .hostSessionDropped(.zero)])
    }

    @Test("files dragged out of this same VM go back into the guest, the promises unread")
    func carriesItsOwnDragOutIntoTheGuest() throws {
        let backing = makeBacking()
        // The drop goes to the guest over its display, not the drop channel.
        host.displayDropAvailability = .disconnected
        var pushes: [Bool] = []
        backing.applyRejectCursor = { pushes.append($0) }
        var promisesRead = false
        backing.promiseSource = DisplayDropPromiseSource(
            carriesPromises: { _ in
                promisesRead = true
                return true
            },
            receivers: { _ in
                promisesRead = true
                return []
            })
        let take = FakeTake(items: [])
        take.carriesOverDisplay = true
        let drag = makeTextDrag("promise", source: DisplayDragOutSource(vmID: host.id, take: take))
        drag.draggingLocation = NSPoint(x: 30, y: 40)
        let point = backing.machineView.convert(drag.draggingLocation, from: nil)

        #expect(backing.draggingEntered(drag) == .copy)
        #expect(backing.draggingUpdated(drag) == .copy)
        backing.draggingExited(drag)
        #expect(backing.draggingEntered(drag) == .copy)
        #expect(backing.performDragOperation(drag))

        #expect(
            take.events == [
                .hostSessionOver(point), .hostSessionOver(point), .hostSessionLeft,
                .hostSessionOver(point), .hostSessionDropped(point),
            ])
        #expect(pushes.allSatisfy { !$0 })
        #expect(!promisesRead)
        // The guest's own drag lands its promises itself: nothing names them.
        #expect(!take.events.contains(.namedItemsForInAppDestination))
    }

    @Test("files dragged out of another VM take the promise path")
    func acceptsAnotherVMsDragOut() throws {
        let backing = makeBacking()
        host.displayDropAvailability = .available
        backing.promiseSource = makePromiseSource([StubPromiseReceiver(fileNames: ["a.txt"])])
        let source = DisplayDragOutSource(vmID: UUID(), take: FakeTake(items: []))

        #expect(backing.draggingEntered(makeTextDrag("promise", source: source)) == .copy)
    }

    @Test("another VM's drag out has its promised items named before anything calls them in")
    func anotherVMsDragOutIsNamedFirst() async throws {
        let backing = makeBacking()
        host.displayDropAvailability = .available
        let receiver = StubPromiseReceiver(fileNames: ["IMG_0001.jpeg"])
        backing.promiseSource = makePromiseSource([receiver])
        let gate = AsyncGate()
        var offered: [URL] = []
        host.onDropFiles = { urls, _ in
            offered = urls
            gate.notify()
            return true
        }
        let take = FakeTake(items: [])
        var calledInFirst: Bool?
        take.onNameItems = {
            calledInFirst = receiver.destination != nil
            return true
        }
        let drag = makeTextDrag("promise", source: DisplayDragOutSource(vmID: UUID(), take: take))

        #expect(backing.performDragOperation(drag))

        #expect(calledInFirst == false)
        #expect(take.events == [.namedItemsForInAppDestination])
        try await gate.wait { !offered.isEmpty }
        #expect(offered.map(\.lastPathComponent) == ["IMG_0001.jpeg"])
    }

    @Test("another VM's drag out whose promised items could not be named is refused, nothing called in")
    func unnamedDragOutIsRefused() throws {
        let backing = makeBacking()
        host.displayDropAvailability = .available
        let receiver = StubPromiseReceiver(fileNames: ["File.jpeg"])
        backing.promiseSource = makePromiseSource([receiver])
        let take = FakeTake(items: [])
        take.onNameItems = { false }
        let drag = makeTextDrag("promise", source: DisplayDragOutSource(vmID: UUID(), take: take))

        #expect(!backing.performDragOperation(drag))

        #expect(receiver.destination == nil)
        #expect(take.events == [.namedItemsForInAppDestination])
    }

    @Test("a VM that never ran the agent is not a drag destination at all")
    func neverConnectedRegistersNothing() throws {
        let backing = makeBacking()
        host.displayDropAvailability = .none

        backing.applyDropRegistration()

        #expect(backing.registeredDraggedTypes.isEmpty)
    }

    @Test("a VM whose agent has connected before registers, even while disconnected")
    func disconnectedStillRegisters() throws {
        let backing = makeBacking()
        host.displayDropAvailability = .disconnected

        backing.applyDropRegistration()
        #expect(backing.registeredDraggedTypes.contains(.fileURL))

        // Registration is idempotent, and follows availability back down.
        let registered = backing.registeredDraggedTypes
        backing.applyDropRegistration()
        #expect(backing.registeredDraggedTypes == registered)

        host.displayDropAvailability = .none
        backing.applyDropRegistration()
        #expect(backing.registeredDraggedTypes.isEmpty)
    }

    @Test("a drag carrying no file URL is refused even when the agent is reachable")
    func refusesNonFileDrags() throws {
        let backing = makeBacking()
        host.displayDropAvailability = .available
        backing.applyDropRegistration()

        #expect(backing.draggingEntered(makeTextDrag("hello")) == [])
    }

    @Test("a drop forwards every dragged file URL")
    func dropForwardsTheURLs() throws {
        let backing = makeBacking()
        host.displayDropAvailability = .available
        var received: [URL] = []
        host.onDropFiles = { urls, _ in
            received = urls
            return true
        }
        let dropped = [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.txt")]

        #expect(backing.performDragOperation(makeFileDrag(dropped)))
        #expect(received.map(\.lastPathComponent) == ["a.txt", "b.txt"])
    }

    @Test("a drop re-checks availability, so a session lost mid-drag springs back")
    func dropRechecksAvailability() throws {
        let backing = makeBacking()
        host.displayDropAvailability = .available
        var forwarded = false
        host.onDropFiles = { _, _ in
            forwarded = true
            return true
        }
        let drag = makeFileDrag([URL(fileURLWithPath: "/tmp/a.txt")])
        #expect(backing.draggingUpdated(drag) == .copy)

        // The guest agent goes away between the last pointer move and the release.
        host.displayDropAvailability = .disconnected
        #expect(!backing.performDragOperation(drag))
        #expect(!forwarded)
    }

    @Test("a refused send reports the drop as not taken")
    func reportsARefusedSend() throws {
        let backing = makeBacking()
        host.displayDropAvailability = .available
        host.onDropFiles = { _, _ in false }

        #expect(!backing.performDragOperation(makeFileDrag([URL(fileURLWithPath: "/tmp/a.txt")])))
    }

    @Test("a file promise's types are registered alongside concrete file URLs")
    func registersPromiseTypes() throws {
        let backing = makeBacking()
        host.displayDropAvailability = .available

        backing.applyDropRegistration()

        for promised in NSFilePromiseReceiver.readableDraggedTypes {
            #expect(backing.registeredDraggedTypes.contains(.init(promised)))
        }
    }

    // MARK: - The reject cursor

    @Test("a refused drag shows the not-allowed cursor, and leaving clears it")
    func refusedDragShowsTheRejectCursor() throws {
        let backing = makeBacking()
        host.displayDropAvailability = .disconnected
        var pushes: [Bool] = []
        backing.applyRejectCursor = { pushes.append($0) }
        let drag = makeFileDrag([URL(fileURLWithPath: "/tmp/a.txt")])

        #expect(backing.draggingEntered(drag) == [])
        #expect(pushes == [true])
        // Repeated updates leave the pushed cursor where it is rather than
        // stacking a second one.
        #expect(backing.draggingUpdated(drag) == [])
        #expect(pushes == [true])

        backing.draggingExited(drag)
        #expect(pushes == [true, false])
    }

    @Test("a drag this display accepts pushes no cursor at all")
    func acceptedDragPushesNothing() throws {
        let backing = makeBacking()
        host.displayDropAvailability = .available
        var pushes: [Bool] = []
        backing.applyRejectCursor = { pushes.append($0) }

        #expect(backing.draggingEntered(makeFileDrag([URL(fileURLWithPath: "/tmp/a.txt")])) == .copy)
        #expect(pushes.isEmpty)
    }

    @Test("availability changing mid-drag flips the cursor on the next update")
    func cursorFollowsAvailabilityMidDrag() throws {
        let backing = makeBacking()
        host.displayDropAvailability = .disconnected
        var pushes: [Bool] = []
        backing.applyRejectCursor = { pushes.append($0) }
        let drag = makeFileDrag([URL(fileURLWithPath: "/tmp/a.txt")])

        // A drag that began while the VM was paused, over a VM that then resumes.
        #expect(backing.draggingEntered(drag) == [])
        host.displayDropAvailability = .available
        #expect(backing.draggingUpdated(drag) == .copy)
        #expect(pushes == [true, false])

        // …and back, when the agent goes away under the same drag.
        host.displayDropAvailability = .disconnected
        #expect(backing.draggingUpdated(drag) == [])
        #expect(pushes == [true, false, true])

        // The drop itself is the last thing that can leave a cursor pushed.
        backing.draggingEnded(drag)
        #expect(pushes == [true, false, true, false])
    }

    // MARK: - File promises

    /// A promise source that writes its files where it is asked to, or fails.
    @MainActor
    private final class StubPromiseReceiver: DisplayDropPromiseReceiving {
        struct Failure: Error {}

        /// When a source fills `fileNames` in — `NSFilePromiseReceiver`
        /// populates them as its files are received, so a Photos asset names
        /// nothing when the drag is taken.
        enum Naming {
            /// Named when the drag is taken, a Finder-style promise's shape.
            case upFront
            /// Named as the first file lands.
            case asFilesLand
            /// Never named at all, so the receiver's own count never accounts
            /// for what it writes.
            case never
        }

        private(set) var fileNames: [String]
        /// Where the view asked for the promised files, which nothing else
        /// tells a drag whose promises never reach an offer.
        private(set) var destination: URL?
        /// How many times this receiver has answered, which is what a test
        /// waiting past the drop's own offer has to wait on.
        private(set) var reportCount = 0
        private let promised: [String]
        private let naming: Naming
        private let fails: Bool

        init(fileNames: [String], naming: Naming = .upFront, fails: Bool = false) {
            self.promised = fileNames
            self.fileNames = naming == .upFront ? fileNames : []
            self.naming = naming
            self.fails = fails
        }

        func receivePromisedFiles(
            atDestination destination: URL, options: [AnyHashable: Any],
            operationQueue: OperationQueue, reader: @escaping (URL, (any Error)?) -> Void
        ) {
            self.destination = destination
            let failure: Failure? = fails ? Failure() : nil
            for name in promised {
                let url = destination.appendingPathComponent(name)
                if failure == nil { try? Data("promised".utf8).write(to: url) }
                // The real receiver answers asynchronously; so does this, so the
                // test exercises the wait rather than a synchronous shortcut.
                MainActorBridge.async {
                    if self.naming == .asFilesLand { self.fileNames = self.promised }
                    self.reportCount += 1
                    reader(url, failure)
                }
            }
        }
    }

    private func makePromiseSource(_ receivers: [any DisplayDropPromiseReceiving])
        -> DisplayDropPromiseSource
    {
        DisplayDropPromiseSource(carriesPromises: { _ in true }, receivers: { _ in receivers })
    }

    @Test("a drag carrying only promises is accepted")
    func promiseOnlyDragIsAccepted() throws {
        let backing = makeBacking()
        host.displayDropAvailability = .available
        backing.promiseSource = makePromiseSource([StubPromiseReceiver(fileNames: ["a.png"])])

        // The pasteboard holds no file URL at all — a Photos drag's shape.
        #expect(backing.draggingEntered(makeTextDrag("hello")) == .copy)
    }

    @Test("a mixed drag is offered once, with the promised files written")
    func mixedPromiseDragIsOfferedTogether() async throws {
        let backing = makeBacking()
        let concrete = scratch.url.appendingPathComponent("dropped.txt")
        try Data("a".utf8).write(to: concrete)

        host.displayDropAvailability = .available
        backing.promiseSource = makePromiseSource([
            StubPromiseReceiver(fileNames: ["a.png"]), StubPromiseReceiver(fileNames: ["b.png"]),
        ])
        let gate = AsyncGate()
        var offered: [[URL]] = []
        host.onDropFiles = { urls, _ in
            offered.append(urls)
            gate.notify()
            return true
        }

        #expect(backing.performDragOperation(makeFileDrag([concrete])))
        try await gate.wait { !offered.isEmpty }

        // One gesture, one offer — so the drop has one readout to report and
        // cancel through.
        #expect(offered.count == 1)
        let files = try #require(offered.first)
        #expect(files.map(\.lastPathComponent) == ["dropped.txt", "a.png", "b.png"])
        // The promised bytes are on disk where the guest's pull will read them.
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test(
        "a promise that names nothing until its files land is still offered",
        arguments: [1, 2])
    func unnamedPromiseIsOffered(promiseCount: Int) async throws {
        let backing = makeBacking()
        host.displayDropAvailability = .available
        let names = (0..<promiseCount).map { "a\($0).png" }
        backing.promiseSource = makePromiseSource([
            StubPromiseReceiver(fileNames: names, naming: .asFilesLand)
        ])
        let gate = AsyncGate()
        var offered: [[URL]] = []
        var staged: URL?
        var reported = false
        host.onDropFiles = { urls, stagedIn in
            offered.append(urls)
            staged = stagedIn
            gate.notify()
            return true
        }
        host.onDropUnreadable = {
            reported = true
            gate.notify()
        }

        #expect(backing.performDragOperation(makeTextDrag("promise")))
        try await gate.wait { !offered.isEmpty || reported }

        // A drag whose files have no names yet still has files coming: a
        // Photos asset names its picture only as it hands it over.
        #expect(!reported)
        #expect(offered.count == 1)
        #expect(offered.first?.map(\.lastPathComponent) == names)
        DropPromiseStaging.release(try #require(staged))
    }

    @Test("a dragged item its promise speaks for is not sent as its URL as well")
    func promisedItemIsNotAlsoSentAsItsURL() async throws {
        let backing = makeBacking()
        let concrete = scratch.url.appendingPathComponent("dropped.txt")
        try Data("a".utf8).write(to: concrete)
        let derivative = scratch.url.appendingPathComponent("derivative.jpeg")
        try Data("b".utf8).write(to: derivative)

        host.displayDropAvailability = .available
        backing.promiseSource = makePromiseSource([
            StubPromiseReceiver(fileNames: ["a.png"], naming: .asFilesLand)
        ])
        let gate = AsyncGate()
        var offered: [URL] = []
        var staged: URL?
        host.onDropFiles = { urls, stagedIn in
            offered = urls
            staged = stagedIn
            gate.notify()
            return true
        }

        #expect(
            backing.performDragOperation(
                try makePromisedURLDrag(promising: derivative, alongside: [concrete])))
        try await gate.wait { !offered.isEmpty }

        // The promise is what the source means to hand over; its item's own URL
        // is the same picture again, and sending both lands one dragged item in
        // the guest twice.
        #expect(offered.map(\.lastPathComponent) == ["dropped.txt", "a.png"])
        DropPromiseStaging.release(try #require(staged))
    }

    @Test("a promise drag hands the drop the directory its files were staged in")
    func promiseDragHandsOverItsStagingDirectory() async throws {
        let backing = makeBacking()
        host.displayDropAvailability = .available
        backing.promiseSource = makePromiseSource([StubPromiseReceiver(fileNames: ["a.png"])])
        let gate = AsyncGate()
        var staged: URL?
        var files: [URL] = []
        host.onDropFiles = { urls, stagedIn in
            files = urls
            staged = stagedIn
            gate.notify()
            return true
        }

        #expect(backing.performDragOperation(makeTextDrag("promise")))
        try await gate.wait { staged != nil }

        // The guest pulls these long after the drag, so whoever takes the drop
        // is handed what to free once it settles.
        let directory = try #require(staged)
        defer { DropPromiseStaging.release(directory) }
        #expect(
            files.allSatisfy {
                $0.deletingLastPathComponent().standardizedFileURL.path
                    == directory.standardizedFileURL.path
            })
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("a promise reporting after the drop was taken leaves its staging alone")
    func lateReportLeavesATakenStagingDirectoryAlone() async throws {
        let backing = makeBacking()
        host.displayDropAvailability = .available
        // A receiver whose names never account for what it writes settles the
        // drop on its first file, so the second reports after the drop was
        // taken — as does any source that answers more often than it names.
        let receiver = StubPromiseReceiver(fileNames: ["a0.png", "a1.png"], naming: .never)
        backing.promiseSource = makePromiseSource([receiver])
        let gate = AsyncGate()
        var offered: [URL] = []
        var staged: URL?
        host.onDropFiles = { urls, stagedIn in
            offered = urls
            staged = stagedIn
            return true
        }

        #expect(backing.performDragOperation(makeTextDrag("promise")))
        // Queued behind every one of the receiver's answers on the main queue.
        MainActorBridge.async { gate.notify() }
        try await gate.wait { receiver.reportCount == 2 }

        // The guest pulls from here long after the drag ended, so a promise
        // still writing when the drop was taken must not free it.
        let directory = try #require(staged)
        defer { DropPromiseStaging.release(directory) }
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(!offered.isEmpty)
        #expect(offered.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test("a promise drag the VM refuses frees what it staged")
    func refusedPromiseDragReleasesItsStagingDirectory() async throws {
        let backing = makeBacking()
        host.displayDropAvailability = .available
        backing.promiseSource = makePromiseSource([StubPromiseReceiver(fileNames: ["a.png"])])
        let gate = AsyncGate()
        var staged: URL?
        host.onDropFiles = { _, stagedIn in
            staged = stagedIn
            gate.notify()
            return false
        }

        #expect(backing.performDragOperation(makeTextDrag("promise")))
        try await gate.wait { staged != nil }

        // Nothing took the drop on, so nothing will settle it.
        #expect(!FileManager.default.fileExists(atPath: try #require(staged).path))
    }

    @Test(
        "a promise its source never writes frees the directory it staged",
        arguments: [1, 2])
    func failedPromiseReleasesItsStagingDirectory(promiseCount: Int) async throws {
        let backing = makeBacking()
        host.displayDropAvailability = .available
        let receiver = StubPromiseReceiver(
            fileNames: (0..<promiseCount).map { "a\($0).png" }, fails: true)
        backing.promiseSource = makePromiseSource([receiver])
        let gate = AsyncGate()
        var reported = false
        var offered = false
        host.onDropFiles = { _, _ in
            offered = true; return true
        }
        host.onDropUnreadable = { reported = true }

        #expect(backing.performDragOperation(makeTextDrag("promise")))
        let directory = try #require(receiver.destination)
        // A failure settles the drag while its other promises are still
        // writing, so this lands behind the last of them on the main queue.
        MainActorBridge.async { gate.notify() }

        try await gate.wait { !FileManager.default.fileExists(atPath: directory.path) }
        #expect(reported)
        #expect(!offered)
    }
}
