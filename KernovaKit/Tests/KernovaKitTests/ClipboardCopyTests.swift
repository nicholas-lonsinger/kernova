import AppKit
import Foundation
import KernovaSynchronization
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaKit

/// A clipboard command's two ends: the source's snapshot, read whole at the command and served from what it
/// read, and the destination's write of a copy, its non-file representations as data and its files promised.
@Suite("Clipboard copies", .caseScoped)
@MainActor
struct ClipboardCopyTests {
    private let scratch = TestScratchDirectory(prefix: "clipboard-copy")

    private func snapshot(_ pasteboard: FakePasteboard) async throws -> ClipboardOfferSource {
        guard
            case .snapshot(let snapshot, _) = await ClipboardPasteboardReader.readSnapshot(
                from: pasteboard, sizeOf: nil)
        else { throw TestFailure("no snapshot") }
        return snapshot
    }

    // MARK: - The snapshot

    @Test("A snapshot reads every type now, sized by what it read, and serves it after the pasteboard moves on")
    func snapshotReadsNow() async throws {
        let pasteboard = FakePasteboard()
        pasteboard.setItem([(.string, Data("text".utf8)), (.rtf, Data("{\\rtf1 rich}".utf8))])

        let source = try await snapshot(pasteboard)
        #expect(source.items[0].representations.map(\.sizeEstimate) == [4, 12])
        #expect(pasteboard.residentReads == [.string, .rtf])

        pasteboard.setItem([(.string, Data("copied since".utf8))])
        #expect(try await source.serve(item: 0, representation: 0) == .bytes(Data("text".utf8)))
        #expect(try await source.serve(item: 0, representation: 1) == .bytes(Data("{\\rtf1 rich}".utf8)))
    }

    @Test("A snapshot keeps a file as the reference it is, read only when pulled")
    func snapshotKeepsFilesByReference() async throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let file = scratch.url.appendingPathComponent("notes.bin")
        try Data("file bytes".utf8).write(to: file)
        let pasteboard = FakePasteboard()
        pasteboard.setFiles([file])

