import AppKit
import Foundation
import KernovaSynchronization
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
    private static let connection = ClipboardConnectionID()
    private let scratch = TestScratchDirectory(prefix: "publisher")
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

    // MARK: - Planning

    @Test("a plan's file URL and inline types reach their own serving calls")
    func planRoutesEachTypeToItsServingCall() {
        let serving = RecordingPromiseServing(
            url: URL(fileURLWithPath: "/tmp/kernova-test/a.bin"), data: Data("inline".utf8))

        let plan = ClipboardPasteboardItemPlan.plan(
            for: [
                ClipboardRepresentationDescriptor(
                    uti: textUTI, filename: "", isInline: true, isPromisable: true),
                ClipboardRepresentationDescriptor(
                    uti: "public.data", filename: "a.bin", isInline: false, isPromisable: true),
            ])
        let specs = ClipboardPasteboardPublisher.specs(for: plan, generation: 6, serve: serving)

        #expect(specs.count == 2)
        #expect(specs[0].provide(textUTI) == Data("inline".utf8))
        #expect(serving.dataCalls == [Call(generation: 6, repIndex: 0, uti: textUTI)])

        // The `.fileURL` flavor promises the URL's own string bytes.
        #expect(
            specs[1].provide(ClipboardPasteboardPublisher.ItemSpec.fileURLType)
                == Data(serving.url!.absoluteString.utf8))
        #expect(serving.fileURLCalls == [Call(generation: 6, repIndex: 1, uti: nil)])
    }

    @Test("a type no coordinate resolves is left off, and an item left empty is dropped")
    func unresolvedTypesAreLeftOff() {
        let serving = RecordingPromiseServing(data: Data("inline".utf8))

        let plan = ClipboardPasteboardItemPlan.plan(
            for: [
                ClipboardRepresentationDescriptor(
                    uti: textUTI, filename: "", isInline: true, isPromisable: true),
                ClipboardRepresentationDescriptor(
                    uti: "public.data", filename: "a.bin", isInline: false, isPromisable: true),
            ])
        let specs = ClipboardPasteboardPublisher.specs(for: plan, serve: serving) { promised in
            promised.isFileURL ? nil : (generation: 3, repIndex: promised.representationIndex)
        }

        // The file item promised nothing but its URL, so nothing is left of it —
        // a paste finds no flavor to fire rather than one that serves nothing.
        #expect(specs.count == 1)
        #expect(specs[0].types == [textUTI])
        #expect(specs[0].provide(textUTI) == Data("inline".utf8))
        #expect(serving.fileURLCalls.isEmpty)
    }

    // MARK: - Promising again

    /// A fresh named pasteboard, the real OS's, never the user's clipboard.
    private func namedPasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KernovaTest-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    /// One item offering one INLINE text representation.
    private var textItem: OfferedItem {
        .with(.make(TypeDescriptor(appleUTI: textUTI), .inline, size: 5))
    }

    /// Reads `type` of the pasteboard's first item off the main thread, where the publisher's hold parks instead
    /// of running an event loop.
    private func paste(_ type: String, from pasteboard: NSPasteboard) async -> Data? {
        nonisolated(unsafe) let reader = pasteboard
        return await offCooperativePool { reader.data(forType: NSPasteboard.PasteboardType(type)) }
    }

    @Test("a paste its readout's Cancel stopped is asked again by the next paste, which gets the bytes")
    func cancelledPasteIsPromisedAgain() async {
        let pasteboard = namedPasteboard()
        defer { pasteboard.releaseGlobally() }
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let publisher = ClipboardPasteboardPublisher(
            pasteboard: pasteboard, providerRegistry: registry, ledger: ClipboardWriteLedger())
        let puller = ScriptedPuller(answers: [nil, Data("hello".utf8)], servable: true)
        #expect(
            publisher.publish(
                [textItem], concealed: false, puller: puller,
                serving: .init(token: offer, connection: Self.connection)))

        #expect(await paste(textUTI, from: pasteboard) == nil)
        await drainMainQueue()
        #expect(await paste(textUTI, from: pasteboard) == Data("hello".utf8))
        #expect(puller.pulls == 2)
        // The write still serves the offer, so the offer's end still withdraws it.
        #expect(publisher.retractWrite(servingOffer: offer, withdrawing: .everyPromise) != nil)
    }

    @Test("a paste whose pull failed is not promised again")
    func failedPasteIsNotPromisedAgain() async {
        let pasteboard = namedPasteboard()
        defer { pasteboard.releaseGlobally() }
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let publisher = ClipboardPasteboardPublisher(
            pasteboard: pasteboard, providerRegistry: registry, ledger: ClipboardWriteLedger())
        let puller = ScriptedPuller(answers: [nil, Data("hello".utf8)], servable: false)
        publisher.publish(
            [textItem], concealed: false, puller: puller, serving: .init(token: offer, connection: Self.connection))
        let written = pasteboard.changeCount

        #expect(await paste(textUTI, from: pasteboard) == nil)
        await drainMainQueue()
        #expect(pasteboard.changeCount == written)
        #expect(await paste(textUTI, from: pasteboard) == nil)
        #expect(puller.pulls == 1)
    }

    @Test("a copy someone else made while the paste ran is not written over")
    func anotherWriteIsNotWrittenOver() async {
        let pasteboard = namedPasteboard()
        defer { pasteboard.releaseGlobally() }
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let publisher = ClipboardPasteboardPublisher(
            pasteboard: pasteboard, providerRegistry: registry, ledger: ClipboardWriteLedger())
        nonisolated(unsafe) let writer = pasteboard
        let copied = Locked(0)
        // The copy lands while the pull runs, so it is on the pasteboard before the empty fire returns.
        let puller = ScriptedPuller(answers: [nil, Data("hello".utf8)], servable: true) {
            DispatchQueue.main.sync {
                writer.clearContents()
                writer.setString("theirs", forType: .string)
                copied.withLock { $0 = writer.changeCount }
            }
        }
        publisher.publish(
            [textItem], concealed: false, puller: puller, serving: .init(token: offer, connection: Self.connection))

        #expect(await paste(textUTI, from: pasteboard) == nil)
        await drainMainQueue()
        let theirs = copied.withLock { $0 }

        #expect(pasteboard.changeCount == theirs)
        #expect(pasteboard.string(forType: .string) == "theirs")
    }

    @Test("a copy promised again stays held: its release waits for what replaces the write")
    func renewedCopyKeepsItsRelease() async {
        let pasteboard = namedPasteboard()
        defer { pasteboard.releaseGlobally() }
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let publisher = ClipboardPasteboardPublisher(
            pasteboard: pasteboard, providerRegistry: registry, ledger: ClipboardWriteLedger())
        let file = scratch.url.appendingPathComponent("a.bin")
        let puller = ScriptedPuller(answers: [nil, Data()], file: file, servable: true)
        let released = Locked(0)
        let placed = publisher.publishCopy(
            [.with(.make(TypeDescriptor(appleUTI: "public.data"), .file, size: 1, name: "a.bin"))],
            concealed: false, servingFileURLs: true, held: { _, _ in nil }, puller: puller,
            serving: .init(token: offer, connection: Self.connection),
            onReleased: { released.withLock { $0 += 1 } })
        #expect(placed.written && placed.holdsCopy)

        let fileURLType = ClipboardPasteboardPublisher.ItemSpec.fileURLType
        #expect(await paste(fileURLType, from: pasteboard) == nil)
        await drainMainQueue()
        #expect(released.withLock { $0 } == 0)
        #expect(await paste(fileURLType, from: pasteboard) == Data(file.absoluteString.utf8))

        publisher.clear()
        #expect(released.withLock { $0 } == 1)
    }
}

