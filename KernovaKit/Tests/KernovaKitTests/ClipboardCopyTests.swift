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
    private static let connection = ClipboardConnectionID()
    private let scratch = TestScratchDirectory(prefix: "clipboard-copy")
    private let stagingRoot = TestStagingRoot()

    private func snapshot(_ pasteboard: FakePasteboard) async throws -> ClipboardOfferSource {
        guard
            case .snapshot(let snapshot, _) = await ClipboardPasteboardReader.readSnapshot(
                from: pasteboard, copyingTo: Self.connection, sizeOf: nil)
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
        guard
            case .nothing = await ClipboardPasteboardReader.readSnapshot(
                from: pasteboard, copyingTo: Self.connection, sizeOf: nil)
        else {
            Issue.record("an empty pasteboard gave a snapshot")
            return
        }
        pasteboard.setItem([
            (.string, Data("a password".utf8)),
            (NSPasteboard.PasteboardType(ClipboardSnapshotPolicy.transientMarkerUTI), Data()),
        ])
        guard
            case .nothing = await ClipboardPasteboardReader.readSnapshot(
                from: pasteboard, copyingTo: Self.connection, sizeOf: nil)
        else {
            Issue.record("a transient copy gave a snapshot")
            return
        }
    }

    // MARK: - The copy's write

    /// Answers every file pull with `url`.
    private final class FilePuller: ClipboardItemPulling {
        func whenEnded(_ handler: @escaping @Sendable () -> Void) {}
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
            [item], concealed: false, servingFileURLs: true,
            held: { _, representation in representation == 0 ? .bytes(Data("text".utf8)) : nil },
            puller: FilePuller(url: URL(fileURLWithPath: "/tmp/a.bin")),
            serving: .init(token: Data(repeating: 1, count: 16), connection: Self.connection),
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
            [item], concealed: true, servingFileURLs: true, held: { _, _ in .bytes(Data("hunter2".utf8)) },
            puller: FilePuller(url: nil),
            serving: .init(token: Data(repeating: 1, count: 16), connection: Self.connection), onReleased: {})
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
        func whenEnded(_ handler: @escaping @Sendable () -> Void) {}
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
        "A snapshot of this process's write of a far-side offer names each representation by reference, pulling nothing"
    )
    func snapshotOfOwnWriteNamesReferences() async throws {
        let pasteboard = FakePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let ledger = ClipboardWriteLedger()
        let publisher = ClipboardPasteboardPublisher(pasteboard: pasteboard, providerRegistry: registry, ledger: ledger)
        var item = OfferedItem()
        item.representations = [Self.representation(ClipboardContent.utf8TextUTI, .inline)]
        let puller = CountingPuller(bytes: Data("the far side's".utf8))
        let offer = Data(repeating: 1, count: 16)
        #expect(
            publisher.publish(
                [item], concealed: false, puller: puller, serving: .init(token: offer, connection: Self.connection)))

        guard
            case .snapshot(let source, let lost) = await ClipboardPasteboardReader.readSnapshot(
                from: pasteboard, ledger: ledger, copyingTo: Self.connection, sizeOf: nil)
        else { throw TestFailure("no snapshot") }
        #expect(lost == 0)
        #expect(puller.pulls.isEmpty)
        #expect(pasteboard.providerInvocations == 0)
        let reference = try #require(source.items.first?.representations.first?.reference)
        #expect(reference.offer == offer && reference.item == 0 && reference.representation == 0)
        #expect(source.standsOnItsPasteboard)
        // The far side fills a reference itself: nothing of it is served from here.
        await #expect(throws: ClipboardServeError.unavailable) { try await source.serve(item: 0, representation: 0) }
        pasteboard.setString("copied since", forType: .string)
        #expect(!source.standsOnItsPasteboard)
    }

    @Test(
        "A snapshot of this process's copy write sends its data as data and names its file by reference, never its INLINE"
    )
    func snapshotOfOwnCopyWrite() async throws {
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
        let puller = CountingPuller(bytes: Data(), url: nil)
        let copy = Data(repeating: 1, count: 16)
        _ = publisher.publishCopy(
            [item], concealed: false, servingFileURLs: true,
            held: { _, representation in representation == 0 ? .bytes(Data("text".utf8)) : nil }, puller: puller,
            serving: .init(token: copy, connection: Self.connection), onReleased: {})

        guard
            case .snapshot(let source, _) = await ClipboardPasteboardReader.readSnapshot(
                from: pasteboard, ledger: ledger, copyingTo: Self.connection, sizeOf: nil)
        else { throw TestFailure("no snapshot") }
        #expect(puller.pulls.isEmpty)
        #expect(pasteboard.providerInvocations == 0)
        let representations = try #require(source.items.first?.representations)
        #expect(representations.map(\.storage) == [.inline, .file])
        // A copy's write holds every INLINE representation as data, so a snapshot of it sends that as data: a
        // reference never names an INLINE representation of a copy, whose bytes its sender let go once served.
        #expect(!representations[0].hasReference)
        #expect(representations[1].reference.offer == copy && representations[1].reference.representation == 1)
        #expect(try await source.serve(item: 0, representation: 0) == .bytes(Data("text".utf8)))
    }

    /// Another connection's offer: answers each INLINE pull with `bytes` and each file pull with `url` until it
    /// ends, then nothing.
    private final class UpstreamPuller: ClipboardItemPulling {
        let bytes: Data
        let url: URL
        private let state = Locked<(ended: Bool, handlers: [@Sendable () -> Void], filePulls: Int)>((false, [], 0))
        init(bytes: Data, url: URL) {
            self.bytes = bytes
            self.url = url
        }
        var filePulls: Int { state.withLock { $0.filePulls } }
        func pullBytes(item: Int, representation: Int, completion: @escaping @Sendable (Data?) -> Void) {
            completion(state.withLock { $0.ended } ? nil : bytes)
        }
        func pullFile(item: Int, representation: Int, completion: @escaping @Sendable (URL?) -> Void) {
            let ended = state.withLock { state -> Bool in
                state.filePulls += 1
                return state.ended
            }
            completion(ended ? nil : url)
        }
        func whenEnded(_ handler: @escaping @Sendable () -> Void) {
            let ended = state.withLock { state -> Bool in
                if !state.ended { state.handlers.append(handler) }
                return state.ended
            }
            if ended { handler() }
        }
        func end() {
            let handlers = state.withLock { state -> [@Sendable () -> Void] in
                state.ended = true
                defer { state.handlers = [] }
                return state.handlers
            }
            for handler in handlers { handler() }
        }
    }

    @Test(
        "A snapshot of another connection's write pulls its text now and serves its file from that write's source, while it lasts"
    )
    func snapshotOfAnotherConnectionsWrite() async throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let file = scratch.url.appendingPathComponent("a.bin")
        try Data("upstream file".utf8).write(to: file)
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
        let upstream = UpstreamPuller(bytes: Data("upstream text".utf8), url: file)
        #expect(
            publisher.publish(
                [item], concealed: false, puller: upstream,
                serving: .init(token: Data(repeating: 1, count: 16), connection: ClipboardConnectionID())))

        guard
            case .snapshot(let source, let lost) = await ClipboardPasteboardReader.readSnapshot(
                from: pasteboard, ledger: ledger, copyingTo: Self.connection, sizeOf: nil)
        else { throw TestFailure("no snapshot") }
        #expect(lost == 0)
        #expect(pasteboard.providerInvocations == 0)
        let representations = try #require(source.items.first?.representations)
        #expect(representations.map(\.hasReference) == [false, false])
        #expect(representations.map(\.storage) == [.inline, .file])
        #expect(representations[0].sizeEstimate == UInt64("upstream text".utf8.count))
        #expect(upstream.filePulls == 0)

        // The text is the snapshot's; the file is pulled from upstream only when pulled.
        pasteboard.setString("copied since", forType: .string)
        #expect(try await source.serve(item: 0, representation: 0) == .bytes(Data("upstream text".utf8)))
        #expect(try await source.serve(item: 0, representation: 1) == .file(file))
        #expect(upstream.filePulls == 1)

        // The upstream offer ends: the snapshot says so, and its file is served no more.
        let ended = AsyncGate()
        let heard = Locked(false)
        source.whenUpstreamEnds {
            heard.withLock { $0 = true }
            ended.notify()
        }
        upstream.end()
        try await ended.wait { heard.withLock { $0 } }
        await #expect(throws: ClipboardServeError.unavailable) { try await source.serve(item: 0, representation: 1) }
        #expect(try await source.serve(item: 0, representation: 0) == .bytes(Data("upstream text".utf8)))
    }

    // MARK: - Bounds and independence

    @Test("A snapshot whose INLINE bytes come to more than the ceiling is too large, read no further")
    func snapshotOverTheCeiling() async {
        let pasteboard = FakePasteboard()
        pasteboard.setItem([(.string, Data("text".utf8)), (.rtf, Data("{\\rtf1 rich}".utf8))])
        guard
            case .tooLarge(let limitBytes) = await ClipboardPasteboardReader.readSnapshot(
                from: pasteboard, ceiling: 3, copyingTo: Self.connection, sizeOf: nil)
        else {
            Issue.record("a snapshot over the ceiling was taken")
            return
        }
        #expect(limitBytes == 3)
        #expect(pasteboard.residentReads == [.string])
    }

    @Test("A snapshot of this process's write is held to the ceiling too")
    func snapshotOfOwnWriteOverTheCeiling() async {
        let pasteboard = FakePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let ledger = ClipboardWriteLedger()
        let publisher = ClipboardPasteboardPublisher(pasteboard: pasteboard, providerRegistry: registry, ledger: ledger)
        var item = OfferedItem()
        item.representations = [Self.representation(ClipboardContent.utf8TextUTI, .inline)]
        _ = publisher.publishCopy(
            [item], concealed: false, servingFileURLs: true, held: { _, _ in .bytes(Data("text".utf8)) },
            puller: CountingPuller(bytes: Data()),
            serving: .init(token: Data(repeating: 1, count: 16), connection: Self.connection), onReleased: {})
        guard
            case .tooLarge = await ClipboardPasteboardReader.readSnapshot(
                from: pasteboard, ceiling: 3, ledger: ledger, copyingTo: Self.connection, sizeOf: nil)
        else {
            Issue.record("a snapshot over the ceiling was taken")
            return
        }
    }

    @Test("A snapshot calls a file promise in at once and keeps the file it landed, whatever the pasteboard does next")
    func snapshotCallsPromisesIn() async throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let pasteboard = FakePasteboard()
        let receiver = FakeFilePromiseReceiver(
            name: "photo.png", fileType: "public.png", contents: .file(Data("png".utf8)))
        pasteboard.setFilePromise(receiver)
        guard
            case .snapshot(let source, _) = await ClipboardPasteboardReader.readSnapshot(
                from: pasteboard, staging: .leased(label: "copies", root: stagingRoot.root), copyingTo: Self.connection,
                sizeOf: nil)
        else { throw TestFailure("no snapshot") }
        #expect(receiver.callIns == 1)
        let kept = try #require(source.items.first?.representations.first)
        #expect(kept.storage == .file && !kept.promised && kept.sizeEstimate == 3)

        pasteboard.setItem([(.string, Data("copied since".utf8))])
        guard case .file(let served) = try await source.serve(item: 0, representation: 0) else {
            Issue.record("the called-in file was not served")
            return
        }
        #expect(served.lastPathComponent == "photo.png")
        #expect(receiver.callIns == 1)
    }

    /// A file in the scratch directory this process cannot open.
    private func unreadableFile(_ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let file = scratch.url.appendingPathComponent(name)
        try Data("locked".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        return file
    }

    @Test("A snapshot leaves out a file it cannot open, counting it, and offers the files it can")
    func snapshotLeavesOutAnUnreadableFile() async throws {
        let readable = scratch.url.appendingPathComponent("open.txt")
        let locked = try unreadableFile("locked.txt")
        try Data("open".utf8).write(to: readable)
        let pasteboard = FakePasteboard()
        #expect(pasteboard.setFiles([readable, locked]))
        guard
            case .snapshot(let source, let lost) = await ClipboardPasteboardReader.readSnapshot(
                from: pasteboard, copyingTo: Self.connection, sizeOf: nil)
        else { throw TestFailure("no snapshot") }
        #expect(lost == 1)
        #expect(
            source.items.flatMap(\.representations).map { String(decoding: $0.name, as: UTF8.self) } == ["open.txt"])
    }

    @Test("A snapshot of only files it cannot open is unreadable: nothing is copied")
    func snapshotOfOnlyUnreadableFiles() async throws {
        let pasteboard = FakePasteboard()
        #expect(pasteboard.setFiles([try unreadableFile("locked.txt")]))
        guard
            case .unreadable = await ClipboardPasteboardReader.readSnapshot(
                from: pasteboard, copyingTo: Self.connection, sizeOf: nil)
        else { throw TestFailure("not unreadable") }
    }

    @Test("A file URL this process cannot open, beside a file promise, is copied by calling the promise in")
    func unreadableFileFallsBackToItsPromise() async throws {
        let pasteboard = FakePasteboard()
        let receiver = FakeFilePromiseReceiver(
            name: "photo.jpeg", fileType: "public.jpeg", contents: .file(Data("jpeg".utf8)))
        #expect(pasteboard.setFile(try unreadableFile("derivative.jpeg"), promising: receiver))
        guard
            case .snapshot(let source, let lost) = await ClipboardPasteboardReader.readSnapshot(
                from: pasteboard, staging: .leased(label: "copies", root: stagingRoot.root),
                copyingTo: Self.connection, sizeOf: nil)
        else { throw TestFailure("no snapshot") }
        #expect(lost == 0)
        #expect(receiver.callIns == 1)
        guard case .file(let served) = try await source.serve(item: 0, representation: 0) else {
            throw TestFailure("the called-in file was not served")
        }
        #expect(served.lastPathComponent == "photo.jpeg")
    }

    // MARK: - Lifetimes

    @Test("A snapshot's called-in files outlive four later call-ins, and go once the snapshot does")
    func snapshotFilesLiveAsLongAsTheSnapshot() async throws {
        let staging = ClipboardFileStaging.leased(label: "copies", root: stagingRoot.root)
        let pasteboard = FakePasteboard()
        func snapshotOfAPromise(_ name: String) async throws -> (ClipboardOfferSource, URL) {
            pasteboard.setFilePromise(
                FakeFilePromiseReceiver(name: name, fileType: "public.png", contents: .file(Data(name.utf8))))
            guard
                case .snapshot(let source, _) = await ClipboardPasteboardReader.readSnapshot(
                    from: pasteboard, staging: staging, copyingTo: Self.connection, sizeOf: nil),
                case .file(let url) = try await source.serve(item: 0, representation: 0)
            else { throw TestFailure("no snapshot of \(name)") }
            return (source, url)
        }
        var (first, file): (ClipboardOfferSource?, URL) = try await snapshotOfAPromise("first.png")
        var later: [ClipboardOfferSource] = []
        for index in 1...4 { later.append(try await snapshotOfAPromise("later-\(index).png").0) }
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try await first?.serve(item: 0, representation: 0) == .file(file))

        first = nil
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(later.count == 4)
    }

    /// A concealed passthrough write of one text item through a puller only it holds, on `pasteboard`.
    private func writeWatched(
        on pasteboard: FakePasteboard, _ publisher: ClipboardPasteboardPublisher
    ) -> () -> CountingPuller? {
        var item = OfferedItem()
        item.representations = [Self.representation(ClipboardContent.utf8TextUTI, .inline)]
        weak var watched: CountingPuller?
        do {
            let puller = CountingPuller(bytes: Data("a password".utf8))
            watched = puller
            #expect(
                publisher.publish(
                    [item], concealed: true, puller: puller,
                    serving: .init(token: Self.writeOffer, connection: Self.connection)))
        }
        return { watched }
    }

    private static let writeOffer = Data(repeating: 1, count: 16)

    @Test("A replaced write's record goes, its source and puller with it: nothing is left to retract")
    func replacedWriteHoldsNothing() async throws {
        let pasteboard = FakePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let ledger = ClipboardWriteLedger()
        let publisher = ClipboardPasteboardPublisher(pasteboard: pasteboard, providerRegistry: registry, ledger: ledger)
        let watched = writeWatched(on: pasteboard, publisher)
        #expect(watched() != nil)
        #expect(ledger.standingWrite(on: pasteboard) != nil)

        // Another app's copy replaces the write, and the pasteboard lets go of its provider.
        pasteboard.setString("copied since", forType: .string)
        await drainMainQueue()
        #expect(ledger.standingWrite(on: pasteboard) == nil)
        #expect(watched() == nil)
        #expect(publisher.retractWrite(servingOffer: Self.writeOffer) == nil)
        #expect(pasteboard.items.first?.data(forType: .string) == Data("copied since".utf8))
    }

    @Test(
        "A write a reader had every promised type of stands: its record and source stay, for a retraction and a snapshot"
    )
    func fullyReadWriteKeepsItsRecord() async throws {
        let pasteboard = FakePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let ledger = ClipboardWriteLedger()
        let publisher = ClipboardPasteboardPublisher(pasteboard: pasteboard, providerRegistry: registry, ledger: ledger)
        let watched = writeWatched(on: pasteboard, publisher)
        let paste = Task.detached { pasteboard.invokeProvider(forType: .init(ClipboardContent.utf8TextUTI)) }
        #expect(await paste.value == Data("a password".utf8))

        // AppKit finishes with the provider, the write standing: a paste is no replacement.
        pasteboard.finishProvider(itemIndex: 0)
        await drainMainQueue()
        #expect(ledger.standingWrite(on: pasteboard) != nil)
        #expect(watched() != nil)
        #expect(publisher.holdsLastWrite)

        // The offer's end still retracts it.
        #expect(publisher.retractWrite(servingOffer: Self.writeOffer) == .cleared)
        #expect(pasteboard.items.isEmpty)
        #expect(watched() == nil)
    }

    @Test("A copy's write a reader had every type of is released only once something replaces it")
    func fullyReadCopyReleasesWhenReplaced() async throws {
        let pasteboard = FakePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let ledger = ClipboardWriteLedger()
        let publisher = ClipboardPasteboardPublisher(pasteboard: pasteboard, providerRegistry: registry, ledger: ledger)
        var item = OfferedItem()
        item.representations = [Self.representation("public.data", .file, name: "a.bin")]
        let released = AsyncGate()
        var wasReleased = false
        let (written, promised) = publisher.publishCopy(
            [item], concealed: false, servingFileURLs: true, held: { _, _ in nil },
            puller: FilePuller(url: URL(fileURLWithPath: "/tmp/a.bin")),
            serving: .init(token: Data(repeating: 1, count: 16), connection: Self.connection),
            onReleased: {
                wasReleased = true
                released.notify()
            })
        #expect(written && promised)

        // A paste has the file URL, and AppKit finishes with the provider, the write standing.
        let paste = Task.detached { pasteboard.invokeProvider(forType: .fileURL) }
        #expect(await paste.value != nil)
        pasteboard.finishProvider(itemIndex: 0)
        await drainMainQueue()
        #expect(!wasReleased)
        #expect(ledger.standingWrite(on: pasteboard) != nil)

        // Another app's copy replaces it: no provider is left to say so, and the write is released all the same.
        pasteboard.setString("copied since", forType: .string)
        try await released.wait { wasReleased }
        #expect(ledger.standingWrite(on: pasteboard) == nil)
    }

    @Test("A write that promises nothing holds no source: a snapshot of it reads its data from the pasteboard")
    func dataOnlyWriteHoldsNoSource() async throws {
        let pasteboard = FakePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let ledger = ClipboardWriteLedger()
        let publisher = ClipboardPasteboardPublisher(pasteboard: pasteboard, providerRegistry: registry, ledger: ledger)
        var item = OfferedItem()
        item.representations = [Self.representation(ClipboardContent.utf8TextUTI, .inline)]
        weak var watched: CountingPuller?
        do {
            let puller = CountingPuller(bytes: Data())
            watched = puller
            let (written, promised) = publisher.publishCopy(
                [item], concealed: true, servingFileURLs: true, held: { _, _ in .bytes(Data("hunter2".utf8)) },
                puller: puller, serving: .init(token: Data(repeating: 1, count: 16), connection: Self.connection),
                onReleased: {})
            #expect(written && !promised)
        }
        #expect(watched == nil)
        #expect(ledger.standingWrite(on: pasteboard) == nil)

        guard
            case .snapshot(let source, _) = await ClipboardPasteboardReader.readSnapshot(
                from: pasteboard, ledger: ledger, copyingTo: Self.connection, sizeOf: nil)
        else { throw TestFailure("no snapshot") }
        #expect(source.concealed)
        #expect(source.items.map { $0.representations.compactMap(\.type.appleUTI) } == [[ClipboardContent.utf8TextUTI]])
        #expect(try await source.serve(item: 0, representation: 0) == .bytes(Data("hunter2".utf8)))
    }
}
