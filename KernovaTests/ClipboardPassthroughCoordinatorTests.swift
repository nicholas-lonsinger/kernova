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
        var supportsDirectoryTree = false
        var lastTransferIssue: ClipboardTransferIssue?
        private(set) var inboundOfferSeq: UInt64 = 0

        /// Every content handed to `grabIfChanged()` by the poll, in order.
        var grabbed: [ClipboardContent] = []

        func stop() {}
        func grabIfChanged() { grabbed.append(clipboardContent) }
        func clearBuffer() { clipboardContent = .empty }
        // materializeForCopy uses the protocol-extension default (resolved reps).

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
        #expect(outcome.didWrite)

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
