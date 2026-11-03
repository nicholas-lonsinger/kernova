import AppKit
import Foundation
import KernovaSynchronization
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaKit

/// The pasteboard ↔ item bridge end to end: a source pasteboard read into an
/// offer, the offer published lazily onto a destination pasteboard, and a
/// paste there pulling each representation back from the source.
@Suite("Clipboard item bridge", .caseScoped)
@MainActor
struct ClipboardItemBridgeTests {
    private let scratch = TestScratchDirectory(prefix: "item-bridge")
    private let concealedType = NSPasteboard.PasteboardType(ClipboardSnapshotPolicy.concealedMarkerUTI)
    private let transientType = NSPasteboard.PasteboardType(ClipboardSnapshotPolicy.transientMarkerUTI)
    private let rtfType = NSPasteboard.PasteboardType("public.rtf")
    private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

    /// Serves a destination's pulls from the source's offer, landing a file or
    /// folder as a receiver does: under the offer's name, in a landing folder.
    private final class OfferPuller: ClipboardItemPulling {
        let source: ClipboardOfferSource
        let items: [OfferedItem]
        let landing: URL

        @MainActor
        init(source: ClipboardOfferSource, landing: URL) {
            self.source = source
            self.items = source.items
            self.landing = landing
        }

        func pullBytes(item: Int, representation: Int) -> Data? {
            guard case .bytes(let data)? = serve(item, representation) else { return nil }
            return data
        }

        func pullFile(item: Int, representation: Int) -> URL? {
            let name = String(decoding: items[item].representations[representation].name, as: UTF8.self)
            let destination = landing.appendingPathComponent(name)
            switch serve(item, representation) {
            case .file(let url)?, .folder(let url)?:
                guard (try? FileManager.default.copyItem(at: url, to: destination)) != nil else { return nil }
                return destination
            default:
                return nil
            }
        }

        /// Blocks, as the provider callback does, until the source serves.
        private func serve(_ item: Int, _ representation: Int) -> ClipboardServedRepresentation? {
            let result = Locked<ClipboardServedRepresentation?>(nil)
            let done = DispatchSemaphore(value: 0)
            let source = self.source
            Task { @MainActor in
                let served = try? await source.serve(item: item, representation: representation)
                result.withLock { $0 = served }
                done.signal()
            }
            done.wait()
            return result.withLock { $0 }
        }
    }

    /// One publication onto a fresh destination, with what it promised.
    private struct Published {
        let destination: FakePasteboard
        let registry: LazyClipboardProviderRegistry
        let landing: URL

        /// Fires item `item`'s provider for `type` as a paste does, off the
        /// main actor so the pull can reach it.
        func paste(_ type: NSPasteboard.PasteboardType, item: Int = 0) async -> Data? {
            let destination = self.destination
            return await offCooperativePool { destination.invokeProvider(forType: type, itemIndex: item) }
        }

        /// The file a paste of item `item`'s `public.file-url` lands.
        func pasteFile(item: Int = 0) async -> URL? {
            guard let data = await paste(.fileURL, item: item) else { return nil }
            return URL(string: String(decoding: data, as: UTF8.self))
        }
    }

    private func directory(_ name: String) throws -> URL {
        let url = scratch.url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func readOffer(
        _ pasteboard: FakePasteboard, promises: [any FilePromiseReceiving] = []
    ) async throws -> ClipboardOfferSource {
        let promiseFolder = try directory("promises")
        let outcome = await ClipboardPasteboardReader.readOffer(
            from: pasteboard, promises: promises,
            promiseDestination: {
                let folder = promiseFolder.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                return folder
            },
            sizeOf: nil)
        guard case .offer(let source, let lost) = outcome else {
            Issue.record("expected an offer, got \(outcome)")
            throw CancellationError()
        }
        #expect(lost == 0)
        return source
    }

    private func publish(_ source: ClipboardOfferSource, servingFileURLs: Bool = true) throws -> Published {
        let landing = try directory("landing-\(UUID().uuidString)")
        let destination = FakePasteboard()
        let registry = LazyClipboardProviderRegistry()
        let publisher = ClipboardPasteboardPublisher(pasteboard: destination, providerRegistry: registry)
        #expect(
            publisher.publish(
                source.items, concealed: source.concealed, transient: source.transient,
                servingFileURLs: servingFileURLs, puller: OfferPuller(source: source, landing: landing)))
        return Published(destination: destination, registry: registry, landing: landing)
    }

