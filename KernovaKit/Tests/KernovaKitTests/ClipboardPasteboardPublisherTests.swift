import AppKit
import Foundation
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaKit

/// The one place a clipboard publication reaches a pasteboard: how every write
/// is marked, what a failed one leaves behind, when a write is still this
/// publisher's to withdraw, and how a plan's promised types reach their bytes.
@Suite("ClipboardPasteboardPublisher", .caseScoped)
@MainActor
struct ClipboardPasteboardPublisherTests {
    private let textUTI = NSPasteboard.PasteboardType.string.rawValue
    private let offer = Data(repeating: 1, count: 16)
    private let otherOffer = Data(repeating: 2, count: 16)

    /// Answers every pull with `bytes` and `url`, counting nothing.
    private final class Puller: ClipboardItemPulling {
        let bytes: Data?
        let url: URL?
        init(bytes: Data? = nil, url: URL? = nil) {
            self.bytes = bytes
            self.url = url
        }
        func pullBytes(item: Int, representation: Int, completion: @escaping @Sendable (Data?) -> Void) {
            completion(bytes)
        }
        func pullFile(item: Int, representation: Int, completion: @escaping @Sendable (URL?) -> Void) {
            completion(url)
        }
    }

    /// A write serving the offer `token`, its specs the test's own.
    private func serving(_ token: Data) -> ClipboardWriteSource {
        ClipboardWriteSource(offer: token, items: [], concealed: false, servingFileURLs: true, puller: Puller())
    }

    /// A write serving `offer`.
    private var servingOffer: ClipboardWriteSource { serving(offer) }

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
        publisher.write([makeSpec(textUTI, bytes: Data("two".utf8))], source: serving(otherOffer))

        #expect(pasteboard.prepareCount == 2)
        #expect(pasteboard.lastPrepareOptions == .currentHostOnly)
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

    // MARK: - What a paste had

    private static func representation(_ uti: String, _ storage: Representation.Storage, name: String = "")
        -> Representation
    {
        var representation = Representation()
        representation.type = TypeDescriptor(appleUTI: uti)
        representation.storage = storage
        representation.name = Data(name.utf8)
        return representation
    }

    /// A write of one text item of `offer` through `publisher`, concealed unless `concealed` is false, through a
    /// puller only it holds, which the returned closure reads.
    private func writeWatched(_ publisher: ClipboardPasteboardPublisher, concealed: Bool = true) -> () -> Puller? {
        var item = OfferedItem()
        item.representations = [Self.representation(textUTI, .inline)]
        weak var watched: Puller?
        do {
            let puller = Puller(bytes: Data("a password".utf8))
            watched = puller
            #expect(
                publisher.publish([item], concealed: concealed, pasteCeiling: .max, puller: puller, serving: offer)
                    == .written)
        }
        return { watched }
    }

    @Test("a write's carriage ending keeps what a paste had of it as data, reading it back")
    func unreadWithdrawalKeepsWhatWasRead() async throws {
        let pasteboard = FakePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let publisher = ClipboardPasteboardPublisher(
            pasteboard: pasteboard, providerRegistry: registry, ledger: ClipboardWriteLedger())
        let watched = writeWatched(publisher, concealed: false)
        let text = NSPasteboard.PasteboardType.string
        #expect(pasteboard.promisedTypesByItem == [[text]])
        #expect(try await offCooperativePool { pasteboard.invokeProvider(forType: text) } == Data("a password".utf8))
        let fires = pasteboard.providerInvocations

        #expect(publisher.retractWrite(servingOffer: offer, withdrawing: .unread) == .keptEverything)
        #expect(pasteboard.promisedTypes.isEmpty)
        #expect(pasteboard.dataByItem == [[text: Data("a password".utf8)]])
        // Read back from what the pasteboard holds: no provider fired again.
        #expect(pasteboard.providerInvocations == fires)
        #expect(watched() == nil)
    }

    @Test("a concealed write's carriage ending withdraws what a paste had of it too, its marker with it")
    func unreadWithdrawalOfAConcealedWriteClears() async throws {
        let pasteboard = FakePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let publisher = ClipboardPasteboardPublisher(
            pasteboard: pasteboard, providerRegistry: registry, ledger: ClipboardWriteLedger())
        let watched = writeWatched(publisher)
        let text = NSPasteboard.PasteboardType.string
        #expect(try await offCooperativePool { pasteboard.invokeProvider(forType: text) } == Data("a password".utf8))

        #expect(publisher.retractWrite(servingOffer: offer, withdrawing: .unread) == .cleared)
        #expect(pasteboard.items.isEmpty)
        #expect(watched() == nil)
    }

    @Test("a write a reader had every type of is released only once something replaces it")
    func fullyReadWriteReleasesWhenReplaced() async throws {
        let pasteboard = FakePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let ledger = ClipboardWriteLedger()
        let publisher = ClipboardPasteboardPublisher(pasteboard: pasteboard, providerRegistry: registry, ledger: ledger)
        var item = OfferedItem()
        item.representations = [Self.representation("public.data", .file, name: "a.bin")]
        let released = AsyncGate()
        var wasReleased = false
        #expect(
            publisher.publish(
                [item], concealed: false, pasteCeiling: .max, puller: Puller(url: URL(fileURLWithPath: "/tmp/a.bin")),
                serving: offer,
                onReleased: {
                    wasReleased = true
                    released.notify()
                }) == .written)

        // A paste has the file URL, and AppKit finishes with the provider, the write standing.
        #expect(try await offCooperativePool { pasteboard.invokeProvider(forType: .fileURL) } != nil)
        pasteboard.finishProvider(itemIndex: 0)
        try await drainMainQueue()
        #expect(!wasReleased)
        #expect(ledger.standingWrite(on: pasteboard) != nil)

        // Another app's copy replaces it: no provider is left to say so, and the write is released all the same.
        pasteboard.setString("copied since", forType: .string)
        try await released.wait { wasReleased }
        #expect(ledger.standingWrite(on: pasteboard) == nil)
    }
}
