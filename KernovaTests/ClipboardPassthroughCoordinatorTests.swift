import AppKit
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// Exercises `ClipboardPassthroughCoordinator` — the automatic-passthrough
/// driver — over a private `NSPasteboard(name:)` so tests never touch the
/// developer's real clipboard.
///
/// The host→guest poll and guest→host publish are driven through a fake
/// `ClipboardServicing` so the assertions are deterministic: the poll's outbound
/// grab is recorded, and the inbound publish's write lands on the private
/// pasteboard.
@Suite("ClipboardPassthroughCoordinator", .admissionGated)
@MainActor
struct ClipboardPassthroughCoordinatorTests {
    /// In-memory `ClipboardServicing` for the coordinator: records outbound grabs
    /// and lets a test simulate a new inbound guest offer. `@Observable` so the
    /// coordinator's `inboundOfferSeq` observation fires.
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

        /// Every content handed to `grabIfChanged()` by the poll, in order.
        var grabbed: [ClipboardContent] = []

        /// What a connected `grabIfChanged()` reports — the seam a test uses to
        /// simulate a send that never left.
        var grabOutcome: ClipboardGrabOutcome = .settled

        /// Makes `materializeForCopy` refuse the way `VsockClipboardService` does
        /// over the deadline-safe cap: every rep dropped, and the refusal
        /// reported in the same step.
        var refusesOverCopyBudget = false

        /// Fires on each `grabIfChanged`, so a wait on the poll's off-actor file
        /// resolve resolves on the event itself.
        @ObservationIgnored let grabRecorded = AsyncGate()

        func stop() {}
        func clearBuffer() { clipboardContent = .empty }

        /// Mirrors both real transports: a disconnected service delivers nothing,
        /// so it reports `.undelivered` and leaves the copy retryable.
        func grabIfChanged() -> ClipboardGrabOutcome {
            guard isConnected else { return .undelivered }
            grabbed.append(clipboardContent)
            grabRecorded.notify()
            return grabOutcome
        }