    private func single(_ source: ClipboardOfferSource) -> [Representation] {
        #expect(source.items.count == 1)
        return source.items.first?.representations ?? []
    }

    // MARK: - Text and images

    @Test("text offers its types without reading them, and a paste pulls only the type it asks for")
    func textRoundTrips() async throws {
        let pasteboard = FakePasteboard()
        pasteboard.setItem([(type: .string, data: Data("hello".utf8)), (type: rtfType, data: Data("{\\rtf1}".utf8))])

        let source = try await readOffer(pasteboard)
        let representations = single(source)
        #expect(representations.map(\.type.appleUTI) == [ClipboardContent.utf8TextUTI, "public.rtf"])
        #expect(representations.allSatisfy { $0.storage == .inline && $0.sizeEstimate == 0 && !$0.promised })
        #expect(representations.first?.type.mime == "text/plain")
        #expect(pasteboard.residentReads.isEmpty)

        let published = try publish(source)
        defer { published.registry.releaseAllForTesting() }
        #expect(published.destination.promisedTypesByItem == [[.string, rtfType]])
        #expect(await published.paste(.string) == Data("hello".utf8))
        #expect(pasteboard.residentReads == [.string])
    }

    @Test("an image round-trips its bytes")
    func imageRoundTrips() async throws {
        let pasteboard = FakePasteboard()
        pasteboard.setItem([(type: .png, data: pngBytes)])

        let source = try await readOffer(pasteboard)
        #expect(single(source).map(\.type.appleUTI) == ["public.png"])

        let published = try publish(source)
        defer { published.registry.releaseAllForTesting() }
        #expect(await published.paste(.png) == pngBytes)
    }

    @Test("several pasteboard items offer one item each")
    func eachPasteboardItemIsAnItem() async throws {
        let pasteboard = FakePasteboard()
        pasteboard.setItems([[(type: .string, data: Data("one".utf8))], [(type: .string, data: Data("two".utf8))]])

        let source = try await readOffer(pasteboard)
        #expect(source.items.count == 2)

        let published = try publish(source)
        defer { published.registry.releaseAllForTesting() }
        #expect(await published.paste(.string, item: 1) == Data("two".utf8))
    }

