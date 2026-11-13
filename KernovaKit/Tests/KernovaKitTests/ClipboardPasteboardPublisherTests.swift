import AppKit
import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// The one place a clipboard publication reaches a pasteboard: how every write
/// is marked, what a failed one leaves behind, when a write is still this
/// publisher's to withdraw, and how a plan's promised types reach their bytes.
@Suite("ClipboardPasteboardPublisher", .caseScoped)
@MainActor
struct ClipboardPasteboardPublisherTests {
    private static let connection = ClipboardConnectionID()
    private let textUTI = ClipboardContent.utf8TextUTI
    private let offer = Data(repeating: 1, count: 16)
    private let otherOffer = Data(repeating: 2, count: 16)
    /// A write serving `offer`.
    private var servingOffer: ClipboardWriteSource {
        ClipboardWriteSource(serving: .init(token: offer, connection: Self.connection), parts: [])
    }

    private func makeSpec(_ uti: String, bytes: Data) -> ClipboardPasteboardPublisher.ItemSpec {
        ClipboardPasteboardPublisher.ItemSpec(types: [uti]) { _ in bytes }
    }

    // MARK: - Writing

    @Test("every write marks its contents host-only")
    func everyWriteIsMarkedHostOnly() {
        let pasteboard = FakeWritePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let publisher = ClipboardPasteboardPublisher(
            pasteboard: pasteboard, providerRegistry: registry)

        publisher.write([makeSpec(textUTI, bytes: Data("one".utf8))], source: servingOffer)
        publisher.write([makeSpec(textUTI, bytes: Data("two".utf8))], source: .init(serving: nil, parts: []))

        #expect(pasteboard.prepareCount == 2)
        #expect(pasteboard.lastPrepareOptions == .currentHostOnly)
    }

    @Test("a successful write hands its providers to the registry")
    func successfulWriteRetainsItsProviders() {
        let pasteboard = FakeWritePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let publisher = ClipboardPasteboardPublisher(
            pasteboard: pasteboard, providerRegistry: registry)

        #expect(
            publisher.write(
                [
                    makeSpec(textUTI, bytes: Data("one".utf8)),
                    makeSpec("public.rtf", bytes: Data("two".utf8)),
                ], source: servingOffer))

