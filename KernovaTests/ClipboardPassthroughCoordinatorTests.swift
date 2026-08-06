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
@Suite("ClipboardPassthroughCoordinator")
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
        var lastTransferIssue: ClipboardTransferIssue?
        private(set) var inboundOfferSeq: UInt64 = 0

        /// Every content handed to `grabIfChanged()` by the poll, in order.
        var grabbed: [ClipboardContent] = []

        /// Makes `materializeForCopy` refuse the way `VsockClipboardService` does
        /// over the deadline-safe cap: every rep dropped, and the transfer issue
        /// raised in the same step.
        var refusesOverCopyBudget = false

        func stop() {}
        func grabIfChanged() { grabbed.append(clipboardContent) }
        func clearBuffer() { clipboardContent = .empty }

        func materializeForCopy() -> [CopyToMacItem] {
            guard refusesOverCopyBudget else {
                return clipboardContent.representations.map { .resolved($0) }
            }
            lastTransferIssue = .overCopyBudget(limitBytes: ClipboardPasteLimit.defaultBytes)
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
    }

    private func makeHarness() -> Harness {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KernovaTest-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let publisher = HostClipboardPublisher(
            writePasteboard: pasteboard, providerRegistry: LazyClipboardProviderRegistry())
        let config = VMConfiguration(name: "Passthrough VM", guestOS: .macOS, bootMode: .macOS)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        let instance = VMInstance(configuration: config, bundleURL: bundleURL)
        let service = FakePassthroughService()
        instance.clipboardService = service
        let coordinator = ClipboardPassthroughCoordinator(
            instance: instance, publisher: publisher, pasteboard: pasteboard)
        return Harness(
            coordinator: coordinator, instance: instance, service: service,
            pasteboard: pasteboard, publisher: publisher)
    }

    /// Places a plain-text item on `pasteboard`.
    private func writeText(_ text: String, to pasteboard: NSPasteboard) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
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

        try await published.wait { h.service.lastTransferIssue != nil }
        #expect(h.pasteboard.changeCount == baseline)
        #expect(h.pasteboard.string(forType: .string) == "previous host content")
        // No gesture outcome exists on this path — the coordinator discards
        // everything but the change count — so the issue is the whole report.
        #expect(
            h.service.lastTransferIssue?.kind
                == .localFailure(
                    code: ClipboardErrorCode.copyTooLarge.rawValue,
                    message: ClipboardTransferIssue.overCopyBudgetMessage(limitBytes: ClipboardPasteLimit.defaultBytes))
        )
    }

    /// A promised-offer service: `materializeForCopy` returns metadata-only
    /// promises, and the paste-time provider surface counts its fires so a test
    /// can prove the publish itself moved no bytes.
    @MainActor
    @Observable
    final class PromisedPassthroughService: ClipboardServicing, ClipboardPasteboardRepProviding {
        var clipboardContent: ClipboardContent = .empty
        var isConnected = true
        var supportsBinaryRepresentations = true
        var lastTransferIssue: ClipboardTransferIssue?
        private(set) var inboundOfferSeq: UInt64 = 0
        /// What the next `materializeForCopy` promises.
        var promises: [CopyToMacPromise] = []

        func stop() {}
        func grabIfChanged() {}
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

        nonisolated func copyToMacFileURL(generation: UInt64, repIndex: Int) -> URL? {
            recordFire()
            return nil
        }
        nonisolated func copyToMacData(generation: UInt64, repIndex: Int, uti: String) -> Data? {
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
            instance: instance, publisher: publisher, pasteboard: pasteboard)

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
