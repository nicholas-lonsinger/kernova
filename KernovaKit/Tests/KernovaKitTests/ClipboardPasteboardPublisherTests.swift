import AppKit
import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// The one place a clipboard publication reaches a pasteboard: how every write
/// is marked, what a failed one leaves behind, when a write is still this
/// publisher's to withdraw, and how a plan's promised types reach their bytes.
@Suite("ClipboardPasteboardPublisher")
@MainActor
struct ClipboardPasteboardPublisherTests {
    private let textUTI = ClipboardContent.utf8TextUTI

    private func makeSpec(_ uti: String, bytes: Data) -> ClipboardPasteboardPublisher.ItemSpec {
        ClipboardPasteboardPublisher.ItemSpec(types: [.init(uti)]) { _ in bytes }
    }

    // MARK: - Writing

    @Test("every write marks its contents host-only")
    func everyWriteIsMarkedHostOnly() {
        let pasteboard = FakeWritePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let publisher = ClipboardPasteboardPublisher(
            pasteboard: pasteboard, providerRegistry: registry)

        publisher.write([makeSpec(textUTI, bytes: Data("one".utf8))], promised: true)
        publisher.write([makeSpec(textUTI, bytes: Data("two".utf8))], promised: false)

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
                ], promised: true))

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

        #expect(!publisher.write([makeSpec(textUTI, bytes: Data("one".utf8))], promised: true))

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

        #expect(!publisher.write([makeSpec(textUTI, bytes: Data("one".utf8))], promised: true))

        // The prepare left an empty pasteboard, which is nobody's write…
        #expect(!publisher.holdsLastWrite)
        #expect(!publisher.retractPromisedWrite())
        // …but the change it made still must not read as the user's own copy.
        #expect(publisher.lastWriteChangeCount == pasteboard.changeCount)
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
        publisher.write([makeSpec(textUTI, bytes: Data("one".utf8))], promised: true)
        #expect(publisher.holdsLastWrite)

        // Somebody else wrote to the pasteboard.
        pasteboard.clearContents()
        #expect(!publisher.holdsLastWrite)
    }

    @Test("a promised write still held is the only one a retraction withdraws")
    func retractionOnlyTakesBackAHeldPromisedWrite() {
        let pasteboard = FakeWritePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let publisher = ClipboardPasteboardPublisher(
            pasteboard: pasteboard, providerRegistry: registry)

        publisher.write([makeSpec(textUTI, bytes: Data("one".utf8))], promised: true)
        #expect(publisher.retractPromisedWrite())
        #expect(publisher.lastWriteChangeCount == nil)
        // Idempotent: the retracted write is forgotten.
        #expect(!publisher.retractPromisedWrite())

        // A fully resolved write serves from local staging and survives the
        // offer behind it moving on.
        publisher.write([makeSpec(textUTI, bytes: Data("two".utf8))], promised: false)
        #expect(!publisher.retractPromisedWrite())
        #expect(publisher.holdsLastWrite)

        // A pasteboard the user has written over since is theirs.
        publisher.write([makeSpec(textUTI, bytes: Data("three".utf8))], promised: true)
        pasteboard.clearContents()
        #expect(!publisher.retractPromisedWrite())
    }

    // MARK: - Planning

    @Test("a plan's file URL and inline types reach their own serving calls")
    func planRoutesEachTypeToItsServingCall() {
        let serving = RecordingPromiseServing()
        serving.url = URL(fileURLWithPath: "/tmp/kernova-test/a.bin")
        serving.data = Data("inline".utf8)

        let plan = ClipboardPasteboardItemPlan.plan(
            for: [
                ClipboardRepresentationDescriptor(
                    uti: textUTI, filename: "", isInline: true, isPromisable: true),
                ClipboardRepresentationDescriptor(
                    uti: "public.data", filename: "a.bin", isInline: false, isPromisable: true),
            ])
        let specs = ClipboardPasteboardPublisher.specs(for: plan, generation: 6, serve: serving)

        #expect(specs.count == 2)
        #expect(specs[0].provide(.init(textUTI)) == Data("inline".utf8))
        #expect(serving.dataCalls == [Call(generation: 6, repIndex: 0, uti: textUTI)])

        // The `.fileURL` flavor promises the URL's own string bytes.
        #expect(specs[1].provide(.fileURL) == Data(serving.url!.absoluteString.utf8))
        #expect(serving.fileURLCalls == [Call(generation: 6, repIndex: 1, uti: nil)])
    }

    @Test("a type no coordinate resolves is left off, and an item left empty is dropped")
    func unresolvedTypesAreLeftOff() {
        let serving = RecordingPromiseServing()
        serving.data = Data("inline".utf8)

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
        #expect(specs[0].types == [.init(textUTI)])
        #expect(specs[0].provide(.init(textUTI)) == Data("inline".utf8))
        #expect(serving.fileURLCalls.isEmpty)
    }
}

/// One call a promise made on its serving side.
private struct Call: Equatable {
    let generation: UInt64
    let repIndex: Int
    let uti: String?
}

/// Records what a promised type asked for instead of pulling anything.
private final class RecordingPromiseServing: ClipboardPromiseServing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedFileURLCalls: [Call] = []
    private var storedDataCalls: [Call] = []
    private var storedURL: URL?
    private var storedData: Data?

    var url: URL? {
        get { lock.withLock { storedURL } }
        set { lock.withLock { storedURL = newValue } }
    }

    var data: Data? {
        get { lock.withLock { storedData } }
        set { lock.withLock { storedData = newValue } }
    }

    var fileURLCalls: [Call] { lock.withLock { storedFileURLCalls } }
    var dataCalls: [Call] { lock.withLock { storedDataCalls } }

    func serveFileURL(generation: UInt64, repIndex: Int) -> URL? {
        lock.withLock {
            storedFileURLCalls.append(Call(generation: generation, repIndex: repIndex, uti: nil))
            return storedURL
        }
    }

    func serveData(generation: UInt64, repIndex: Int, uti: String) -> Data? {
        lock.withLock {
            storedDataCalls.append(Call(generation: generation, repIndex: repIndex, uti: uti))
            return storedData
        }
    }
}
