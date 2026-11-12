import AppKit
import Foundation
import KernovaTestSupport
import KernovaTransferProgress
import Testing

@testable import KernovaCore
@testable import KernovaKit

/// Exercises `HostClipboardPublisher.publish(from:)`'s cancellation contract:
/// what a publish has done, and must not have done, when the task running it is
/// cancelled before its pasteboard write.
///
/// Everything runs over a private `NSPasteboard(name:)` and an isolated provider
/// registry, so the real write/promise path is exercised without touching the
/// developer's clipboard.
@Suite("HostClipboardPublisher cancellation", .caseScoped)
@MainActor
struct HostClipboardPublisherCancellationTests {
    /// Minimal in-memory `ClipboardServicing` that counts the publish's one
    /// request for items — `guestClipboardItems` is where a real transport
    /// reports its refusals and retires its offer, so a publish nobody is
    /// waiting on must never reach it.
    @MainActor
    @Observable
    final class CountingService: ClipboardServicing {
        var guestContent: ClipboardContent
        var isConnected = true
        var supportsBinaryRepresentations = true
        let inboundOfferSeq: UInt64 = 0
        private(set) var materializeCount = 0

        init(content: ClipboardContent) { guestContent = content }

        func stop() {}
        func copyMacClipboardToGuest(_ snapshot: ClipboardOfferSource) -> ClipboardTransferFailure? { nil }
        func guestClipboardCopy(_ write: @escaping @MainActor (GuestCopyContents) -> Void) async -> GuestClipboardCopy {
            .nothing
        }
        func offerHostCopy(_ copy: ClipboardOfferSource) async -> ClipboardGrabOutcome { .settled }

        func guestClipboardItems() -> [CopyToMacItem] {
            materializeCount += 1
            return guestContent.representations.map { .resolved($0) }
        }
    }

    private struct Fixture {
        let publisher: HostClipboardPublisher
        let pasteboard: NSPasteboard
        let registry: LazyClipboardProviderRegistry
        let service: CountingService
    }

    private let stagingRoot = TestStagingRoot()

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
                pasteboard: pasteboard, providerRegistry: registry,
                stagingRoot: stagingRoot.root),
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

/// Maps what `guestClipboardItems` hands `HostClipboardPublisher.publish(from:)`,
/// and what the pasteboard write does, to each terminal outcome.
@Suite("HostClipboardPublisher outcomes", .caseScoped)
@MainActor
struct HostClipboardPublisherOutcomeTests {
    /// Hands the publisher a fixed `guestClipboardItems` result.
    @MainActor
    @Observable
    final class ScriptedService: ClipboardServicing {
        var isConnected = true
        var supportsBinaryRepresentations = true
        let inboundOfferSeq: UInt64 = 0
        let copyItems: [CopyToMacItem]

        init(copyItems: [CopyToMacItem]) { self.copyItems = copyItems }

        func stop() {}
        func copyMacClipboardToGuest(_ snapshot: ClipboardOfferSource) -> ClipboardTransferFailure? { nil }
        func guestClipboardCopy(_ write: @escaping @MainActor (GuestCopyContents) -> Void) async -> GuestClipboardCopy {
            .nothing
        }
        func offerHostCopy(_ copy: ClipboardOfferSource) async -> ClipboardGrabOutcome { .settled }
        func guestClipboardItems() -> [CopyToMacItem] { copyItems }
    }

    private let stagingRoot = TestStagingRoot()

    private func publish(
        _ copyItems: [CopyToMacItem], failWrite: Bool = false
    ) async throws -> HostPublishOutcome {
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let pasteboard = FakePasteboard()
        if failWrite { pasteboard.failNextWrite() }
        let publisher = HostClipboardPublisher(
            pasteboard: pasteboard, providerRegistry: registry,
            stagingRoot: stagingRoot.root)
        return try await publisher.publish(from: ScriptedService(copyItems: copyItems))
    }

    private static let inline = ClipboardContent.Representation(
        uti: ClipboardContent.utf8TextUTI, data: Data("note".utf8))

    @Test("A payload that stages nothing is a staging failure")
    func unstageablePayloadFailsStaging() async throws {
        // A file payload whose bytes were never pulled stages no file, so the
        // publish plans an item and ends up with no pasteboard spec.
        let unstageable = ClipboardContent.Representation(
            uti: "public.data", source: .pendingRemote(byteCount: 10), filename: "big.bin")
        let outcome = try await publish([.resolved(unstageable)])
        guard case .stagingFailed = outcome else {
            Issue.record("Expected .stagingFailed, got \(outcome)")
            return
        }
    }

    @Test("A write beside dropped files carries their reasons")
    func writtenCarriesDroppedReasons() async throws {
        let outcome = try await publish([.resolved(Self.inline), .droppedFile(.overPasteBudget)])
        guard case .written(let count, let dropped) = outcome else {
            Issue.record("Expected .written, got \(outcome)")
            return
        }
        #expect(count == 1)
        #expect(dropped == [.overPasteBudget])
    }
}