        #expect(registry.countForTesting == 2)
        #expect(publisher.lastWriteChangeCount == pasteboard.changeCount)
    }

    @Test("a failed write still latches the change it made, and retains nothing")
    func failedWriteLatchesItsChangeAndRetainsNothing() {
        let pasteboard = FakeWritePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let publisher = ClipboardPasteboardPublisher(
            pasteboard: pasteboard, providerRegistry: registry)
        pasteboard.failNextWrite()

        #expect(
            !publisher.write(
                [makeSpec(textUTI, bytes: Data("one".utf8))], source: servingOffer))

        // The prepare cleared the pasteboard and bumped its count, and that
        // change must never read as the user's own copy.
        #expect(publisher.lastWriteChangeCount == pasteboard.changeCount)
        #expect(registry.countForTesting == 0)
    }

    @Test("a failed write holds nothing, so there is nothing to take back")
    func failedWriteIsNotHeld() {
        let pasteboard = FakeWritePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let publisher = ClipboardPasteboardPublisher(
            pasteboard: pasteboard, providerRegistry: registry)
        pasteboard.failNextWrite()

        #expect(
            !publisher.write(
                [makeSpec(textUTI, bytes: Data("one".utf8))], source: servingOffer))

        // The prepare left an empty pasteboard, which is nobody's write…
        #expect(!publisher.holdsLastWrite)
        #expect(publisher.retractWrite(servingOffer: offer, withdrawing: .everyPromise) == nil)
        // …but the change it made still must not read as the user's own copy.
        #expect(publisher.lastWriteChangeCount == pasteboard.changeCount)
    }

    @Test("a write displaces the promise before it, and the registry lets those providers go")
    func supersedingWriteReleasesTheDisplacedProviders() {
        let pasteboard = FakeWritePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let publisher = ClipboardPasteboardPublisher(
            pasteboard: pasteboard, providerRegistry: registry)

        publisher.write(
            [
                makeSpec(textUTI, bytes: Data("one".utf8)),
                makeSpec("public.rtf", bytes: Data("two".utf8)),
            ], source: servingOffer)
        #expect(registry.countForTesting == 2)

        // The pasteboard finishes with the displaced providers, which is what
        // lets the registry drop them — otherwise every publication of a
        // session's life is retained for the process's.
        publisher.write([makeSpec(textUTI, bytes: Data("three".utf8))], source: servingOffer)
        #expect(registry.countForTesting == 1)

        #expect(publisher.retractWrite(servingOffer: offer, withdrawing: .everyPromise) == .cleared)
        #expect(registry.countForTesting == 0)
    }

    // MARK: - Holding the write

    @Test("the write is held only while nothing has replaced it")
    func holdsLastWriteTracksTheChangeCount() {
        let pasteboard = FakeWritePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let publisher = ClipboardPasteboardPublisher(
            pasteboard: pasteboard, providerRegistry: registry)

        #expect(!publisher.holdsLastWrite)
        publisher.write([makeSpec(textUTI, bytes: Data("one".utf8))], source: servingOffer)
        #expect(publisher.holdsLastWrite)

        // Somebody else wrote to the pasteboard.
        pasteboard.clearContents()
        #expect(!publisher.holdsLastWrite)
    }

    @Test("a retraction withdraws only a write still held that serves the offer it names")
    func retractionOnlyTakesBackAHeldWriteOfItsOffer() {
        let pasteboard = FakeWritePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let publisher = ClipboardPasteboardPublisher(
            pasteboard: pasteboard, providerRegistry: registry)

        publisher.write([makeSpec(textUTI, bytes: Data("one".utf8))], source: servingOffer)
        #expect(publisher.retractWrite(servingOffer: offer, withdrawing: .everyPromise) == .cleared)
        // The clear is the publisher's own write, which no poll may read as a copy.
        #expect(publisher.lastWriteChangeCount == pasteboard.changeCount)
        // Idempotent: the retracted write is forgotten.
        #expect(publisher.retractWrite(servingOffer: offer, withdrawing: .everyPromise) == nil)

        // A write serving no offer survives any offer's end.
        publisher.write([makeSpec(textUTI, bytes: Data("two".utf8))], source: .init(serving: nil, parts: []))
        #expect(publisher.retractWrite(servingOffer: offer, withdrawing: .everyPromise) == nil)
        #expect(publisher.holdsLastWrite)

        // Another offer's end never reaches a write serving this one.
        publisher.write([makeSpec(textUTI, bytes: Data("two".utf8))], source: servingOffer)
        #expect(publisher.retractWrite(servingOffer: otherOffer, withdrawing: .everyPromise) == nil)
        #expect(publisher.holdsLastWrite)

        // A pasteboard the user has written over since is theirs.
        publisher.write([makeSpec(textUTI, bytes: Data("three".utf8))], source: servingOffer)
        pasteboard.clearContents()
        #expect(publisher.retractWrite(servingOffer: offer, withdrawing: .everyPromise) == nil)
    }

    @Test(
        "a retraction keeps a write's data, but an item losing its file goes whole, and a concealed one keeps no promise"
    )
    func retractionKeepsDataButNotAFilesStandIns() {
        let pasteboard = FakeWritePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let publisher = ClipboardPasteboardPublisher(pasteboard: pasteboard, providerRegistry: registry)
        let marker = ClipboardSnapshotPolicy.concealedMarkerUTI
        let fileURL = ClipboardPasteboardPublisher.ItemSpec.fileURLType

        publisher.write(
            [
                // A file's item: its name as data, the file promised.
                ClipboardPasteboardPublisher.ItemSpec(data: [(textUTI, Data("name".utf8))], types: [fileURL]) { _ in
                    nil
                },
                // Text as data, a richer type promised.
                ClipboardPasteboardPublisher.ItemSpec(data: [(textUTI, Data("text".utf8))], types: ["public.rtf"]) {
                    _ in nil
                },
                // A concealed item: its marker as data, the text promised.
                ClipboardPasteboardPublisher.ItemSpec(data: [(marker, Data())], types: [textUTI]) { _ in nil },
            ], source: servingOffer)
        #expect(publisher.retractWrite(servingOffer: offer, withdrawing: .everyPromise) == .keptPart)
        #expect(pasteboard.promisedTypes.isEmpty)
        #expect(pasteboard.dataByItem == [[NSPasteboard.PasteboardType(textUTI): Data("text".utf8)]])
        #expect(publisher.lastWriteChangeCount == pasteboard.changeCount)
        #expect(publisher.retractWrite(servingOffer: offer, withdrawing: .everyPromise) == nil)
        #expect(registry.countForTesting == 0)
    }

    @Test(
        "a write promising nothing is withdrawn only when it holds a concealed item: that item goes whole, the rest stays",
        arguments: [ClipboardWithdrawal.unread, .everyPromise])
    func concealedDataGoesWholeAtAnyWithdrawal(_ withdrawal: ClipboardWithdrawal) {
        let pasteboard = FakeWritePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let publisher = ClipboardPasteboardPublisher(pasteboard: pasteboard, providerRegistry: registry)
        let marker = ClipboardSnapshotPolicy.concealedMarkerUTI
        let plain = ClipboardPasteboardPublisher.ItemSpec(data: [(textUTI, Data("plain".utf8))], types: []) { _ in nil }

        publisher.write([plain], source: servingOffer)
        #expect(publisher.retractWrite(servingOffer: offer, withdrawing: withdrawal) == nil)

        publisher.write(
            [
                ClipboardPasteboardPublisher.ItemSpec(
                    data: [(textUTI, Data("hunter2".utf8)), (marker, Data())], types: []
                ) { _ in nil },
                plain,
            ], source: servingOffer)
        #expect(publisher.retractWrite(servingOffer: offer, withdrawing: withdrawal) == .keptPart)
        #expect(pasteboard.dataByItem == [[NSPasteboard.PasteboardType(textUTI): Data("plain".utf8)]])
    }
}
