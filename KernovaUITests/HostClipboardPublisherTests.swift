import AppKit
import Foundation
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaCore
@testable import KernovaKit

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
        let inboundOfferSeq: UInt64 = 0
        let connectionEpoch: UInt64 = 0
        let connectionStartChangeCount: Int? = nil
        let snapshotStaging: ClipboardFileStaging? = nil
        let clipboardConnection: ClipboardConnectionID? = nil
        let copyItems: [CopyToMacItem]

        init(copyItems: [CopyToMacItem]) { self.copyItems = copyItems }

        func passthroughStopped() {}
        func hostCopyOffersNothing() {}
        func reservePromiseDestination() -> URL? { nil }
        func copyMacClipboardToGuest(_ snapshot: ClipboardOfferSource) -> ClipboardTransferFailure? { nil }
        func guestClipboardCopy(_ write: @escaping @MainActor (GuestCopyContents) -> Void) async -> GuestClipboardCopy {
            .nothing
        }
        func offerHostCopy(_ copy: ClipboardOfferSource) {}
        func guestClipboardItems() -> [CopyToMacItem] { copyItems }
    }

    /// A puller nothing in these tests asks.
    final class UnaskedPuller: ClipboardItemPulling, Sendable {
        func whenEnded(_ handler: @escaping @Sendable () -> Void) {}
        func pullBytes(item: Int, representation: Int, completion: @escaping @Sendable (Data?) -> Void) {
            completion(nil)
        }
        func pullFile(item: Int, representation: Int, completion: @escaping @Sendable (URL?) -> Void) {
            completion(nil)
        }
    }

    /// A live offer of one inline text representation.
    private static var textOffer: CopyToMacItem {
        var representation = Representation()
        representation.type = TypeDescriptor(appleUTI: ClipboardContent.utf8TextUTI)
        representation.storage = .inline
        var item = OfferedItem()
        item.representations = [representation]
        return .offer(
            CopyToMacOffer(
                serving: .init(token: Data(repeating: 3, count: 16), connection: ClipboardConnectionID()),
                items: [item], concealed: false, servingFileURLs: true, puller: UnaskedPuller()))
    }

    private func publish(
        _ copyItems: [CopyToMacItem], on pasteboard: FakePasteboard = FakePasteboard()
    ) -> HostPublishOutcome {
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let publisher = HostClipboardPublisher(pasteboard: pasteboard, providerRegistry: registry)
        return publisher.publish(from: ScriptedService(copyItems: copyItems))
    }

    @Test("A write beside dropped files carries their reasons")
    func writtenCarriesDroppedReasons() {
        let outcome = publish([Self.textOffer, .droppedFile(.overPasteBudget)])
        guard case .written(let count, let dropped) = outcome else {
            Issue.record("Expected .written, got \(outcome)")
            return
        }
        #expect(count == 1)
        #expect(dropped == [.overPasteBudget])
    }

    @Test("Only dropped files serve nothing, and leave the pasteboard as it was")
    func droppedFilesAloneServeNothing() {
        let pasteboard = FakePasteboard()
        let baseline = pasteboard.changeCount
        let outcome = publish([.droppedFile(.overPasteBudget)], on: pasteboard)
        guard case .nothingServed(let reasons) = outcome else {
            Issue.record("Expected .nothingServed, got \(outcome)")
            return
        }
        #expect(reasons == [.overPasteBudget])
        #expect(pasteboard.changeCount == baseline)
    }

    @Test("A write the pasteboard refuses is a write failure")
    func refusedWriteFails() {
        let pasteboard = FakePasteboard()
        pasteboard.failNextWrite()
        let outcome = publish([Self.textOffer], on: pasteboard)
        guard case .writeFailed = outcome else {
            Issue.record("Expected .writeFailed, got \(outcome)")
            return
        }
    }
}