    @Test("a pull after the pasteboard moved on is refused unavailable")
    func pullAfterTheCopyIsReplacedIsUnavailable() async throws {
        let pasteboard = FakePasteboard()
        pasteboard.setString("first", forType: .string)
        let source = try await readOffer(pasteboard)

        pasteboard.setString("second", forType: .string)

        await #expect(throws: ClipboardServeError.unavailable) {
            try await source.serve(item: 0, representation: 0)
        }
        #expect(pasteboard.residentReads.isEmpty)
    }

    // MARK: - Files and folders

    @Test("a file offers its name and size, never its path text, and lands under its name")
    func fileRoundTrips() async throws {
        let file = try directory("copied").appendingPathComponent("notes.txt")
        try Data("file body".utf8).write(to: file)
        let pasteboard = FakePasteboard()
        pasteboard.setItem([
            (type: .fileURL, data: Data(file.absoluteString.utf8)), (type: .string, data: Data(file.path.utf8)),
        ])

        let source = try await readOffer(pasteboard)
        let representations = single(source)
        #expect(representations.count == 1)
        #expect(representations.first?.storage == .file)
        #expect(representations.first?.name == Data("notes.txt".utf8))
        #expect(representations.first?.sizeEstimate == 9)
        #expect(representations.first?.type.appleUTI == "public.plain-text")

        let published = try publish(source)
        defer { published.registry.releaseAllForTesting() }
        #expect(published.destination.promisedTypesByItem == [[.fileURL]])
        let landed = try #require(await published.pasteFile())
        #expect(landed.lastPathComponent == "notes.txt")
        #expect(try Data(contentsOf: landed) == Data("file body".utf8))
    }

    @Test("an image file also offers its bytes inline, which withholding file URLs keeps")
    func imageFileOffersItsBytesInline() async throws {
        let file = try directory("copied").appendingPathComponent("photo.png")
        try pngBytes.write(to: file)
        let pasteboard = FakePasteboard()
        pasteboard.setItem([(type: .fileURL, data: Data(file.absoluteString.utf8))])

        let source = try await readOffer(pasteboard)
        #expect(single(source).map(\.storage) == [.file, .inline])

        let published = try publish(source)
        defer { published.registry.releaseAllForTesting() }
        #expect(published.destination.promisedTypesByItem == [[.fileURL, .png]])
        #expect(await published.paste(.png) == pngBytes)

        let withheld = try publish(source, servingFileURLs: false)
        defer { withheld.registry.releaseAllForTesting() }
        #expect(withheld.destination.promisedTypesByItem == [[.png]])
    }

    @Test("a folder offers itself as FOLDER and lands whole under its name")
    func folderRoundTrips() async throws {
        let folder = try directory("copied/Album")
        try Data("a".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try Data("bb".utf8).write(to: folder.appendingPathComponent("b.txt"))
        let pasteboard = FakePasteboard()
        pasteboard.setItem([(type: .fileURL, data: Data(folder.absoluteString.utf8))])

        let source = try await readOffer(pasteboard)
        let representations = single(source)
        #expect(representations.map(\.storage) == [.folder])
        #expect(representations.first?.name == Data("Album".utf8))

        let published = try publish(source)
        defer { published.registry.releaseAllForTesting() }
        let landed = try #require(await published.pasteFile())
        #expect(landed.lastPathComponent == "Album")
        #expect(try Data(contentsOf: landed.appendingPathComponent("b.txt")) == Data("bb".utf8))
    }

    @Test("a file gone since the copy is lost, not offered")
    func vanishedFileIsLost() async throws {
        let gone = scratch.url.appendingPathComponent("gone.txt")
        let pasteboard = FakePasteboard()
        pasteboard.setItem([(type: .fileURL, data: Data(gone.absoluteString.utf8))])

        let outcome = await ClipboardPasteboardReader.readOffer(from: pasteboard, sizeOf: nil)

        guard case .nothingOfferable(let lost) = outcome else {
            Issue.record("expected nothing offerable, got \(outcome)")
            return
        }
        #expect(lost == 1)
    }

    // MARK: - Promises

    private let promiseTypes: [NSPasteboard.PasteboardType] = [
        .init("com.apple.NSFilePromiseItemMetaData"), .init("com.apple.pasteboard.promised-file-content-type"),
    ]

    private func promisePasteboard() -> FakePasteboard {
        let pasteboard = FakePasteboard()
        pasteboard.setItem(promiseTypes.map { (type: $0, data: Data()) })
        return pasteboard
    }

    @Test("a promise is offered promised, called in only on its first pull, and served from that call-in after")
    func promiseRoundTrips() async throws {
        let receiver = FakeFilePromiseReceiver(name: "photo.png", fileType: "public.png", contents: .file(pngBytes))

        let source = try await readOffer(promisePasteboard(), promises: [receiver])
        let representation = try #require(single(source).first)
        #expect(representation.promised)
        #expect(representation.storage == .file)
        #expect(representation.name == Data("photo.png".utf8))
        #expect(representation.type.appleUTI == "public.png")
        #expect(receiver.callIns == 0)

        let published = try publish(source)
        defer { published.registry.releaseAllForTesting() }
        let landed = try #require(await published.pasteFile())
        #expect(landed.lastPathComponent == "photo.png")
        #expect(try Data(contentsOf: landed) == pngBytes)

        guard case .file(let again) = try await source.serve(item: 0, representation: 0) else {
            Issue.record("expected the promised file")
            return
        }
        #expect(try Data(contentsOf: again) == pngBytes)
        #expect(receiver.callIns == 1)
    }

    @Test("a promise naming nothing yet is offered under its type's extension; a folder type offers FOLDER")
    func promiseNamesAndStorage() async throws {
        let nameless = FakeFilePromiseReceiver(
            name: "IMG_0001.png", fileType: "public.png", contents: .file(pngBytes), named: false)
        let folder = FakeFilePromiseReceiver(
            name: "Export", fileType: "public.folder", contents: .folder(["a.txt": Data("a".utf8)]))
        let pasteboard = FakePasteboard()
        let promiseItem = promiseTypes.map { (type: $0, data: Data()) }
        pasteboard.setItems([promiseItem, promiseItem])

        let source = try await readOffer(pasteboard, promises: [nameless, folder])

        let names = source.items.map { $0.representations.first?.name }
        #expect(names == [Data("Untitled.png".utf8), Data("Export".utf8)])
        #expect(source.items.map { $0.representations.first?.storage } == [.file, .folder])
        guard case .folder(let landed) = try await source.serve(item: 1, representation: 0) else {
            Issue.record("expected the promised folder")
            return
        }
        #expect(try Data(contentsOf: landed.appendingPathComponent("a.txt")) == Data("a".utf8))
    }

    @Test("a promise whose source fails is refused read-failed")
    func failedPromiseIsReadFailed() async throws {
        let receiver = FakeFilePromiseReceiver(name: "x.png", fileType: "public.png", contents: .failure)
        let source = try await readOffer(promisePasteboard(), promises: [receiver])

        await #expect(throws: ClipboardServeError.readFailed) {
            try await source.serve(item: 0, representation: 0)
        }
    }

    // MARK: - Markers

    @Test("a concealed copy is offered concealed and published with the marker, which reads back concealed")
    func concealedRoundTrips() async throws {
        let pasteboard = FakePasteboard()
        pasteboard.setItem([(type: .string, data: Data("hunter2".utf8)), (type: concealedType, data: Data())])

        let source = try await readOffer(pasteboard)
        #expect(source.concealed)
        #expect(!source.transient)
        #expect(single(source).map(\.type.appleUTI) == [ClipboardContent.utf8TextUTI])

        let published = try publish(source)
        defer { published.registry.releaseAllForTesting() }
        #expect(published.destination.promisedTypesByItem == [[.string, concealedType]])
        let reread = try await readOffer(published.destination)
        #expect(reread.concealed)
        #expect(published.destination.providerInvocations == 0)
    }

    @Test("a transient copy is offered transient rather than dropped, and published with the marker")
    func transientRoundTrips() async throws {
        let pasteboard = FakePasteboard()
        pasteboard.setItem([(type: .string, data: Data("snippet".utf8)), (type: transientType, data: Data())])

        let source = try await readOffer(pasteboard)
        #expect(source.transient)
        #expect(!source.concealed)

        let published = try publish(source)
        defer { published.registry.releaseAllForTesting() }
        #expect(published.destination.promisedTypesByItem == [[.string, transientType]])
        #expect(await published.paste(transientType) == Data())
        #expect(await published.paste(.string) == Data("snippet".utf8))
        #expect(try await readOffer(published.destination).transient)
    }

    @Test("an auto-generated copy offers nothing")
    func autoGeneratedIsSuppressed() async {
        let pasteboard = FakePasteboard()
        pasteboard.setItem([
            (type: .string, data: Data("fix".utf8)),
            (type: .init(ClipboardSnapshotPolicy.autoGeneratedMarkerUTI), data: Data()),
        ])

        let outcome = await ClipboardPasteboardReader.readOffer(from: pasteboard, sizeOf: nil)

        guard case .suppressed(.autoGeneratedSnapshot) = outcome else {
            Issue.record("expected suppression, got \(outcome)")
            return
        }
    }

    // MARK: - Content

    @Test("held content offers its text inline and its files by name, and previews as pending metadata")
    func contentOffersAndPreviews() async throws {
        let file = try directory("held").appendingPathComponent("photo.png")
        try pngBytes.write(to: file)
        let content = ClipboardContent(
            representations: [
                .init(uti: ClipboardContent.utf8TextUTI, data: Data("caption".utf8)),
                .init(uti: "public.png", fileURL: file, byteCount: pngBytes.count, filename: "photo.png"),
            ], isConcealed: true)

        let source = ClipboardOfferSource(content: content)
        #expect(source.concealed)
        #expect(source.items.map { $0.representations.map(\.storage) } == [[.inline], [.file, .inline]])
        #expect(try await source.serve(item: 0, representation: 0) == .bytes(Data("caption".utf8)))
        #expect(try await source.serve(item: 1, representation: 1) == .bytes(pngBytes))

        let preview = ClipboardContent(previewOf: source.items, concealed: source.concealed)
        #expect(preview.isConcealed)
        #expect(preview.representations.map(\.filename) == ["", "photo.png"])
        #expect(preview.representations.allSatisfy { $0.isPendingRemote })
        #expect(preview.representations.last?.byteCount == pngBytes.count)
    }
}