        func materializeForCopy() -> [CopyToMacItem] {
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

    private struct Harness {
        let coordinator: ClipboardPassthroughCoordinator
        let instance: VMInstance
        let service: FakePassthroughService
        let pasteboard: NSPasteboard
        let publisher: HostClipboardPublisher
        /// This VM's transfer report, as every surface reads it.
        let reports: ClipboardTransferReports
    }

    private func makeHarness(preferences: AppPreferences? = nil) -> Harness {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KernovaTest-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let publisher = HostClipboardPublisher(
            writePasteboard: pasteboard, providerRegistry: LazyClipboardProviderRegistry())
        let config = VMConfiguration(name: "Passthrough VM", guestOS: .macOS, bootMode: .macOS)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        let instance = VMInstance(
            configuration: config, bundleURL: bundleURL,
            preferences: preferences
                ?? makeEphemeralPreferences(suiteName: "test.kernova.passthrough-instance"))
        let service = FakePassthroughService()
        let reports = ClipboardTransferReports()
        service.reporter = reports.reporter
        instance.clipboardService = service
        let coordinator = ClipboardPassthroughCoordinator(
            instance: instance, publisher: publisher, reporter: reports.reporter,
            pasteboard: pasteboard)
        return Harness(
            coordinator: coordinator, instance: instance, service: service,
            pasteboard: pasteboard, publisher: publisher, reports: reports)
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

    private func makeScratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kernova-passthrough-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("A host clipboard change is forwarded to the guest on poll")
    func pollForwardsHostChange() {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        writeText("hello guest", to: h.pasteboard)
        h.coordinator.pollHostClipboard()

        #expect(h.service.grabbed.count == 1)
        #expect(h.service.grabbed.first?.text == "hello guest")
        #expect(h.service.clipboardContent.text == "hello guest")
    }

    @Test("An unchanged host clipboard is not re-forwarded")
    func pollSkipsUnchanged() {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        writeText("once", to: h.pasteboard)
        h.coordinator.pollHostClipboard()
        h.coordinator.pollHostClipboard()  // change count unchanged

        #expect(h.service.grabbed.count == 1)
    }

    @Test("A copy during an outage is forwarded once the redial's service reconnects")
    func copyDuringOutageIsForwardedAfterReconnect() {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        // The channel went down (the guest closed it on reconnect) and the
        // service settled — no poll may record the change count while
        // disconnected, or the copy below would never be noticed once a fresh
        // service comes up.
        h.service.isConnected = false
        writeText("copied during the outage", to: h.pasteboard)
        h.coordinator.pollHostClipboard()
        #expect(h.service.grabbed.isEmpty)

        // The accept path swaps in a fresh service on redial.
        let reconnected = FakePassthroughService()
        reconnected.reporter = h.reports.reporter
        h.instance.clipboardService = reconnected
        h.coordinator.pollHostClipboard()

        #expect(reconnected.grabbed.count == 1)
        #expect(reconnected.grabbed.first?.text == "copied during the outage")
    }

    @Test("A forward the transport never delivered is re-offered until it lands")
    func undeliveredForwardIsRetried() {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        // The send failed on a connection that still reports itself up — a
        // verdict only the transport's own outcome carries.
        h.service.grabOutcome = .undelivered
        writeText("never left the host", to: h.pasteboard)
        h.coordinator.pollHostClipboard()
        #expect(h.service.grabbed.count == 1)

        // Same copy, same change count: the poll must offer it again rather than
        // read the count as already spent.
        h.coordinator.pollHostClipboard()
        #expect(h.service.grabbed.count == 2)

        h.service.grabOutcome = .settled
        h.coordinator.pollHostClipboard()
        #expect(h.service.grabbed.count == 3)
        #expect(h.service.grabbed.last?.text == "never left the host")

        // Landed — the count is settled and the retries stop.
        h.coordinator.pollHostClipboard()
        #expect(h.service.grabbed.count == 3)
    }

    @Test("Our own inbound publish is absorbed, not re-forwarded (echo suppression)")
    func echoSuppressed() async {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        // Simulate a guest offer landing and publish it to the host pasteboard —
        // exactly what the inbound path (or a manual "Copy to Mac") does through
        // the shared publisher.
        h.service.clipboardContent = ClipboardContent(text: "from guest")
        let outcome = await h.publisher.publish(from: h.service)
        guard case .written = outcome else {
            Issue.record("Expected the publish to land on the pasteboard, got \(outcome)")
            return
        }

        // The poll must recognize its own write and not offer it back to the guest.
        h.coordinator.pollHostClipboard()
        #expect(h.service.grabbed.isEmpty)
    }

    @Test("a copied zero-byte file is forwarded like any other, with nothing noted")
    func pollForwardsZeroByteFile() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let empty = directory.appendingPathComponent("empty.txt")
        try Data().write(to: empty)
        writeFileURLs([empty], to: h.pasteboard)

        h.coordinator.pollHostClipboard()
        try await h.service.grabRecorded.wait { !h.service.grabbed.isEmpty }

        #expect(h.service.grabbed.last?.representations.map(\.filename) == ["empty.txt"])
        #expect(h.service.grabbed.last?.representations.first?.byteCount == 0)
        #expect(h.reports.failure == nil)
    }

    @Test("a forward the intake could not fully read surfaces the skip as an issue")
    func pollSurfacesIntakeSkipNote() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = directory.appendingPathComponent("kept.txt")
        let doomed = directory.appendingPathComponent("doomed.txt")
        try Data("kept".utf8).write(to: kept)
        try Data("doomed".utf8).write(to: doomed)
        writeFileURLs([kept, doomed], to: h.pasteboard)

        // The poll reads the URLs synchronously and stats them on a Task that
        // cannot start until this method suspends — so deleting here reproduces
        // exactly the race that leaves a forward carrying fewer files than were
        // copied, with no gesture to report it back to.
        h.coordinator.pollHostClipboard()
        try FileManager.default.removeItem(at: doomed)

        try await h.reports.waitForFailure()
        #expect(h.service.grabbed.last?.representations.map(\.filename) == ["kept.txt"])
        #expect(h.reports.failure == .itemsSkipped(note: "Skipped 1 unreadable item"))
    }