/// Answers each pull with the next of `answers`, nil once they run out — a FILE pull with `file` where an answer
/// is not nil — and calls every representation `servable`.
private final class ScriptedPuller: ClipboardItemPulling, Sendable {
    private let answers: Locked<[Data?]>
    private let file: URL?
    private let servable: Bool
    private let duringPull: @Sendable () -> Void
    private let count = Locked(0)

    /// Runs `duringPull` in each pull, before it answers.
    init(answers: [Data?], file: URL? = nil, servable: Bool, duringPull: @escaping @Sendable () -> Void = {}) {
        self.answers = Locked(answers)
        self.file = file
        self.servable = servable
        self.duringPull = duringPull
    }

    /// How many pulls were started.
    var pulls: Int { count.withLock { $0 } }

    func pullBytes(item: Int, representation: Int, completion: @escaping @Sendable (Data?) -> Void) {
        completion(next())
    }

    func pullFile(item: Int, representation: Int, completion: @escaping @Sendable (URL?) -> Void) {
        completion(next() == nil ? nil : file)
    }

    func canServe(item: Int, representation: Int) -> Bool { servable }

    func whenEnded(_ handler: @escaping @Sendable () -> Void) {}

    private func next() -> Data? {
        count.withLock { $0 += 1 }
        duringPull()
        return answers.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}

/// One call a promise made on its serving side.
private struct Call: Equatable, Sendable {
    let generation: UInt64
    let repIndex: Int
    let uti: String?
}

/// Records what a promised type asked for instead of pulling anything.
private final class RecordingPromiseServing: ClipboardPromiseServing, Sendable {
    private struct Calls: Sendable {
        var fileURL: [Call] = []
        var data: [Call] = []
    }

    let url: URL?
    let data: Data?
    private let calls = Locked(Calls())

    /// Answers every file-URL request with `url` and every data request with
    /// `data`.
    init(url: URL? = nil, data: Data? = nil) {
        self.url = url
        self.data = data
    }

    var fileURLCalls: [Call] { calls.withLock { $0.fileURL } }
    var dataCalls: [Call] { calls.withLock { $0.data } }

    func serveFileURL(generation: UInt64, repIndex: Int) -> URL? {
        calls.withLock { $0.fileURL.append(Call(generation: generation, repIndex: repIndex, uti: nil)) }
        return url
    }

    func serveData(generation: UInt64, repIndex: Int, uti: String) -> Data? {
        calls.withLock { $0.data.append(Call(generation: generation, repIndex: repIndex, uti: uti)) }
        return data
    }
}