        let source = try await snapshot(pasteboard)
        #expect(source.items.map { $0.representations.map(\.storage) } == [[.file]])
        pasteboard.setItem([(.string, Data("copied since".utf8))])
        guard case .file(let served) = try await source.serve(item: 0, representation: 0) else {
            Issue.record("the file was not served")
            return
        }
        #expect(served.lastPathComponent == "notes.bin")
    }

    @Test("An empty or transient pasteboard has nothing to snapshot")
    func nothingToSnapshot() async {
        let pasteboard = FakePasteboard()
        guard case .nothing = await ClipboardPasteboardReader.readSnapshot(from: pasteboard, sizeOf: nil) else {
            Issue.record("an empty pasteboard gave a snapshot")
            return
        }
        pasteboard.setItem([
            (.string, Data("a password".utf8)),
            (NSPasteboard.PasteboardType(ClipboardSnapshotPolicy.transientMarkerUTI), Data()),
        ])
        guard case .nothing = await ClipboardPasteboardReader.readSnapshot(from: pasteboard, sizeOf: nil) else {
            Issue.record("a transient copy gave a snapshot")
            return
        }
    }

    // MARK: - The copy's write

    /// Answers every file pull with `url`.
    private final class FilePuller: ClipboardItemPulling {
        let url: URL?
        init(url: URL?) { self.url = url }
        func pullBytes(item: Int, representation: Int, completion: @escaping @Sendable (Data?) -> Void) {
            completion(nil)
        }
        func pullFile(item: Int, representation: Int, completion: @escaping @Sendable (URL?) -> Void) {
            completion(url)
        }
    }

    private static func representation(_ uti: String, _ storage: Representation.Storage, name: String = "")
        -> Representation
    {
        var representation = Representation()
        representation.type = TypeDescriptor(appleUTI: uti)
        representation.storage = storage
        representation.name = Data(name.utf8)
        return representation
    }

    @Test("A copy's landed representations are written as data now and its file promised, released once let go")
    func copyIsWrittenAsData() async throws {
        let pasteboard = FakePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let publisher = ClipboardPasteboardPublisher(pasteboard: pasteboard, providerRegistry: registry)
        var item = OfferedItem()
        item.representations = [
            Self.representation(ClipboardContent.utf8TextUTI, .inline),
            Self.representation("public.data", .file, name: "a.bin"),
        ]
        let released = AsyncGate()
        var wasReleased = false

        let (written, promised) = publisher.publishCopy(
            [item], concealed: false, servingFileURLs: true, landed: { _, _ in Data("text".utf8) },
            puller: FilePuller(url: URL(fileURLWithPath: "/tmp/a.bin")), servingOffer: Data(repeating: 1, count: 16),
            onReleased: {
                wasReleased = true
                released.notify()
            })
        #expect(written && promised)
        #expect(
            pasteboard.dataByItem == [[NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI): Data("text".utf8)]])
        #expect(pasteboard.promisedTypes == [.fileURL])
        #expect(!wasReleased)

        pasteboard.setItem([(.string, Data("the user's".utf8))])
        try await released.wait { wasReleased }
    }

    @Test("A copy with no file promises nothing, and a concealed one carries its marker as data")
    func copyWithoutFilesPromisesNothing() {
        let pasteboard = FakePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let publisher = ClipboardPasteboardPublisher(pasteboard: pasteboard, providerRegistry: registry)
        var item = OfferedItem()
        item.representations = [Self.representation(ClipboardContent.utf8TextUTI, .inline)]

        let (written, promised) = publisher.publishCopy(
            [item], concealed: true, servingFileURLs: true, landed: { _, _ in Data("hunter2".utf8) },
            puller: FilePuller(url: nil), servingOffer: Data(repeating: 1, count: 16), onReleased: {})
        #expect(written && !promised)
        #expect(pasteboard.promisedTypes.isEmpty)
        #expect(
            pasteboard.dataByItem.first?[NSPasteboard.PasteboardType(ClipboardSnapshotPolicy.concealedMarkerUTI)]
                == Data())
        #expect(registry.countForTesting == 0)
    }

    // MARK: - A snapshot of this process's own write

    /// Answers each INLINE pull with `bytes` and each file pull with `url`, counting the pulls.
    private final class CountingPuller: ClipboardItemPulling {
        let bytes: Data
        let url: URL?
        private let pulled = Locked<[Int]>([])
        init(bytes: Data, url: URL? = nil) {
            self.bytes = bytes
            self.url = url
        }
        /// The representation each pull asked for, in order.
        var pulls: [Int] { pulled.withLock { $0 } }
        func pullBytes(item: Int, representation: Int, completion: @escaping @Sendable (Data?) -> Void) {
            pulled.withLock { $0.append(representation) }
            completion(bytes)
        }
        func pullFile(item: Int, representation: Int, completion: @escaping @Sendable (URL?) -> Void) {
            pulled.withLock { $0.append(representation) }
            completion(url)
        }
    }

    @Test(
        "A snapshot of a pasteboard holding this process's write of a far-side offer is built by pulling it, the write's promise never read"
    )
    func snapshotOfOwnWritePulls() async throws {
        let pasteboard = FakePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let ledger = ClipboardWriteLedger()
        let publisher = ClipboardPasteboardPublisher(pasteboard: pasteboard, providerRegistry: registry, ledger: ledger)
        var item = OfferedItem()
        item.representations = [Self.representation(ClipboardContent.utf8TextUTI, .inline)]
        let puller = CountingPuller(bytes: Data("the far side's".utf8))
        #expect(
            publisher.publish([item], concealed: false, puller: puller, servingOffer: Data(repeating: 1, count: 16)))

        guard
            case .snapshot(let source, let lost) = await ClipboardPasteboardReader.readSnapshot(
                from: pasteboard, destinationOffer: Data(repeating: 2, count: 16), ledger: ledger, sizeOf: nil)
        else { throw TestFailure("no snapshot") }
        #expect(lost == 0)
        #expect(puller.pulls == [0])
        #expect(pasteboard.providerInvocations == 0)
        #expect(source.items[0].representations[0].sizeEstimate == UInt64("the far side's".utf8.count))
        #expect(try await source.serve(item: 0, representation: 0) == .bytes(Data("the far side's".utf8)))
    }

    @Test("A pasteboard holding this process's write of the destination's own offer holds what a snapshot would carry")
    func ownWriteOfTheDestinationsOfferIsHeld() async throws {
        let pasteboard = FakePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let ledger = ClipboardWriteLedger()
        let publisher = ClipboardPasteboardPublisher(pasteboard: pasteboard, providerRegistry: registry, ledger: ledger)
        var item = OfferedItem()
        item.representations = [Self.representation(ClipboardContent.utf8TextUTI, .inline)]
        let puller = CountingPuller(bytes: Data("the far side's".utf8))
        let offer = Data(repeating: 1, count: 16)
        #expect(publisher.publish([item], concealed: false, puller: puller, servingOffer: offer))

        guard
            case .heldByDestination = await ClipboardPasteboardReader.readSnapshot(
                from: pasteboard, destinationOffer: offer, ledger: ledger, sizeOf: nil)
        else { throw TestFailure("snapshotted the destination's own offer") }
        #expect(puller.pulls.isEmpty)
        #expect(pasteboard.providerInvocations == 0)
    }

    @Test(
        "A snapshot of this process's copy write takes its data as written and pulls its file, its promise never read")
    func snapshotOfOwnCopyWrite() async throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let landed = scratch.url.appendingPathComponent("a.bin")
        try Data("file bytes".utf8).write(to: landed)
        let pasteboard = FakePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let ledger = ClipboardWriteLedger()
        let publisher = ClipboardPasteboardPublisher(pasteboard: pasteboard, providerRegistry: registry, ledger: ledger)
        var item = OfferedItem()
        item.representations = [
            Self.representation(ClipboardContent.utf8TextUTI, .inline),
            Self.representation("public.data", .file, name: "a.bin"),
        ]
        let puller = CountingPuller(bytes: Data(), url: landed)
        _ = publisher.publishCopy(
            [item], concealed: false, servingFileURLs: true, landed: { _, _ in Data("text".utf8) }, puller: puller,
            servingOffer: Data(repeating: 1, count: 16), onReleased: {})

        guard
            case .snapshot(let source, _) = await ClipboardPasteboardReader.readSnapshot(
                from: pasteboard, ledger: ledger, sizeOf: nil)
        else { throw TestFailure("no snapshot") }
        #expect(puller.pulls == [1])
        #expect(pasteboard.providerInvocations == 0)
        #expect(source.items[0].representations.map(\.storage) == [.inline, .file])
        #expect(try await source.serve(item: 0, representation: 0) == .bytes(Data("text".utf8)))
        #expect(try await source.serve(item: 0, representation: 1) == .file(landed))
    }
}
