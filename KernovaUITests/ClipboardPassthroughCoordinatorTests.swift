import AppKit
import Foundation
import KernovaKit
import KernovaTestSupport
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
        var clipboardContent: ClipboardContent = .empty
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

        /// Makes `materializeForCopy` refuse the way `HubClipboardService` does
        /// over the deadline-safe cap: every file dropped, and the refusal
        /// reported in the same step.
        var refusesOverCopyBudget = false

        /// Fires on each `offerHostCopy`, so a wait on the poll's off-actor read
        /// resolves on the event itself.
        @ObservationIgnored let grabRecorded = AsyncGate()

        /// How many times `materializeForCopy` has run — a publish's first step,
        /// and so how far a publish a test is holding has got.
        var copiesMaterialized = 0

        func stop() {}
        func clearBuffer() { clipboardContent = .empty }

        func grabIfChanged() -> ClipboardGrabOutcome { .settled }

        /// Mirrors both real transports: a disconnected service delivers nothing,
        /// so it reports `.undelivered` and leaves the copy retryable.
        func offerHostCopy(_ copy: ClipboardOfferSource) async -> ClipboardGrabOutcome {
            guard isConnected else { return .undelivered }
            let text = await copy.utf8Text()
            grabbed.append(Forwarded(copy: copy, text: text))
            grabRecorded.notify()
            return grabOutcome
        }

        func materializeForCopy() -> [CopyToMacItem] {
            copiesMaterialized += 1
            guard refusesOverCopyBudget else {
                return clipboardContent.representations.map { .resolved($0) }
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
            clipboardContent = content
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

    @Test("A host clipboard change is forwarded to the guest on poll")
    func pollForwardsHostChange() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        writeText("hello guest", to: h.pasteboard)
        try await poll(h)

        #expect(h.service.grabbed.count == 1)
        #expect(h.service.grabbed.first?.text == "hello guest")
    }

    @Test("An unchanged host clipboard is not re-forwarded")
    func pollSkipsUnchanged() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        writeText("once", to: h.pasteboard)
        try await poll(h)
        try await poll(h)  // change count unchanged

        #expect(h.service.grabbed.count == 1)
    }

    @Test("A copy made during an outage stays on the host; one made after the reconnect is forwarded")
    func copyDuringOutageIsNotForwardedAfterReconnect() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        h.service.isConnected = false
        writeText("copied during the outage", to: h.pasteboard)
        try await poll(h)
        #expect(h.service.grabbed.isEmpty)

        // The accept path swaps in a fresh service on redial.
        let reconnected = FakePassthroughService()
        reconnected.reporter = h.reports.reporter
        h.instance.sessionContext?.clipboardService = reconnected
        try await poll(h)
        try await poll(h)
        #expect(reconnected.grabbed.isEmpty)

        writeText("copied after the reconnect", to: h.pasteboard)
        try await poll(h)
        #expect(reconnected.grabbed.map(\.text) == ["copied after the reconnect"])
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

    @Test("The copy standing at connect is neither forwarded nor reported, even when its file is gone")
    func standingCopyAtConnectIsIgnored() async throws {
        let h = makeHarness(bindsConnection: false)
        defer { h.pasteboard.releaseGlobally() }

        let doomed = scratch.url.appendingPathComponent("doomed.txt")
        try Data("doomed".utf8).write(to: doomed)
        writeFileURLs([doomed], to: h.pasteboard)
        try FileManager.default.removeItem(at: doomed)

        try await poll(h)
        try await poll(h)
        #expect(h.service.grabbed.isEmpty)
        #expect(h.reports.failure == nil)
        #expect(h.reports.refusals.isEmpty)

        writeText("copied once connected", to: h.pasteboard)
        try await poll(h)
        #expect(h.service.grabbed.map(\.text) == ["copied once connected"])
    }

    @Test("Passthrough started on a connected guest skips the current clipboard and forwards the next copy")
    func startOnConnectedServiceSkipsStandingCopy() async throws {
        let h = makeHarness(bindsConnection: false)
        defer { h.pasteboard.releaseGlobally() }

        writeText("copied before passthrough started", to: h.pasteboard)
        h.coordinator.start()
        defer { h.coordinator.stop() }
        try await poll(h)
        try await poll(h)
        #expect(h.service.grabbed.isEmpty)

        writeText("copied after passthrough started", to: h.pasteboard)
        try await poll(h)
        #expect(h.service.grabbed.map(\.text) == ["copied after passthrough started"])
    }

    @Test("A forward the transport never delivered is re-offered until it lands")
    func undeliveredForwardIsRetried() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        // The send failed on a connection that still reports itself up — a
        // verdict only the transport's own outcome carries.
        h.service.grabOutcome = .undelivered
        writeText("never left the host", to: h.pasteboard)
        try await poll(h)
        #expect(h.service.grabbed.count == 1)

        // Same copy, same change count: the poll must offer it again rather than
        // read the count as already spent.
        try await poll(h)
        #expect(h.service.grabbed.count == 2)

        h.service.grabOutcome = .settled
        try await poll(h)
        #expect(h.service.grabbed.count == 3)
        #expect(h.service.grabbed.last?.text == "never left the host")

        // Landed — the count is settled and the retries stop.
        try await poll(h)
        #expect(h.service.grabbed.count == 3)
    }

    @Test("Our own inbound publish is absorbed, not re-forwarded (echo suppression)")
    func echoSuppressed() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        // Simulate a guest offer landing and publish it to the host pasteboard —
        // exactly what the inbound path (or a manual "Copy to Mac") does through
        // the shared publisher.
        h.service.clipboardContent = ClipboardContent(text: "from guest")
        let outcome = try await h.publisher.publish(from: h.service)
        guard case .written = outcome else {
            Issue.record("Expected the publish to land on the pasteboard, got \(outcome)")
            return
        }

        // The poll must recognize its own write and not offer it back to the guest.
        try await poll(h)
        #expect(h.service.grabbed.isEmpty)
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

    @Test("a file deleted before the poll reads the pasteboard surfaces the skip as an issue")
    func pollSurfacesPrePollLoss() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        let kept = scratch.url.appendingPathComponent("kept.txt")
        let doomed = scratch.url.appendingPathComponent("doomed.txt")
        try Data("kept".utf8).write(to: kept)
        try Data("doomed".utf8).write(to: doomed)
        writeFileURLs([kept, doomed], to: h.pasteboard)

        // A forward carrying fewer files than were copied, with no gesture to
        // report it back to.
        try FileManager.default.removeItem(at: doomed)
        h.coordinator.pollHostClipboard()

        try await h.reports.waitForFailure()
        #expect(h.service.grabbed.last?.filenames == ["kept.txt"])
        #expect(h.reports.failure == .itemsSkipped(count: 1))
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

    @Test("a text-only transport reports no lost file")
    func pollStaysQuietForTextOnlyTransport() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }
        h.service.supportsBinaryRepresentations = false

        let doomed = scratch.url.appendingPathComponent("doomed.txt")
        try Data("doomed".utf8).write(to: doomed)
        writeFileURLs([doomed], to: h.pasteboard)
        try FileManager.default.removeItem(at: doomed)

        // Wait on the read *completing*, not on a bounded sleep: the loss is
        // handled on an unstructured Task, so a sleep that outruns a loaded
        // scheduler would assert "no issue" before the branch that could raise
        // one had run, and pass for the wrong reason.
        try await poll(h)

        // A text-only transport (a Linux guest's) carries no file, so a vanished
        // one is nothing it lost.
        #expect(h.service.grabbed.isEmpty)
        #expect(h.reports.failure == nil)
    }

    @Test("A file resolve whose connection dropped offers nothing to the reconnected service")
    func resolveOutlivingItsConnectionIsDropped() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        let file = scratch.url.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: file)
        writeFileURLs([file], to: h.pasteboard)

        // The resolve's continuation needs the main actor this test holds, so the
        // connection drops and the redial's service comes up strictly between
        // the poll's read and the offer it leads to.
        h.coordinator.pollHostClipboard()
        h.service.isConnected = false
        h.coordinator.pollHostClipboard()
        let reconnected = FakePassthroughService()
        reconnected.reporter = h.reports.reporter
        h.instance.sessionContext?.clipboardService = reconnected
        h.coordinator.pollHostClipboard()
        try await h.resolves.wait(untilCompleted: 1)

        #expect(h.service.grabbed.isEmpty)
        #expect(reconnected.grabbed.isEmpty)
        #expect(h.reports.failure == nil)
        #expect(h.reports.refusals.isEmpty)

        // The copy belonged to the dropped connection, so the new one's polls
        // leave it on the host.
        try await poll(h)
        #expect(reconnected.grabbed.isEmpty)
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
        writeFileURLs([file], to: h.pasteboard)

        // Passthrough switched off and back on while the walk runs.
        h.coordinator.start()
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

    @Test("A transient-marked snapshot is not forwarded")
    func transientMarkerSkipped() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        let item = NSPasteboardItem()
        item.setString("secret-ish", forType: .string)
        let transientType = NSPasteboard.PasteboardType(ClipboardSnapshotPolicy.transientMarkerUTI)
        item.setData(Data("1".utf8), forType: transientType)
        h.pasteboard.clearContents()
        h.pasteboard.writeObjects([item])

        try await poll(h)
        #expect(h.service.grabbed.isEmpty)
    }

    @Test("A new inbound guest offer is auto-published to the host pasteboard")
    func inboundOfferPublishesToHost() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        // Event-driven: the gate fires when the inbound auto-publish completes, so
        // the wait resolves on the publish itself — never a poll deadline — even
        // when a contended CI main actor delays the observation → publish Task
        // chain. The generous timeout is a stuck-condition backstop, not the
        // success deadline.
        let published = AsyncGate()
        h.coordinator.onInboundPublishedForTesting = { published.notify() }
        h.coordinator.start()
        defer { h.coordinator.stop() }

        h.service.simulateInboundOffer(ClipboardContent(text: "guest copied this"))

        let textType = NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)
        try await published.wait {
            h.pasteboard.data(forType: textType) == Data("guest copied this".utf8)
        }
    }

    @Test("An over-cap inbound offer writes nothing and leaves the refusal on the service")
    func inboundOverCapOfferPublishesNothing() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        // What the Mac clipboard holds when the guest copies the over-cap files —
        // and still holds afterwards, since the publish returns before it clears.
        writeText("previous host content", to: h.pasteboard)
        let baseline = h.pasteboard.changeCount

        let published = AsyncGate()
        h.coordinator.onInboundPublishedForTesting = { published.notify() }
        h.coordinator.start()
        defer { h.coordinator.stop() }

        h.service.refusesOverCopyBudget = true
        h.service.simulateInboundOffer(ClipboardContent(text: "over the cap"))

        try await published.wait { h.reports.failure != nil }
        #expect(h.pasteboard.changeCount == baseline)
        #expect(h.pasteboard.string(forType: .string) == "previous host content")
        // No gesture outcome exists on this path — the coordinator discards
        // everything but the change count — so the report is the whole account.
        #expect(
            h.reports.failure == .tooLarge(limitBytes: ClipboardPasteLimit.defaultBytes))
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
        // service reports the refusal inside `materializeForCopy`, while the
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

    @Test("a ceiling that did not rise republishes nothing")
    func anUnraisedCeilingRepublishesNothing() async throws {
        let preferences = makeTestPreferences()
        preferences.clipboardMaxPasteBytes = 16 * 1024 * 1024 * 1024
        let h = try await makeBudgetRefusedHarness(preferences: preferences)
        defer {
            h.coordinator.stop()
            h.pasteboard.releaseGlobally()
        }

        // Lowering it can only refuse more, so replaying would rewrite the Mac
        // clipboard for no gain.
        var republished = false
        h.coordinator.onInboundPublishedForTesting = { republished = true }
        h.service.refusesOverCopyBudget = false
        preferences.clipboardMaxPasteBytes = 512 * 1024 * 1024
        h.coordinator.republishIfCeilingRaised()

        await h.coordinator.inboundPublishTaskForTesting?.value
        #expect(!republished)
        #expect(h.pasteboard.string(forType: .string) == "previous host content")
    }

    /// A guest-offer service: `materializeForCopy` returns the offer whole, and
    /// its puller counts the pulls a paste starts, so a test can prove the
    /// publish itself moved no bytes.
    @MainActor
    @Observable
    final class PromisedPassthroughService: ClipboardServicing {
        var clipboardContent: ClipboardContent = .empty
        var isConnected = true
        var supportsBinaryRepresentations = true
        private(set) var inboundOfferSeq: UInt64 = 0
        /// What the next `materializeForCopy` offers.
        var items: [OfferedItem] = []
        @ObservationIgnored let puller = CountingPuller()

        func stop() {}
        func grabIfChanged() -> ClipboardGrabOutcome { .settled }
        func offerHostCopy(_ copy: ClipboardOfferSource) async -> ClipboardGrabOutcome { .settled }
        func clearBuffer() { clipboardContent = .empty }
        func materializeForCopy() -> [CopyToMacItem] {
            [.offer(CopyToMacOffer(items: items, concealed: false, servingFileURLs: true, puller: puller))]
        }

        func simulateInboundOffer(_ items: [OfferedItem]) {
            self.items = items
            inboundOfferSeq &+= 1
        }
    }

    /// Answers every inline pull with the same bytes, and counts every pull.
    final class CountingPuller: ClipboardItemPulling, Sendable {
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

    @Test("After stop, a new inbound offer is not published")
    func stopHaltsInboundPublish() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        var publishedAfterStop = false
        h.coordinator.start()
        h.coordinator.stop()
        h.coordinator.onInboundPublishedForTesting = { publishedAfterStop = true }

        let baseline = h.pasteboard.changeCount
        h.service.simulateInboundOffer(ClipboardContent(text: "should not appear"))

        // The offer's observation fires in a main-actor job the offer enqueued,
        // and a publish it launched lands with the task it leaves behind.
        await drainMainQueue()
        await h.coordinator.inboundPublishTaskForTesting?.value
        #expect(!publishedAfterStop)
        #expect(h.pasteboard.changeCount == baseline)
    }

    /// Starts a session and parks its one inbound publish at the write: past
    /// `materializeForCopy` *and* past the publisher's off-actor stage, the
    /// window a cancellation has to land in for the write to be stopped.
    private func makeHeldPublishHarness() async throws -> (Harness, PublishHold) {
        let h = makeHarness()
        writeText("previous host content", to: h.pasteboard)
        let hold = PublishHold(h.publisher)
        h.coordinator.start()
        h.service.simulateInboundOffer(ClipboardContent(text: "guest copied this"))
        try await hold.waitUntilAtWrite()
        // Where the park sits: the publish has planned and staged its items, the
        // state a gate on `materializeForCopy` — synchronous, before the first
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

    @Test("A publish held at its write still lands while the session is running")
    func heldInboundPublishLandsWithoutAStop() async throws {
        let (h, hold) = try await makeHeldPublishHarness()
        defer {
            h.coordinator.stop()
            h.pasteboard.releaseGlobally()
        }

        let published = AsyncGate()
        var publishCompleted = false
        h.coordinator.onInboundPublishedForTesting = {
            publishCompleted = true
            published.notify()
        }
        hold.release()
        try await published.wait { publishCompleted }

        let textType = NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)
        #expect(h.pasteboard.data(forType: textType) == Data("guest copied this".utf8))
        // The coordinator absorbed its own write, so the next poll tick skips it.
        #expect(h.publisher.lastWriteChangeCount == h.pasteboard.changeCount)
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
/// `materializeForCopy` and the staging hop — so a test can drive a `stop()`, or
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
