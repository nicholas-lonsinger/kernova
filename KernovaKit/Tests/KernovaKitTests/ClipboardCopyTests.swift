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

    /// Staging a snapshot's called-in file promises land in.
    private var staging: ClipboardFileStaging { .leased(label: "copies", root: stagingRoot.root) }

    private func snapshot(_ pasteboard: FakePasteboard) async throws -> ClipboardOfferSource {
        guard
            case .snapshot(let snapshot, _) = await ClipboardPasteboardReader.readSnapshot(
                from: pasteboard, staging: staging, copyingTo: Self.connection, sizeOf: nil)
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
                from: pasteboard, staging: staging, copyingTo: Self.connection, sizeOf: nil)
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
                from: pasteboard, staging: staging, copyingTo: Self.connection, sizeOf: nil)
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

        let (written, holdsCopy) = publisher.publishCopy(
            [item], concealed: false, servingFileURLs: true,
            held: { _, representation in representation == 0 ? .bytes(Data("text".utf8)) : nil },
            puller: FilePuller(url: URL(fileURLWithPath: "/tmp/a.bin")),
            serving: .init(token: Data(repeating: 1, count: 16), connection: Self.connection),
            onReleased: {
                wasReleased = true
                released.notify()
            })
        #expect(written && holdsCopy)
        #expect(
            pasteboard.dataByItem == [[NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI): Data("text".utf8)]])
        #expect(pasteboard.promisedTypes == [.fileURL])
        #expect(!wasReleased)

        pasteboard.setItem([(.string, Data("the user's".utf8))])
        try await released.wait { wasReleased }
    }

    @Test(
        "A copy with no file promises nothing and is not held; a concealed one carries its marker as data, held until replaced",
        arguments: [false, true])
    func copyWithoutFilesPromisesNothing(concealed: Bool) {
        let pasteboard = FakePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let publisher = ClipboardPasteboardPublisher(pasteboard: pasteboard, providerRegistry: registry)
        var item = OfferedItem()
        item.representations = [Self.representation(ClipboardContent.utf8TextUTI, .inline)]

        let (written, holdsCopy) = publisher.publishCopy(
            [item], concealed: concealed, servingFileURLs: true, held: { _, _ in .bytes(Data("hunter2".utf8)) },
            puller: FilePuller(url: nil),
            serving: .init(token: Data(repeating: 1, count: 16), connection: Self.connection), onReleased: {})
        #expect(written && holdsCopy == concealed)
        #expect(pasteboard.promisedTypes.isEmpty)
        #expect(
            pasteboard.dataByItem.first?[NSPasteboard.PasteboardType(ClipboardSnapshotPolicy.concealedMarkerUTI)]
                == (concealed ? Data() : nil))
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
                from: pasteboard, ledger: ledger, staging: staging, copyingTo: Self.connection, sizeOf: nil)
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
                from: pasteboard, ledger: ledger, staging: staging, copyingTo: Self.connection, sizeOf: nil)
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

    @Test("A snapshot of another connection's write leaves out an item it could not pull, counted with the unreadable")
    func snapshotCountsAFailedPullAsLeftOut() async throws {
        let pasteboard = FakePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let ledger = ClipboardWriteLedger()
        let publisher = ClipboardPasteboardPublisher(pasteboard: pasteboard, providerRegistry: registry, ledger: ledger)
        var text = OfferedItem()
        text.representations = [Self.representation(ClipboardContent.utf8TextUTI, .inline)]
        var file = OfferedItem()
        file.representations = [Self.representation("public.data", .file, name: "a.bin")]
        #expect(
            publisher.publish(
                [text, file], concealed: false, puller: FilePuller(url: URL(fileURLWithPath: "/tmp/a.bin")),
                serving: .init(token: Data(repeating: 1, count: 16), connection: ClipboardConnectionID())))

        guard
            case .snapshot(let source, let lost) = await ClipboardPasteboardReader.readSnapshot(
                from: pasteboard, ledger: ledger, staging: staging, copyingTo: Self.connection, sizeOf: nil)
        else { throw TestFailure("no snapshot") }
        #expect(lost == 1)
        #expect(source.items.map { $0.representations.map(\.storage) } == [[.file]])
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
                from: pasteboard, ledger: ledger, staging: staging, copyingTo: Self.connection, sizeOf: nil)
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
        source.whenWithdrawalOwed { withdrawal in
            #expect(withdrawal == .upstreamEnded)
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
                from: pasteboard, ceiling: 3, staging: staging, copyingTo: Self.connection, sizeOf: nil)
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
                from: pasteboard, ceiling: 3, ledger: ledger, staging: staging, copyingTo: Self.connection, sizeOf: nil)
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
                from: pasteboard, staging: staging, copyingTo: Self.connection,
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

    /// Image files in the scratch directory, each `size` bytes, offered from a pasteboard naming them.
    private func imageFilesOffer(_ names: [String], size: Int) async throws -> ClipboardOfferSource {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let files = try names.map { name in
            let file = scratch.url.appendingPathComponent(name)
            try Data(repeating: 0x50, count: size).write(to: file)
            return file
        }
        let pasteboard = FakePasteboard()
        #expect(pasteboard.setFiles(files))
        guard case .offer(let source, _) = await ClipboardPasteboardReader.readOffer(from: pasteboard, sizeOf: nil)
        else { throw TestFailure("no offer") }
        return source
    }

    @Test(
        "Copied image files whose bytes read as nothing, their sizes together over the ceiling, cross as their files, nothing left out"
    )
    func unreadImageBytesCountNothing() async throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let files = try ["a.png", "b.png"].map { name in
            let file = scratch.url.appendingPathComponent(name)
            try Data(repeating: 0x50, count: 8).write(to: file)
            return file
        }
        let pasteboard = FakePasteboard()
        #expect(pasteboard.setFiles(files))

        // As iCloud Drive's evicted files read downloading nothing: each fits the ceiling alone, the two do not.
        let outcome = await ClipboardPasteboardReader.readSnapshot(
            from: pasteboard, ceiling: 10, ledger: ClipboardWriteLedger(), staging: staging, copyingTo: Self.connection,
            sizeOf: nil,
            contentsOf: { _ in nil })
        guard case .snapshot(let snapshot, let lost) = outcome else { throw TestFailure("not a snapshot: \(outcome)") }
        #expect(lost == 0)
        #expect(snapshot.items.map { $0.representations.map(\.storage) } == [[.file], [.file]])
    }

    @Test("An image file whose size alone is over what is left of the ceiling is too large, its bytes never read")
    func overCeilingImageIsNeverRead() async throws {
        let source = try await imageFilesOffer(["big.png"], size: 12)
        let reads = Locked(0)

        await #expect(throws: ClipboardSnapshotTooLarge(limitBytes: 10)) {
            _ = try await source.snapshot(
                inlineCeiling: 10, holding: staging.lease(),
                contentsOf: { _ in
                    reads.withLock { $0 += 1 }
                    return Data(repeating: 0x50, count: 12)
                })
        }
        #expect(reads.withLock { $0 } == 0)
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
                from: pasteboard, staging: staging, copyingTo: Self.connection, sizeOf: nil)
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
                from: pasteboard, staging: staging, copyingTo: Self.connection, sizeOf: nil)
        else { throw TestFailure("not unreadable") }
    }

    /// Guest Photos' ⌘C, its file URL naming a derivative in the Photos library that the agent cannot open.
    private func photosCopy(naming file: URL) -> [(type: NSPasteboard.PasteboardType, data: Data)] {
        let url = Data(file.absoluteString.utf8)
        let names: [(String, Data)] = [
            ("com.apple.photos.object-reference.asset", Data("asset".utf8)),
            ("public.jpeg", Data("jpeg".utf8)),
            ("CorePasteboardFlavorType 0x4A504547", Data("jpeg".utf8)),
            ("public.file-url", url),
            ("CorePasteboardFlavorType 0x6675726C", url),
            ("dyn.ah62d4rv4gu8y6y4grf0gn5xbrzw1gydcr7u1e3cytf2gn", url),
            ("NSFilenamesPboardType", url),
            ("dyn.ah62d4rv4gu8yc6durvwwaznwmuuha2pxsvw0e55bsmwca7d3sbwu", url),
            ("Apple URL pasteboard type", url),
            ("dyn.ah62d4rv4gu8za0cuqf31k3pcr7u1e3cmsvw04vdbsvuyq4pqqznzexcdr71004pfnv61a3k", Data("cookie".utf8)),
            ("PXPasteboardItemDataFileURLCookieType", Data("cookie".utf8)),
            ("public.tiff", Data("tiff".utf8)),
            ("NeXT TIFF v4.0 pasteboard type", Data("tiff".utf8)),
        ]
        return names.map { (NSPasteboard.PasteboardType($0.0), $0.1) }
    }

    @Test(
        "An item whose file cannot be opened, with no promise, crosses as its other types, its file and aliases left out"
    )
    func unreadableFileItemCrossesAsItsData() async throws {
        let pasteboard = FakePasteboard()
        #expect(pasteboard.setItem(photosCopy(naming: try unreadableFile("derivative.jpeg"))))
        let crossing = [
            "com.apple.photos.object-reference.asset", "public.jpeg", "CorePasteboardFlavorType 0x4A504547",
            "dyn.ah62d4rv4gu8za0cuqf31k3pcr7u1e3cmsvw04vdbsvuyq4pqqznzexcdr71004pfnv61a3k",
            "PXPasteboardItemDataFileURLCookieType", "public.tiff", "NeXT TIFF v4.0 pasteboard type",
        ]

        guard
            case .snapshot(let source, let lost) = await ClipboardPasteboardReader.readSnapshot(
                from: pasteboard, staging: staging, copyingTo: Self.connection, sizeOf: nil)
        else { throw TestFailure("no snapshot") }
        #expect(lost == 1)
        let item = try #require(source.items.first)
        #expect(source.items.count == 1)
        #expect(item.representations.compactMap(\.type.appleUTI) == crossing)
        #expect(item.representations.allSatisfy { $0.storage == .inline })
        #expect(try await source.serve(item: 0, representation: 1) == .bytes(Data("jpeg".utf8)))

        // Passthrough's offer reads the item by the same rule.
        guard case .offer(let offer, let offerLost) = await ClipboardPasteboardReader.readOffer(from: pasteboard)
        else { throw TestFailure("no offer") }
        #expect(offerLost == 1)
        #expect(offer.items.map { $0.representations.compactMap(\.type.appleUTI) } == [crossing])
    }

    @Test("A readable file item crosses as its file and every type not naming it, its plain text included, as data")
    func readableFileItemCrossesItsOtherTypes() async throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let file = scratch.url.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: file)
        let url = Data(file.absoluteString.utf8)
        // Finder's ⌘C of a file, its plain text the file's name, with a private type beside its icon.
        let finderCopy: [(type: NSPasteboard.PasteboardType, data: Data)] = [
            (.fileURL, url),
            (NSPasteboard.PasteboardType("NSFilenamesPboardType"), Data("<plist/>".utf8)),
            (NSPasteboard.PasteboardType("public.utf8-plain-text"), Data("notes.txt".utf8)),
            (NSPasteboard.PasteboardType("com.apple.icns"), Data("icns".utf8)),
            (NSPasteboard.PasteboardType("com.example.private-state"), Data("private".utf8)),
        ]
        let pasteboard = FakePasteboard()
        #expect(pasteboard.setItem(finderCopy))
        let crossing: [String?] = [
            "public.plain-text", "public.utf8-plain-text", "com.apple.icns", "com.example.private-state",
        ]

        guard
            case .snapshot(let source, let lost) = await ClipboardPasteboardReader.readSnapshot(
                from: pasteboard, staging: staging, copyingTo: Self.connection, sizeOf: nil)
        else { throw TestFailure("no snapshot") }
        #expect(lost == 0)
        let item = try #require(source.items.first)
        #expect(source.items.count == 1)
        #expect(item.representations.map(\.type.appleUTI) == crossing)
        #expect(item.representations.map(\.storage) == [.file, .inline, .inline, .inline])
        guard case .file(let served) = try await source.serve(item: 0, representation: 0) else {
            throw TestFailure("the file was not served")
        }
        #expect(served.lastPathComponent == "notes.txt")
        #expect(try await source.serve(item: 0, representation: 1) == .bytes(Data("notes.txt".utf8)))
        #expect(try await source.serve(item: 0, representation: 2) == .bytes(Data("icns".utf8)))
        #expect(try await source.serve(item: 0, representation: 3) == .bytes(Data("private".utf8)))

        // Passthrough's offer reads the item by the same rule.
        guard case .offer(let offer, let offerLost) = await ClipboardPasteboardReader.readOffer(from: pasteboard)
        else { throw TestFailure("no offer") }
        #expect(offerLost == 0)
        #expect(offer.items.map { $0.representations.map(\.type.appleUTI) } == [crossing])
    }

    @Test("A file URL this process cannot open, beside a file promise, is copied by calling the promise in")
    func unreadableFileFallsBackToItsPromise() async throws {
        let pasteboard = FakePasteboard()
        let receiver = FakeFilePromiseReceiver(
            name: "photo.jpeg", fileType: "public.jpeg", contents: .file(Data("jpeg".utf8)))
        #expect(pasteboard.setFile(try unreadableFile("derivative.jpeg"), promising: receiver))
        guard
            case .snapshot(let source, let lost) = await ClipboardPasteboardReader.readSnapshot(
                from: pasteboard, staging: staging,
                copyingTo: Self.connection, sizeOf: nil)
        else { throw TestFailure("no snapshot") }
        #expect(lost == 0)
        #expect(receiver.callIns == 1)
        guard case .file(let served) = try await source.serve(item: 0, representation: 0) else {
            throw TestFailure("the called-in file was not served")
        }
        #expect(served.lastPathComponent == "photo.jpeg")
    }

    /// Types a file promise of the source's places, beside `NSFilePromiseReceiver`'s readable ones.
    private static let promiseTypes: [(type: NSPasteboard.PasteboardType, data: Data)] = [
        (NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"), Data("file:///tmp/photo.jpeg".utf8)),
        (NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData"), Data("meta".utf8)),
    ]

    @Test(
        "An item whose file cannot be opened crosses as its promise, called in, and every type not naming a file or the promise, as data"
    )
    func unreadableFileItemCrossesItsPromiseAndItsData() async throws {
        let pasteboard = FakePasteboard()
        let receiver = FakeFilePromiseReceiver(
            name: "photo.jpeg", fileType: "public.jpeg", contents: .file(Data("jpeg".utf8)))
        #expect(
            pasteboard.setItem(
                photosCopy(naming: try unreadableFile("derivative.jpeg")) + Self.promiseTypes, promising: receiver))
        let crossing = [
            "com.apple.photos.object-reference.asset", "public.jpeg", "CorePasteboardFlavorType 0x4A504547",
            "dyn.ah62d4rv4gu8za0cuqf31k3pcr7u1e3cmsvw04vdbsvuyq4pqqznzexcdr71004pfnv61a3k",
            "PXPasteboardItemDataFileURLCookieType", "public.tiff", "NeXT TIFF v4.0 pasteboard type",
        ]

        guard
            case .snapshot(let source, let lost) = await ClipboardPasteboardReader.readSnapshot(
                from: pasteboard, staging: staging,
                copyingTo: Self.connection, sizeOf: nil)
        else { throw TestFailure("no snapshot") }
        #expect(lost == 0)
        #expect(receiver.callIns == 1)
        let item = try #require(source.items.first)
        #expect(source.items.count == 1)
        #expect(item.representations.compactMap(\.type.appleUTI) == ["public.jpeg"] + crossing)
        #expect(item.representations.map(\.storage) == [.file] + crossing.map { _ in .inline })
        guard case .file(let served) = try await source.serve(item: 0, representation: 0) else {
            throw TestFailure("the called-in file was not served")
        }
        #expect(served.lastPathComponent == "photo.jpeg")
        #expect(try await source.serve(item: 0, representation: 2) == .bytes(Data("jpeg".utf8)))

        // Passthrough's offer reads the item by the same rule.
        guard
            case .offer(let offer, let offerLost) = await ClipboardPasteboardReader.readOffer(
                from: pasteboard, promises: pasteboard.filePromiseReceivers)
        else { throw TestFailure("no offer") }
        #expect(offerLost == 0)
        #expect(offer.items.map { $0.representations.compactMap(\.type.appleUTI) } == [["public.jpeg"] + crossing])
    }

    @Test("An item that is only a promise of a file crosses as its promise and every type not naming the promise")
    func promiseItemCrossesItsOtherTypes() async throws {
        let pasteboard = FakePasteboard()
        let receiver = FakeFilePromiseReceiver(
            name: "photo.heic", fileType: "public.heic", contents: .file(Data("heic".utf8)))
        let other: [(type: NSPasteboard.PasteboardType, data: Data)] = [
            (NSPasteboard.PasteboardType("public.jpeg"), Data("jpeg".utf8)),
            (NSPasteboard.PasteboardType("com.example.private-state"), Data("private".utf8)),
        ]
        #expect(pasteboard.setItem(other + Self.promiseTypes, promising: receiver))
        let crossing = ["public.jpeg", "com.example.private-state"]

        guard
            case .snapshot(let source, let lost) = await ClipboardPasteboardReader.readSnapshot(
                from: pasteboard, staging: staging,
                copyingTo: Self.connection, sizeOf: nil)
        else { throw TestFailure("no snapshot") }
        #expect(lost == 0)
        #expect(receiver.callIns == 1)
        let item = try #require(source.items.first)
        #expect(item.representations.compactMap(\.type.appleUTI) == ["public.heic"] + crossing)
        #expect(item.representations.map(\.storage) == [.file, .inline, .inline])
        guard case .file(let served) = try await source.serve(item: 0, representation: 0) else {
            throw TestFailure("the called-in file was not served")
        }
        #expect(served.lastPathComponent == "photo.heic")
        #expect(try await source.serve(item: 0, representation: 2) == .bytes(Data("private".utf8)))

        guard
            case .offer(let offer, _) = await ClipboardPasteboardReader.readOffer(
                from: pasteboard, promises: pasteboard.filePromiseReceivers)
        else { throw TestFailure("no offer") }
        #expect(offer.items.map { $0.representations.compactMap(\.type.appleUTI) } == [["public.heic"] + crossing])
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

    /// A passthrough write of one text item, concealed unless `concealed` is false, through a puller only it
    /// holds, on `pasteboard`.
    private func writeWatched(
        on pasteboard: FakePasteboard, _ publisher: ClipboardPasteboardPublisher, concealed: Bool = true
    ) -> () -> CountingPuller? {
        var item = OfferedItem()
        item.representations = [Self.representation(ClipboardContent.utf8TextUTI, .inline)]
        weak var watched: CountingPuller?
        do {
            let puller = CountingPuller(bytes: Data("a password".utf8))
            watched = puller
            #expect(
                publisher.publish(
                    [item], concealed: concealed, puller: puller,
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

        // Another app's copy replaces the write, and the next poll ends it.
        pasteboard.setString("copied since", forType: .string)
        ClipboardPasteboardWatch.pollForTesting(pasteboard)
        await drainMainQueue()
        #expect(ledger.standingWrite(on: pasteboard) == nil)
        #expect(watched() == nil)
        #expect(publisher.retractWrite(servingOffer: Self.writeOffer, withdrawing: .everyPromise) == nil)
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
        #expect(publisher.retractWrite(servingOffer: Self.writeOffer, withdrawing: .everyPromise) == .cleared)
        #expect(pasteboard.items.isEmpty)
        #expect(watched() == nil)
    }

    @Test("A write's carriage ending keeps what a paste had of it as data, reading it back")
    func unreadWithdrawalKeepsWhatWasRead() async throws {
        let pasteboard = FakePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let publisher = ClipboardPasteboardPublisher(
            pasteboard: pasteboard, providerRegistry: registry, ledger: ClipboardWriteLedger())
        let watched = writeWatched(on: pasteboard, publisher, concealed: false)
        let text = NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)
        #expect(pasteboard.promisedTypesByItem == [[text]])
        let paste = Task.detached { pasteboard.invokeProvider(forType: text) }
        #expect(await paste.value == Data("a password".utf8))
        let fires = pasteboard.providerInvocations

        #expect(publisher.retractWrite(servingOffer: Self.writeOffer, withdrawing: .unread) == .keptEverything)
        #expect(pasteboard.promisedTypes.isEmpty)
        #expect(pasteboard.dataByItem == [[text: Data("a password".utf8)]])
        // Read back from what the pasteboard holds: no provider fired again.
        #expect(pasteboard.providerInvocations == fires)
        #expect(watched() == nil)
    }

    @Test("A concealed write's carriage ending withdraws what a paste had of it too, its marker with it")
    func unreadWithdrawalOfAConcealedWriteClears() async throws {
        let pasteboard = FakePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let publisher = ClipboardPasteboardPublisher(
            pasteboard: pasteboard, providerRegistry: registry, ledger: ClipboardWriteLedger())
        let watched = writeWatched(on: pasteboard, publisher)
        let text = NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)
        let paste = Task.detached { pasteboard.invokeProvider(forType: text) }
        #expect(await paste.value == Data("a password".utf8))

        #expect(publisher.retractWrite(servingOffer: Self.writeOffer, withdrawing: .unread) == .cleared)
        #expect(pasteboard.items.isEmpty)
        #expect(watched() == nil)
    }

    @Test("A write's carriage ending with nothing of it pasted clears it, its concealed marker too")
    func unreadWithdrawalOfAnUnreadWriteClears() async throws {
        let pasteboard = FakePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let publisher = ClipboardPasteboardPublisher(
            pasteboard: pasteboard, providerRegistry: registry, ledger: ClipboardWriteLedger())
        _ = writeWatched(on: pasteboard, publisher)

        #expect(publisher.retractWrite(servingOffer: Self.writeOffer, withdrawing: .unread) == .cleared)
        #expect(pasteboard.items.isEmpty)
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
        let (written, holdsCopy) = publisher.publishCopy(
            [item], concealed: false, servingFileURLs: true, held: { _, _ in nil },
            puller: FilePuller(url: URL(fileURLWithPath: "/tmp/a.bin")),
            serving: .init(token: Data(repeating: 1, count: 16), connection: Self.connection),
            onReleased: {
                wasReleased = true
                released.notify()
            })
        #expect(written && holdsCopy)

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

    @Test("A copy's write replaced before any provider of it finished ends at the next poll, its publisher gone")
    func unfinishedCopyEndsAtTheNextPoll() async throws {
        let pasteboard = FakePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let ledger = ClipboardWriteLedger()
        var item = OfferedItem()
        item.representations = [Self.representation("public.data", .file, name: "a.bin")]
        var released = false
        do {
            let publisher = ClipboardPasteboardPublisher(
                pasteboard: pasteboard, providerRegistry: registry, ledger: ledger)
            let (written, holdsCopy) = publisher.publishCopy(
                [item], concealed: false, servingFileURLs: true, held: { _, _ in nil },
                puller: FilePuller(url: URL(fileURLWithPath: "/tmp/a.bin")),
                serving: .init(token: Data(repeating: 1, count: 16), connection: Self.connection),
                onReleased: { released = true })
            #expect(written && holdsCopy)
        }

        // Another app's copy replaces the write, nothing having pasted it: AppKit finishes no provider until this
        // process next uses the pasteboard. No suspension follows, so the watch's own timer cannot poll first.
        pasteboard.setString("copied since", forType: .string)
        #expect(registry.countForTesting == 1)
        #expect(!released)

        ClipboardPasteboardWatch.pollForTesting(pasteboard)
        #expect(released)
        #expect(ledger.standingWrite(on: pasteboard) == nil)
        #expect(!ClipboardPasteboardWatch.isPollingForTesting(pasteboard))
    }

    @Test("A poll ends a replaced copy's write before any reader of the pasteboard hears it, and then stops watching")
    func replacedCopyEndsBeforeTheNewCopyIsRead() async throws {
        let pasteboard = FakePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let publisher = ClipboardPasteboardPublisher(
            pasteboard: pasteboard, providerRegistry: registry, ledger: ClipboardWriteLedger())
        var heard: [String] = []
        // A reader observing before the write's watch begins still hears each poll after it.
        let reader = ClipboardPasteboardWatch.observe(pasteboard, in: .newCopies) { heard.append("reader") }
        var item = OfferedItem()
        item.representations = [Self.representation("public.data", .file, name: "a.bin")]
        let (written, holdsCopy) = publisher.publishCopy(
            [item], concealed: false, servingFileURLs: true, held: { _, _ in nil },
            puller: FilePuller(url: URL(fileURLWithPath: "/tmp/a.bin")),
            serving: .init(token: Data(repeating: 1, count: 16), connection: Self.connection),
            onReleased: { heard.append("released") })
        #expect(written && holdsCopy)
        let paste = Task.detached { pasteboard.invokeProvider(forType: .fileURL) }
        #expect(await paste.value != nil)
        pasteboard.finishProvider(itemIndex: 0)
        await drainMainQueue()
        heard = []

        pasteboard.setString("copied since", forType: .string)
        ClipboardPasteboardWatch.pollForTesting(pasteboard)
        #expect(heard == ["released", "reader"])

        reader.cancel()
        #expect(!ClipboardPasteboardWatch.isPollingForTesting(pasteboard))
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
            let (written, holdsCopy) = publisher.publishCopy(
                [item], concealed: true, servingFileURLs: true, held: { _, _ in .bytes(Data("hunter2".utf8)) },
                puller: puller, serving: .init(token: Data(repeating: 1, count: 16), connection: Self.connection),
                onReleased: {})
            // Concealed, it is held until replaced, but holds no source.
            #expect(written && holdsCopy)
        }
        #expect(watched == nil)
        #expect(ledger.standingWrite(on: pasteboard) == nil)

        guard
            case .snapshot(let source, _) = await ClipboardPasteboardReader.readSnapshot(
                from: pasteboard, ledger: ledger, staging: staging, copyingTo: Self.connection, sizeOf: nil)
        else { throw TestFailure("no snapshot") }
        #expect(source.concealed)
        #expect(source.items.map { $0.representations.compactMap(\.type.appleUTI) } == [[ClipboardContent.utf8TextUTI]])
        #expect(try await source.serve(item: 0, representation: 0) == .bytes(Data("hunter2".utf8)))
    }
}