    @Test("a forward whose every item went unreadable surfaces the rejection")
    func pollSurfacesWholeCopyRejection() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let doomed = directory.appendingPathComponent("doomed.txt")
        try Data("doomed".utf8).write(to: doomed)
        writeFileURLs([doomed], to: h.pasteboard)

        // The total of the partial case: nothing resolves, so nothing is
        // forwarded and the guest is left with a copy that never arrived.
        h.coordinator.pollHostClipboard()
        try FileManager.default.removeItem(at: doomed)

        try await h.reports.waitForFailure()
        #expect(h.service.grabbed.isEmpty)
        #expect(h.reports.failure == .itemsSkipped(note: "Couldn't read the dropped item"))
    }

    @Test("a file deleted before the poll reads the pasteboard is reported too")
    func pollSurfacesPrePollLoss() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = directory.appendingPathComponent("kept.txt")
        let doomed = directory.appendingPathComponent("doomed.txt")
        try Data("kept".utf8).write(to: kept)
        try Data("doomed".utf8).write(to: doomed)
        writeFileURLs([kept, doomed], to: h.pasteboard)

        // The mirror of `pollSurfacesIntakeSkipNote`: deleting *before* the poll
        // means the intake's existence check drops the item, not the off-actor
        // stat. The user-visible loss is identical, so the report must be too.
        try FileManager.default.removeItem(at: doomed)
        h.coordinator.pollHostClipboard()

        try await h.reports.waitForFailure()
        #expect(h.service.grabbed.last?.representations.map(\.filename) == ["kept.txt"])
        #expect(h.reports.failure == .itemsSkipped(note: "Skipped 1 unreadable item"))
    }

    @Test("a copy whose every file vanished before the poll surfaces the rejection")
    func pollSurfacesPrePollWholeCopyLoss() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let doomed = directory.appendingPathComponent("doomed.txt")
        try Data("doomed".utf8).write(to: doomed)
        writeFileURLs([doomed], to: h.pasteboard)

        // A stale clipboard — the copy's file already gone when passthrough
        // connects and forwards the current clipboard whatever its age.
        try FileManager.default.removeItem(at: doomed)
        h.coordinator.pollHostClipboard()

        try await h.reports.waitForFailure()
        #expect(h.service.grabbed.isEmpty)
        #expect(h.reports.failure == .itemsSkipped(note: "Couldn't read the dropped item"))
    }

    @Test("a text-only transport's blanket file rejection is not reported")
    func pollStaysQuietForTextOnlyTransport() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }
        h.service.supportsBinaryRepresentations = false

        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: file)
        writeFileURLs([file], to: h.pasteboard)

        // Wait on the resolve *completing*, not on a bounded sleep: the rejection
        // branch runs on an unstructured Task, so a sleep that outruns a loaded
        // scheduler would assert "no issue" before the branch that could raise
        // one had run, and pass for the wrong reason.
        var resolveCompleted = false
        let resolved = AsyncGate()
        h.coordinator.onForwardResolvedForTesting = {
            resolveCompleted = true
            resolved.notify()
        }
        h.coordinator.pollHostClipboard()
        try await resolved.wait { resolveCompleted }

        // A Linux guest rejects every file copy by design, so reporting here
        // would fire on each one rather than on anything the user can act on.
        #expect(h.service.grabbed.isEmpty)
        #expect(h.reports.failure == nil)
    }

    @Test("A file copy whose service settles mid-resolve reaches the reconnected one")
    func fileCopyLostMidResolveIsRetried() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: file)
        writeFileURLs([file], to: h.pasteboard)

        var resolveCompleted = false
        let resolved = AsyncGate()
        h.coordinator.onForwardResolvedForTesting = {
            resolveCompleted = true
            resolved.notify()
        }

        // The resolve's continuation needs the main actor this test holds, so the
        // channel dies strictly between the poll's read and the offer it leads
        // to — the window the change count used to be consumed in.
        h.coordinator.pollHostClipboard()
        h.service.isConnected = false
        try await resolved.wait { resolveCompleted }
        #expect(h.service.grabbed.isEmpty)

        // The redial installs a fresh service, and the copy is still outstanding.
        let reconnected = FakePassthroughService()
        reconnected.reporter = h.reports.reporter
        h.instance.clipboardService = reconnected
        resolveCompleted = false
        h.coordinator.pollHostClipboard()
        try await resolved.wait { resolveCompleted }

        #expect(reconnected.grabbed.map { $0.representations.map(\.filename) } == [["notes.txt"]])
    }

    @Test("A poll during an in-flight file resolve starts no second walk of the same copy")
    func pollDuringResolveForwardsOnce() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: file)
        writeFileURLs([file], to: h.pasteboard)

        var resolveCompleted = false
        let resolved = AsyncGate()
        h.coordinator.onForwardResolvedForTesting = {
            resolveCompleted = true
            resolved.notify()
        }

        // Both polls run before the resolve's Task can start: leaving the copy
        // retryable must not turn every tick of a multi-second folder walk into
        // another walk.
        h.coordinator.pollHostClipboard()
        h.coordinator.pollHostClipboard()
        try await resolved.wait { resolveCompleted }
        #expect(h.service.grabbed.count == 1)

        // And once it has settled, the copy is not offered a second time.
        h.coordinator.pollHostClipboard()
        #expect(h.service.grabbed.count == 1)
    }

    @Test("A file resolve the host clipboard outran offers nothing and settles nothing")
    func supersededResolveIsDropped() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: file)
        writeFileURLs([file], to: h.pasteboard)

        var resolveCompleted = false
        let resolved = AsyncGate()
        h.coordinator.onForwardResolvedForTesting = {
            resolveCompleted = true
            resolved.notify()
        }

        // The user copies something else while the folder walk is still running.
        h.coordinator.pollHostClipboard()
        writeText("copied over the folder", to: h.pasteboard)
        try await resolved.wait { resolveCompleted }

        // Offering the walk's result now would put content nobody holds on the
        // guest's clipboard.
        #expect(h.service.grabbed.isEmpty)

        // And settling the superseded count must not roll the record backwards:
        // the copy that replaced it still forwards.
        h.coordinator.pollHostClipboard()
        #expect(h.service.grabbed.map(\.text) == ["copied over the folder"])
    }

    @Test("A file resolve outliving its passthrough session neither offers nor settles")
    func resolveOutlivingItsSessionIsDropped() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: file)
        writeFileURLs([file], to: h.pasteboard)

        var resolveCompleted = false
        let resolved = AsyncGate()
        h.coordinator.onForwardResolvedForTesting = {
            resolveCompleted = true
            resolved.notify()
        }

        // Passthrough switched off and back on while the walk runs, so its
        // resolve lands in a session that has already reseeded to `-1`.
        h.coordinator.start()
        h.coordinator.pollHostClipboard()
        h.coordinator.stop()
        h.coordinator.start()
        defer { h.coordinator.stop() }

        try await resolved.wait { resolveCompleted }
        #expect(h.service.grabbed.isEmpty)

        // Nothing was recorded either: the fresh session's first poll still
        // forwards the current clipboard, which a stale record would suppress.
        resolveCompleted = false
        h.coordinator.pollHostClipboard()
        try await resolved.wait { resolveCompleted }
        #expect(h.service.grabbed.map { $0.representations.map(\.filename) } == [["notes.txt"]])
    }

    @Test("An undelivered forward files no transfer report until its retry lands")
    func undeliveredForwardDefersItsSkipNote() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = directory.appendingPathComponent("kept.txt")
        let doomed = directory.appendingPathComponent("doomed.txt")
        try Data("kept".utf8).write(to: kept)
        try Data("doomed".utf8).write(to: doomed)
        writeFileURLs([kept, doomed], to: h.pasteboard)

        var resolveCompleted = false
        let resolved = AsyncGate()
        h.coordinator.onForwardResolvedForTesting = {
            resolveCompleted = true
            resolved.notify()
        }

        h.service.grabOutcome = .undelivered
        h.coordinator.pollHostClipboard()
        try FileManager.default.removeItem(at: doomed)
        try await resolved.wait { resolveCompleted }

        // Nothing reached the guest, so nothing partial did either — reporting
        // here would file one refusal per poll until the retry lands.
        #expect(h.service.grabbed.count == 1)
        #expect(h.reports.refusals.isEmpty)

        h.service.grabOutcome = .settled
        resolveCompleted = false
        h.coordinator.pollHostClipboard()
        try await resolved.wait { resolveCompleted }

        #expect(h.reports.refusals.count == 1)
        #expect(h.reports.failure == .itemsSkipped(note: "Skipped 1 unreadable item"))
    }

    @Test("A transient-marked snapshot is not forwarded")
    func transientMarkerSkipped() {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        let item = NSPasteboardItem()
        item.setString("secret-ish", forType: .string)
        let transientType = NSPasteboard.PasteboardType(ClipboardSnapshotPolicy.transientMarkerUTI)
        item.setData(Data("1".utf8), forType: transientType)
        h.pasteboard.clearContents()
        h.pasteboard.writeObjects([item])

        h.coordinator.pollHostClipboard()
        #expect(h.service.grabbed.isEmpty)
    }

    @Test("A new inbound guest offer is auto-published to the host pasteboard")
    func inboundOfferPublishesToHost() async throws {
        let h = makeHarness()
        defer { h.pasteboard.releaseGlobally() }

        // Event-driven: the gate fires when the inbound auto-publish completes, so
        // the wait resolves on the publish itself — never a poll deadline — even
        // when a contended CI main actor delays the observation → publish Task
        // chain (docs/TESTING.md "Async waits in tests"). The generous timeout is a
        // stuck-condition backstop, not the success deadline.
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
        // Settle the outbound poll first, so this models a session that has been
        // running rather than one started microseconds ago. Otherwise the 0.5 s
        // timer's first tick — which forwards unconditionally — lands mid-test on
        // a loaded machine and overwrites the service buffer with host content.
        h.coordinator.pollHostClipboard()

        h.service.refusesOverCopyBudget = true
        h.service.simulateInboundOffer(ClipboardContent(text: "over the cap"))
        try await published.wait { publishCompleted }
        return h
    }

    @Test("raising the ceiling republishes the offer the old one refused")
    func raisingTheCeilingRepublishes() async throws {
        let preferences = makeEphemeralPreferences(suiteName: "test.kernova.passthrough-raise")
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
        let preferences = makeEphemeralPreferences(suiteName: "test.kernova.passthrough-user-copy")
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

        // Bounded negative check, as in `stopHaltsInboundPublish`. RATIONALE:
        // asserting the *absence* of an event needs a bounded wait; the short
        // sleep is the backstop, not a success deadline.
        try await Task.sleep(for: .milliseconds(300))
        #expect(!republished)
        #expect(h.pasteboard.string(forType: .string) == "what the user copied")
    }

    @Test("a ceiling that did not rise republishes nothing")
    func anUnraisedCeilingRepublishesNothing() async throws {
        let preferences = makeEphemeralPreferences(suiteName: "test.kernova.passthrough-lower")
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

        // Bounded negative check, as in `stopHaltsInboundPublish`. RATIONALE:
        // asserting the *absence* of an event needs a bounded wait; the short
        // sleep is the backstop, not a success deadline.
        try await Task.sleep(for: .milliseconds(300))
        #expect(!republished)
        #expect(h.pasteboard.string(forType: .string) == "previous host content")
    }

    /// A promised-offer service: `materializeForCopy` returns metadata-only
    /// promises, and the paste-time provider surface counts its fires so a test
    /// can prove the publish itself moved no bytes.
    @MainActor
    @Observable
    final class PromisedPassthroughService: ClipboardServicing, ClipboardPromiseServing {
        var clipboardContent: ClipboardContent = .empty
        var isConnected = true
        var supportsBinaryRepresentations = true
        private(set) var inboundOfferSeq: UInt64 = 0
        /// What the next `materializeForCopy` promises.
        var promises: [CopyToMacPromise] = []

        func stop() {}
        func grabIfChanged() -> ClipboardGrabOutcome { .settled }
        func clearBuffer() { clipboardContent = .empty }
        func materializeForCopy() -> [CopyToMacItem] { promises.map { .promised($0) } }

        func simulateInboundOffer(promising promises: [CopyToMacPromise]) {
            self.promises = promises
            inboundOfferSeq &+= 1
        }

        // Paste-time provider surface: every fire is a byte pull, counted here.
        @ObservationIgnored private let fireLock = NSLock()
        @ObservationIgnored nonisolated(unsafe) private var fireCountStorage = 0
        nonisolated var pasteFireCount: Int { fireLock.withLock { fireCountStorage } }
        nonisolated private func recordFire() { fireLock.withLock { fireCountStorage += 1 } }

        nonisolated func serveFileURL(generation: UInt64, repIndex: Int) -> URL? {
            recordFire()
            return nil
        }
        nonisolated func serveData(generation: UInt64, repIndex: Int, uti: String) -> Data? {
            recordFire()
            return Data("promised bytes".utf8)
        }
    }

    @Test("A promised inbound offer auto-publishes without moving any bytes")
    func inboundPromisedOfferPublishesWithoutPulling() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KernovaTest-\(UUID().uuidString)"))
        pasteboard.clearContents()
        defer { pasteboard.releaseGlobally() }
        let publisher = HostClipboardPublisher(
            writePasteboard: pasteboard, providerRegistry: LazyClipboardProviderRegistry())
        let config = VMConfiguration(name: "Promised VM", guestOS: .macOS, bootMode: .macOS)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        let instance = VMInstance(configuration: config, bundleURL: bundleURL)
        let service = PromisedPassthroughService()
        instance.clipboardService = service
        let coordinator = ClipboardPassthroughCoordinator(
            instance: instance, publisher: publisher, reporter: instance.clipboardTransfers,
            pasteboard: pasteboard)

        let published = AsyncGate()
        coordinator.onInboundPublishedForTesting = { published.notify() }
        coordinator.start()
        defer { coordinator.stop() }

        let baseline = pasteboard.changeCount
        service.simulateInboundOffer(promising: [
            CopyToMacPromise(
                generation: 4, repIndex: 0, uti: ClipboardContent.utf8TextUTI, filename: "",
                isInline: true),
            CopyToMacPromise(
                generation: 4, repIndex: 1, uti: "public.data", filename: "big.bin",
                isInline: false),
        ])

        // The auto-publish lands promised items on the pasteboard…
        try await published.wait { pasteboard.changeCount > baseline }
        let textType = NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)
        let types = pasteboard.pasteboardItems?.flatMap(\.types) ?? []
        #expect(types.contains(textType))
        #expect(types.contains(.fileURL))
        // …without a single byte pull: publishing is metadata-only.
        #expect(service.pasteFireCount == 0)

        // Only a consumer's flavor read fires a pull.
        #expect(pasteboard.data(forType: textType) == Data("promised bytes".utf8))
        #expect(service.pasteFireCount == 1)
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

        // Bounded negative check: stop() cancelled the observation, so no publish
        // Task fires. RATIONALE: asserting the *absence* of an event needs a
        // bounded wait; the short sleep is the backstop, not a success deadline.
        try await Task.sleep(for: .milliseconds(300))
        #expect(!publishedAfterStop)
        #expect(h.pasteboard.changeCount == baseline)
    }
}
