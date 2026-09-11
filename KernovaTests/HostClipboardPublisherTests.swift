import AppKit
import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova
@testable import KernovaKit

/// Exercises `HostClipboardPublisher.publish(from:)`'s cancellation contract:
/// what a publish has done, and must not have done, when the task running it is
/// cancelled before its pasteboard write.
///
/// Everything runs over a private `NSPasteboard(name:)` and an isolated provider
/// registry, so the real write/promise path is exercised without touching the
/// developer's clipboard.
@Suite("HostClipboardPublisher cancellation", .admissionGated)
@MainActor
struct HostClipboardPublisherCancellationTests {
    /// Minimal in-memory `ClipboardServicing` that counts the publish's one
    /// request for items — `materializeForCopy` is where a real transport
    /// reports its refusals and retires its offer, so a publish nobody is
    /// waiting on must never reach it.
    @MainActor
    @Observable
    final class CountingService: ClipboardServicing {
        var clipboardContent: ClipboardContent
        var isConnected = true
        var supportsBinaryRepresentations = true
        private(set) var materializeCount = 0

        init(content: ClipboardContent) { clipboardContent = content }

        func stop() {}
        func grabIfChanged() -> ClipboardGrabOutcome { .settled }
        func clearBuffer() { clipboardContent = .empty }

        func materializeForCopy() -> [CopyToMacItem] {
            materializeCount += 1
            return clipboardContent.representations.map { .resolved($0) }
        }
    }

    private struct Fixture {
        let publisher: HostClipboardPublisher
        let pasteboard: NSPasteboard
        let registry: LazyClipboardProviderRegistry
        let service: CountingService
    }

    /// What the user already has on their Mac clipboard — a cancelled publish
    /// has to leave it exactly there.
    private static let hostContent = "the user's own copy"

    private func makeFixture(text: String = "guest copied this") -> Fixture {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KernovaTest-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(Self.hostContent, forType: .string)
        pasteboard.writeObjects([item])
        let registry = LazyClipboardProviderRegistry()
        return Fixture(
            publisher: HostClipboardPublisher(
                writePasteboard: pasteboard, providerRegistry: registry),
            pasteboard: pasteboard, registry: registry,
            service: CountingService(content: ClipboardContent(text: text)))
    }

    @Test("A publish cancelled before it begins asks the service for nothing")
    func cancelBeforeStartSkipsMaterialize() async {
        let f = makeFixture()
        defer { f.pasteboard.releaseGlobally() }
        let baseline = f.pasteboard.changeCount

        // Nothing suspends between the launch and the cancel, so the body
        // provably has not begun when the cancellation lands.
        let publish = Task { @MainActor in try await f.publisher.publish(from: f.service) }
        publish.cancel()

        await #expect(throws: CancellationError.self) { try await publish.value }
        #expect(f.service.materializeCount == 0)
        #expect(f.pasteboard.changeCount == baseline)
        #expect(f.pasteboard.string(forType: .string) == Self.hostContent)
        #expect(f.publisher.lastWriteChangeCount == nil)
    }

    @Test("A publish cancelled at its write leaves the pasteboard and the registry untouched")
    func cancelAtWriteWritesNothing() async throws {
        let f = makeFixture()
        defer { f.pasteboard.releaseGlobally() }
        defer { f.registry.releaseAllForTesting() }
        let baseline = f.pasteboard.changeCount

        let atWrite = AsyncGate()
        let resumed = AsyncGate()
        var isAtWrite = false
        var isReleased = false
        f.publisher.beforePasteboardWriteForTesting = {
            isAtWrite = true
            atWrite.notify()
            // A fired backstop only lets the publish write, which the assertions
            // below catch — this hides no stuck condition.
            try? await resumed.wait { isReleased }
        }

        let publish = Task { @MainActor in try await f.publisher.publish(from: f.service) }
        try await atWrite.wait { isAtWrite }
        publish.cancel()
        isReleased = true
        resumed.notify()

        await #expect(throws: CancellationError.self) { try await publish.value }
        // It planned its items — the cancel arrived afterwards — and stopped
        // there: no write, and so no provider handed to the registry.
        #expect(f.service.materializeCount == 1)
        #expect(f.pasteboard.changeCount == baseline)
        #expect(f.pasteboard.string(forType: .string) == Self.hostContent)
        #expect(f.publisher.lastWriteChangeCount == nil)
        #expect(f.registry.countForTesting == 0)
    }

    @Test("An uncancelled publish writes its items and registers their providers")
    func uncancelledPublishWrites() async throws {
        let f = makeFixture(text: "lazy bytes")
        defer { f.pasteboard.releaseGlobally() }
        defer { f.registry.releaseAllForTesting() }
        let baseline = f.pasteboard.changeCount

        let outcome = try await f.publisher.publish(from: f.service)

        guard case .written = outcome else {
            Issue.record("Expected the publish to land on the pasteboard, got \(outcome)")
            return
        }
        #expect(f.pasteboard.changeCount > baseline)
        #expect(f.publisher.lastWriteChangeCount == f.pasteboard.changeCount)
        #expect(f.registry.countForTesting == 1)
        let textType = NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)
        #expect(f.pasteboard.data(forType: textType) == Data("lazy bytes".utf8))
    }
}
