import AppKit
import Foundation
import KernovaKit
import KernovaTestSupport
import KernovaTransferProgress
import KernovaWire
import Synchronization
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// Exercises `ClipboardPassthroughCoordinator` — the automatic-passthrough
/// driver — over a private `NSPasteboard(name:)` so tests never touch the
/// developer's real clipboard.
///
/// The host→guest poll and guest→host publish are driven through a fake
/// `ClipboardServicing` so the assertions are deterministic: each copy the poll
/// offers is recorded, and the inbound publish's write lands on the private
/// pasteboard.
@Suite("ClipboardPassthroughCoordinator", .caseScoped)
@MainActor
struct ClipboardPassthroughCoordinatorTests {
    private let stagingRoot = TestStagingRoot()
    private let scratch = TestScratchDirectory(prefix: "kernova-passthrough")

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
    }

    /// In-memory `ClipboardServicing` for the coordinator: records the copies it
    /// is offered and lets a test simulate a new inbound guest offer.
    /// `@Observable` so the coordinator's `inboundOfferSeq` observation fires.
    @MainActor
    @Observable
    final class FakePassthroughService: ClipboardServicing {
        var guestContent: ClipboardContent = .empty
        var isConnected = true
        var supportsBinaryRepresentations = true
        private(set) var inboundOfferSeq: UInt64 = 0

        /// Where this stand-in reports its own refusals, as the real transport
        /// does — the VM's transfer report.
        @ObservationIgnored var reporter: ClipboardTransferReporter?

        /// One copy the poll offered.
        struct Forwarded {
            let copy: ClipboardOfferSource
            /// Its text, read when it was offered.
            let text: String?

            /// The name of each of its FILE and FOLDER representations.
            @MainActor var filenames: [String] {
                copy.items.flatMap(\.representations).filter { $0.storage != .inline }
                    .map { String(decoding: $0.name, as: UTF8.self) }
            }
        }

        /// Every copy handed to `offerHostCopy(_:)` by the poll, in order.
        var grabbed: [Forwarded] = []

        /// What a connected `offerHostCopy(_:)` reports — the seam a test uses to
        /// simulate a send that never left.
        var grabOutcome: ClipboardGrabOutcome = .settled

        /// Makes `guestClipboardItems` refuse the way `HubClipboardService` does
        /// over the deadline-safe cap: every file dropped, and the refusal
        /// reported in the same step.
        var refusesOverCopyBudget = false

        /// Fires on each `offerHostCopy`, so a wait on the poll's off-actor read
        /// resolves on the event itself.
        @ObservationIgnored let grabRecorded = AsyncGate()

        /// How many times `guestClipboardItems` has run — a publish's first step,
        /// and so how far a publish a test is holding has got.
        var copiesMaterialized = 0

        func stop() {}
        func copyMacClipboardToGuest(_ snapshot: ClipboardOfferSource) -> ClipboardTransferFailure? { nil }
        func guestClipboardCopy(_ write: @escaping @MainActor (GuestCopyContents) -> Void) async -> GuestClipboardCopy {
            .nothing
        }

        /// Mirrors both real transports: a disconnected service delivers nothing,
        /// so it reports `.undelivered` and leaves the copy retryable.
        func offerHostCopy(_ copy: ClipboardOfferSource) async -> ClipboardGrabOutcome {
            guard isConnected else { return .undelivered }
            let text = await copy.utf8Text()
            grabbed.append(Forwarded(copy: copy, text: text))
            grabRecorded.notify()
            return grabOutcome
        }

        func guestClipboardItems() -> [CopyToMacItem] {
            copiesMaterialized += 1
            guard refusesOverCopyBudget else {
                return guestContent.representations.map { .resolved($0) }
            }
            reporter?.finish(
                ClipboardTransferFinish(
                    gesture: .copy,
                    outcome: .failed(
                        .tooLarge(limitBytes: ClipboardPasteLimit.defaultBytes)),
                    peerName: "Passthrough VM"))
            return [.droppedFile(.overPasteBudget)]
        }

        /// Simulates a new inbound guest offer: publishes `content` and bumps the
        /// inbound sequence the coordinator observes.
        func simulateInboundOffer(_ content: ClipboardContent) {
            guestContent = content
            inboundOfferSeq &+= 1
        }
    }

    /// Counts the forward resolves the coordinator has completed.
    @MainActor
    final class ForwardResolveLog {
        private(set) var count = 0
        private let completed = AsyncGate()

        func record() {
            count += 1
            completed.notify()
        }

        /// Suspends until `count` resolves have completed.
        func wait(untilCompleted count: Int) async throws {
            try await completed.wait { self.count == count }
        }
    }

    private struct Harness {
        let coordinator: ClipboardPassthroughCoordinator
        let instance: VMInstance
        let service: FakePassthroughService
        let pasteboard: NSPasteboard
        let publisher: HostClipboardPublisher
        /// This VM's transfer report, as every surface reads it.
        let reports: ClipboardTransferReports
        /// The coordinator's completed file resolves, the event a wait on the
        /// poll's off-actor resolve resolves on.
        let resolves: ForwardResolveLog
    }

    /// Builds a coordinator over a connected fake service.
    ///
    /// With `bindsConnection`, one poll binds that service before the test
    /// writes anything, so every copy the test makes is one made while the
    /// connection is up.
    private func makeHarness(
        preferences: AppPreferences? = nil, bindsConnection: Bool = true
    ) -> Harness {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KernovaTest-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let publisher = HostClipboardPublisher(
            pasteboard: pasteboard, providerRegistry: LazyClipboardProviderRegistry(),
            stagingRoot: stagingRoot.root)
        let instance = VMInstanceFixture.make(
            name: "Passthrough VM", guestOS: .macOS,
            preferences: preferences ?? makeTestPreferences())
        let service = FakePassthroughService()
        let reports = ClipboardTransferReports()
        service.reporter = reports.reporter
        // The clipboard service is session state, so it needs a session to
        // live in.
        instance.beginSessionContextForTesting().clipboardService = service
        let coordinator = ClipboardPassthroughCoordinator(
            instance: instance, publisher: publisher, reporter: reports.reporter)
        let resolves = ForwardResolveLog()
        coordinator.onForwardResolvedForTesting = { resolves.record() }
        if bindsConnection { coordinator.pollHostClipboard() }
        return Harness(
            coordinator: coordinator, instance: instance, service: service,
            pasteboard: pasteboard, publisher: publisher, reports: reports, resolves: resolves)
    }

    /// Polls once, then waits until every forward a poll has started is handled.
    private func poll(_ h: Harness) async throws {
        h.coordinator.pollHostClipboard()
        try await h.resolves.wait(untilCompleted: h.coordinator.forwardsStartedForTesting)
    }

    /// Places a plain-text item on `pasteboard`.
    private func writeText(_ text: String, to pasteboard: NSPasteboard) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    /// Places one `public.file-url` item per URL, as a Finder ⌘C of several files
    /// does.
    private func writeFileURLs(_ urls: [URL], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.writeObjects(
            urls.map { url in
                let item = NSPasteboardItem()
                item.setString(url.absoluteString, forType: .fileURL)
                return item
            })
    }

    @Test("A service that reconnects in place forwards only copies made after it came back")
    func copyDuringInPlaceOutageIsNotForwarded() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        // SPICE keeps one service object across a vdagent re-handshake, so the
        // disconnected poll is the only thing that can end the connection.
        h.service.isConnected = false
        try await poll(h)
        writeText("copied during the outage", to: h.pasteboard)
        h.service.isConnected = true
        try await poll(h)
        try await poll(h)
        #expect(h.service.grabbed.isEmpty)

        writeText("copied after the reconnect", to: h.pasteboard)
        try await poll(h)
        #expect(h.service.grabbed.map(\.text) == ["copied after the reconnect"])
    }

    @Test("a copied zero-byte file is forwarded like any other, with nothing noted")
    func pollForwardsZeroByteFile() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        let empty = scratch.url.appendingPathComponent("empty.txt")
        try Data().write(to: empty)
        writeFileURLs([empty], to: h.pasteboard)

        h.coordinator.pollHostClipboard()
        try await h.service.grabRecorded.wait { !h.service.grabbed.isEmpty }

        #expect(h.service.grabbed.last?.filenames == ["empty.txt"])
        #expect(h.service.grabbed.last?.copy.items.first?.representations.first?.sizeEstimate == 0)
        #expect(h.reports.failure == nil)
    }

    @Test("a copy whose every file vanished before the poll surfaces the rejection")
    func pollSurfacesPrePollWholeCopyLoss() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        let doomed = scratch.url.appendingPathComponent("doomed.txt")
        try Data("doomed".utf8).write(to: doomed)
        writeFileURLs([doomed], to: h.pasteboard)

        // A copy made while connected whose file vanished before the poll read
        // it.
        try FileManager.default.removeItem(at: doomed)
        h.coordinator.pollHostClipboard()

        try await h.reports.waitForFailure()
        #expect(h.service.grabbed.isEmpty)
        #expect(h.reports.failure == .itemsUnreadable)
    }

    @Test("a second copy losing the same item is announced again, not collapsed into the first")
    func eachPartialCopyIsAnnouncedOnItsOwn() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        let kept = scratch.url.appendingPathComponent("kept.txt")
        let doomed = scratch.url.appendingPathComponent("doomed.txt")
        try Data("kept".utf8).write(to: kept)
        try Data("doomed".utf8).write(to: doomed)
        try FileManager.default.removeItem(at: doomed)

        // Two copies of the same partial selection: the second forwards content
        // the guest already holds, so nothing on the offer path resets what the
        // first left standing. Each is still a gesture the user made, and each
        // is owed its own message.
        writeFileURLs([kept, doomed], to: h.pasteboard)
        h.coordinator.pollHostClipboard()
        try await h.resolves.wait(untilCompleted: 1)

        writeFileURLs([kept, doomed], to: h.pasteboard)
        h.coordinator.pollHostClipboard()
        try await h.resolves.wait(untilCompleted: 2)

        #expect(h.reports.refusals.count == 2)
        #expect(h.reports.failure == .itemsSkipped(count: 1))
    }

    @Test("A poll during an in-flight file resolve starts no second walk of the same copy")
    func pollDuringResolveForwardsOnce() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        let file = scratch.url.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: file)
        writeFileURLs([file], to: h.pasteboard)

        // Both polls run before the resolve's Task can start: leaving the copy
        // retryable must not turn every tick of a multi-second folder walk into
        // another walk.
        h.coordinator.pollHostClipboard()
        h.coordinator.pollHostClipboard()
        try await h.resolves.wait(untilCompleted: 1)
        #expect(h.service.grabbed.count == 1)

        // And once it has settled, the copy is not offered a second time.
        try await poll(h)
        #expect(h.service.grabbed.count == 1)
    }

    @Test("A file resolve the host clipboard outran offers nothing and settles nothing")
    func supersededResolveIsDropped() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        let file = scratch.url.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: file)
        writeFileURLs([file], to: h.pasteboard)

        // The user copies something else while the folder walk is still running.
        h.coordinator.pollHostClipboard()
        writeText("copied over the folder", to: h.pasteboard)
        try await h.resolves.wait(untilCompleted: 1)

        // Offering the walk's result now would put content nobody holds on the
        // guest's clipboard.
        #expect(h.service.grabbed.isEmpty)

        // And settling the superseded count must not roll the record backwards:
        // the copy that replaced it still forwards.
        try await poll(h)
        #expect(h.service.grabbed.map(\.text) == ["copied over the folder"])
    }

    @Test("A file resolve outliving its passthrough session offers nothing, and the next copy still forwards")
    func resolveOutlivingItsSessionIsDropped() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        let file = scratch.url.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: file)
        h.coordinator.start()
        writeFileURLs([file], to: h.pasteboard)

        // Passthrough switched off and back on while the walk runs; turning it on sends nothing standing.
        h.coordinator.pollHostClipboard()
        h.coordinator.stop()
        h.coordinator.start()
        defer { h.coordinator.stop() }
        h.coordinator.pollHostClipboard()

        try await h.resolves.wait(untilCompleted: 1)
        #expect(h.service.grabbed.isEmpty)

        writeText("copied after the restart", to: h.pasteboard)
        try await poll(h)
        #expect(h.service.grabbed.map(\.text) == ["copied after the restart"])
    }

    @Test("An undelivered forward files no transfer report until its retry lands")
    func undeliveredForwardDefersItsSkipNote() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        let kept = scratch.url.appendingPathComponent("kept.txt")
        let doomed = scratch.url.appendingPathComponent("doomed.txt")
        try Data("kept".utf8).write(to: kept)
        try Data("doomed".utf8).write(to: doomed)
        writeFileURLs([kept, doomed], to: h.pasteboard)

        h.service.grabOutcome = .undelivered
        h.coordinator.pollHostClipboard()
        try FileManager.default.removeItem(at: doomed)
        try await h.resolves.wait(untilCompleted: 1)

        // Nothing reached the guest, so nothing partial did either — reporting
        // here would file one refusal per poll until the retry lands.
        #expect(h.service.grabbed.count == 1)
        #expect(h.reports.refusals.isEmpty)

        h.service.grabOutcome = .settled
        h.coordinator.pollHostClipboard()
        try await h.resolves.wait(untilCompleted: 2)

        #expect(h.reports.refusals.count == 1)
        #expect(h.reports.failure == .itemsSkipped(count: 1))
    }

    // MARK: - Replaying a refusal after the ceiling is raised

    /// Drives a passthrough session to the state the raise has to rescue: an
    /// inbound offer refused over the ceiling, nothing on the Mac clipboard.
    private func makeBudgetRefusedHarness(
        preferences: AppPreferences, hostContent: String = "previous host content"
    ) async throws -> Harness {
        let h = makeHarness(preferences: preferences)
        writeText(hostContent, to: h.pasteboard)

        // Wait on the publish *completing*, not on the transfer report: the
        // service reports the refusal inside `guestClipboardItems`, while the
        // coordinator records it only once the publish returns. Keying on the
        // report lets the raise land before there is a refusal to replay.
        var publishCompleted = false
        let published = AsyncGate()
        h.coordinator.onInboundPublishedForTesting = {
            publishCompleted = true
            published.notify()
        }
        h.coordinator.start()

        h.service.refusesOverCopyBudget = true
        h.service.simulateInboundOffer(ClipboardContent(text: "over the cap"))
        try await published.wait { publishCompleted }
        return h
    }

    @Test("raising the ceiling republishes the offer the old one refused")
    func raisingTheCeilingRepublishes() async throws {
        let preferences = makeTestPreferences()
        preferences.clipboardMaxPasteBytes = 512 * 1024 * 1024
        let h = try await makeBudgetRefusedHarness(preferences: preferences)
        defer {
            h.coordinator.stop()
            h.pasteboard.releaseGlobally()
        }

        // The user raises the ceiling — the action the refusal invites. Without a
        // replay this offer's sequence is already consumed and re-copying the
        // same content in the guest is deduped, so it would never arrive.
        let republished = AsyncGate()
        h.coordinator.onInboundPublishedForTesting = { republished.notify() }
        preferences.clipboardMaxPasteBytes = 16 * 1024 * 1024 * 1024
        h.service.refusesOverCopyBudget = false
        h.coordinator.republishIfCeilingRaised()

        // A published guest rep lands under its own UTI, not `.string` — that
        // type only ever holds what `writeText` put there.
        let textType = NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)
        try await republished.wait {
            h.pasteboard.data(forType: textType) == Data("over the cap".utf8)
        }
    }

    @Test("a ceiling raised over content the user has since copied leaves their clipboard alone")
    func raisingTheCeilingSparesAUserCopy() async throws {
        let preferences = makeTestPreferences()
        preferences.clipboardMaxPasteBytes = 512 * 1024 * 1024
        let h = try await makeBudgetRefusedHarness(preferences: preferences)
        defer {
            h.coordinator.stop()
            h.pasteboard.releaseGlobally()
        }

        // The user copies on the Mac between the refusal and the raise. That
        // pasteboard is theirs; replaying the guest's older offer over it would
        // destroy a copy they just made.
        writeText("what the user copied", to: h.pasteboard)
        var republished = false
        h.coordinator.onInboundPublishedForTesting = { republished = true }
        h.service.refusesOverCopyBudget = false
        preferences.clipboardMaxPasteBytes = 16 * 1024 * 1024 * 1024
        h.coordinator.republishIfCeilingRaised()

        // The raise decides synchronously; a republish it launched has landed
        // once the publish in flight has.
        await h.coordinator.inboundPublishTaskForTesting?.value
        #expect(!republished)
        #expect(h.pasteboard.string(forType: .string) == "what the user copied")
    }

    /// A guest-offer service: `guestClipboardItems` returns the offer whole, and
    /// its puller counts the pulls a paste starts, so a test can prove the
    /// publish itself moved no bytes.
    @MainActor
    @Observable
    final class PromisedPassthroughService: ClipboardServicing {
        var isConnected = true
        var supportsBinaryRepresentations = true
        private(set) var inboundOfferSeq: UInt64 = 0
        /// What the next `guestClipboardItems` offers.
        var items: [OfferedItem] = []
        @ObservationIgnored let puller = CountingPuller()

        func stop() {}
        func copyMacClipboardToGuest(_ snapshot: ClipboardOfferSource) -> ClipboardTransferFailure? { nil }
        func guestClipboardCopy(_ write: @escaping @MainActor (GuestCopyContents) -> Void) async -> GuestClipboardCopy {
            .nothing
        }
        func offerHostCopy(_ copy: ClipboardOfferSource) async -> ClipboardGrabOutcome { .settled }
        func guestClipboardItems() -> [CopyToMacItem] {
            [
                .offer(
                    CopyToMacOffer(
                        serving: .init(token: Data(repeating: 9, count: 16), connection: ClipboardConnectionID()),
                        items: items, concealed: false, servingFileURLs: true,
                        puller: puller))
            ]
        }

        func simulateInboundOffer(_ items: [OfferedItem]) {
            self.items = items
            inboundOfferSeq &+= 1
        }
    }

    /// Answers every inline pull with the same bytes, and counts every pull.
    final class CountingPuller: ClipboardItemPulling, Sendable {
        func whenEnded(_ handler: @escaping @Sendable () -> Void) {}
        func canServe(item: Int, representation: Int) -> Bool { false }

        private let pulls = Mutex(0)
        var pullCount: Int { pulls.withLock { $0 } }

        func pullBytes(item: Int, representation: Int, completion: @escaping @Sendable (Data?) -> Void) {
            pulls.withLock { $0 += 1 }
            completion(Data("promised bytes".utf8))
        }

        func pullFile(item: Int, representation: Int, completion: @escaping @Sendable (URL?) -> Void) {
            pulls.withLock { $0 += 1 }
            completion(nil)
        }
    }

    private static func representation(
        _ uti: String, _ storage: Representation.Storage, name: String = ""
    ) -> Representation {
        var representation = Representation()
        representation.type = TypeDescriptor(appleUTI: uti)
        representation.storage = storage
        representation.name = Data(name.utf8)
        return representation
    }

    @Test("A guest's inbound offer auto-publishes without moving any bytes")
    func inboundPromisedOfferPublishesWithoutPulling() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KernovaTest-\(UUID().uuidString)"))
        pasteboard.clearContents()
        defer { pasteboard.releaseGlobally() }
        let publisher = HostClipboardPublisher(
            pasteboard: pasteboard, providerRegistry: LazyClipboardProviderRegistry(),
            stagingRoot: stagingRoot.root)
        let instance = VMInstanceFixture.make(name: "Promised VM", guestOS: .macOS)
        let service = PromisedPassthroughService()
        instance.beginSessionContextForTesting().clipboardService = service
        let coordinator = ClipboardPassthroughCoordinator(
            instance: instance, publisher: publisher, reporter: instance.clipboardTransfers)

        let published = AsyncGate()
        coordinator.onInboundPublishedForTesting = { published.notify() }
        coordinator.start()
        defer { coordinator.stop() }

        let baseline = pasteboard.changeCount
        var text = OfferedItem()
        text.representations = [Self.representation(ClipboardContent.utf8TextUTI, .inline)]
        var file = OfferedItem()
        file.representations = [Self.representation("public.data", .file, name: "big.bin")]
        service.simulateInboundOffer([text, file])

        // The auto-publish lands promised items on the pasteboard…
        try await published.wait { pasteboard.changeCount > baseline }
        let textType = NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)
        let types = pasteboard.pasteboardItems?.flatMap(\.types) ?? []
        #expect(types.contains(textType))
        #expect(types.contains(.fileURL))
        // …without a single byte pull: publishing is metadata-only.
        #expect(service.puller.pullCount == 0)

        // Only a consumer's flavor read fires a pull. Read off the main thread,
        // where the publisher's hold parks rather than running an event loop.
        nonisolated(unsafe) let consumer = pasteboard
        let served = await Task.detached { consumer.data(forType: textType) }.value
        #expect(served == Data("promised bytes".utf8))
        #expect(service.puller.pullCount == 1)
    }

    /// Starts a session and parks its one inbound publish at the write: past
    /// `guestClipboardItems` *and* past the publisher's off-actor stage, the
    /// window a cancellation has to land in for the write to be stopped.
    private func makeHeldPublishHarness() async throws -> (Harness, PublishHold) {
        let h = makeHarness()
        writeText("previous host content", to: h.pasteboard)
        let hold = PublishHold(h.publisher)
        h.coordinator.start()
        h.service.simulateInboundOffer(ClipboardContent(text: "guest copied this"))
        try await hold.waitUntilAtWrite()
        // Where the park sits: the publish has planned and staged its items, the
        // state a gate on `guestClipboardItems` — synchronous, before the first
        // await — cannot hold a publish in.
        #expect(h.service.copiesMaterialized == 1)
        return (h, hold)
    }

    @Test("stop() cancels the inbound publish in flight, so nothing lands after it")
    func stopCancelsTheInboundPublishInFlight() async throws {
        let (h, hold) = try await makeHeldPublishHarness()
        defer { h.pasteboard.releaseGlobally() }
        let baseline = h.pasteboard.changeCount

        let publish = try #require(h.coordinator.inboundPublishTaskForTesting)
        var publishedAfterStop = false
        h.coordinator.onInboundPublishedForTesting = { publishedAfterStop = true }
        h.coordinator.stop()
        #expect(publish.isCancelled)

        hold.release()
        await publish.value

        #expect(!publishedAfterStop)
        #expect(h.pasteboard.changeCount == baseline)
        #expect(h.pasteboard.string(forType: .string) == "previous host content")
        // The write records this whether or not the pasteboard took the items,
        // so `nil` means the write was never attempted.
        #expect(h.publisher.lastWriteChangeCount == nil)
    }

    @Test("A newer inbound offer supersedes the publish in flight")
    func newerOfferSupersedesInFlightPublish() async throws {
        let (h, hold) = try await makeHeldPublishHarness()
        defer {
            h.coordinator.stop()
            h.pasteboard.releaseGlobally()
        }
        let first = try #require(h.coordinator.inboundPublishTaskForTesting)

        let published = AsyncGate()
        h.coordinator.onInboundPublishedForTesting = { published.notify() }
        h.service.simulateInboundOffer(ClipboardContent(text: "guest copied again"))
        // Both publishes park at the write, so the first is provably still in
        // flight — not merely un-awaited — when the second supersedes it.
        try await hold.waitUntilAtWrite(count: 2)

        #expect(first.isCancelled)
        let second = try #require(h.coordinator.inboundPublishTaskForTesting)
        #expect(second != first)
        #expect(!second.isCancelled)

        hold.release()
        let textType = NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)
        try await published.wait {
            h.pasteboard.data(forType: textType) == Data("guest copied again".utf8)
        }
    }
}

/// Parks every publish one step short of its pasteboard write — past
/// `guestClipboardItems` and the staging hop — so a test can drive a `stop()`, or
/// a superseding offer, into the window a gate before the publish's first await
/// never reaches.
///
/// Install it on the publisher before the offer that triggers the publish:
/// ``waitUntilAtWrite(count:)`` resolves once that many publishes are parked
/// there, and ``release()`` lets them all go on.
@MainActor
private final class PublishHold {
    private let reached = AsyncGate()
    private let resumed = AsyncGate()
    private var parkedCount = 0
    private var isReleased = false

    init(_ publisher: HostClipboardPublisher) {
        publisher.beforePasteboardWriteForTesting = { [self] in
            parkedCount += 1
            reached.notify()
            // A fired backstop only lets the publish reach its write, which the
            // caller's assertions catch — this hides no stuck condition.
            try? await resumed.wait { self.isReleased }
        }
    }

    /// Suspends until `count` publishes are parked at the write.
    func waitUntilAtWrite(count: Int = 1) async throws {
        try await reached.wait { self.parkedCount >= count }
    }

    /// Lets every parked publish go on.
    func release() {
        isReleased = true
        resumed.notify()
    }
}
