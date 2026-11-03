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

        func pullBytes(item: Int, representation: Int, completion: @escaping @Sendable (Data?) -> Void) {
            serve(item, representation) { served in
                guard case .bytes(let data)? = served else { return completion(nil) }
                completion(data)
            }
        }

        func pullFile(item: Int, representation: Int, completion: @escaping @Sendable (URL?) -> Void) {
            let name = String(decoding: items[item].representations[representation].name, as: UTF8.self)
            let destination = landing.appendingPathComponent(name)
            serve(item, representation) { served in
                switch served {
                case .file(let url)?, .folder(let url)?:
                    let copied = (try? FileManager.default.copyItem(at: url, to: destination)) != nil
                    completion(copied ? destination : nil)
                default:
                    completion(nil)
                }
            }
        }

        /// Serves on the main actor, completing from there rather than on the
        /// paste's thread.
        private func serve(
            _ item: Int, _ representation: Int,
            then completion: @escaping @Sendable (ClipboardServedRepresentation?) -> Void
        ) {
            let source = self.source
            Task { @MainActor in
                completion(try? await source.serve(item: item, representation: representation))
            }
        }
    }

    /// Completes every pull with `bytes`, counting the pulls it was asked to
    /// start.
    private final class FixedPuller: ClipboardItemPulling {
        let bytes: Data
        let starts = Locked(0)

        init(bytes: Data) { self.bytes = bytes }

        func pullBytes(item: Int, representation: Int, completion: @escaping @Sendable (Data?) -> Void) {
            starts.withLock { $0 += 1 }
            completion(bytes)
        }

        func pullFile(item: Int, representation: Int, completion: @escaping @Sendable (URL?) -> Void) {
            starts.withLock { $0 += 1 }
            completion(nil)
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
                source.items, concealed: source.concealed, servingFileURLs: servingFileURLs,
                puller: OfferPuller(source: source, landing: landing)))
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

    @Test(
        "a promise whose name is no single path component is offered under its type's extension",
        arguments: ["..", ".", "a/b", "a\u{0}b", String(repeating: "x", count: PathComponent.maxByteCount + 1)])
    func misnamedPromiseIsUntitled(name: String) async throws {
        let receiver = FakeFilePromiseReceiver(name: name, fileType: "public.png", contents: .file(pngBytes))

        let source = try await readOffer(promisePasteboard(), promises: [receiver])

        #expect(source.items.map { $0.representations.first?.name } == [Data("Untitled.png".utf8)])
    }

    @Test("a promise whose source fails is refused read-failed")
    func failedPromiseIsReadFailed() async throws {
        let receiver = FakeFilePromiseReceiver(name: "x.png", fileType: "public.png", contents: .failure)
        let source = try await readOffer(promisePasteboard(), promises: [receiver])

        await #expect(throws: ClipboardServeError.readFailed) {
            try await source.serve(item: 0, representation: 0)
        }
    }

    @Test("a legacy promise item takes its own receiver, so the next promise keeps its own")
    func legacyPromiseKeepsReceiversAligned() async throws {
        let legacy = NSPasteboard.PasteboardType(
            "dyn.ah62d4rv4gu8yc6durvwwa3xmrvw1gkdusm1044pxqyuha2pxsvw0e55bsmwca7d3sbwu")
        let pasteboard = FakePasteboard()
        pasteboard.setItems([
            [(type: legacy, data: Data("txt".utf8))], promiseTypes.map { (type: $0, data: Data()) },
        ])
        let first = FakeFilePromiseReceiver(
            name: "legacy.txt", fileType: "public.plain-text", contents: .file(Data("A".utf8)))
        let second = FakeFilePromiseReceiver(name: "photo.png", fileType: "public.png", contents: .file(pngBytes))

        let source = try await readOffer(pasteboard, promises: [first, second])

        let names = source.items.map { $0.representations.first?.name }
        #expect(names == [Data("legacy.txt".utf8), Data("photo.png".utf8)])
        #expect(source.items.allSatisfy { $0.representations.first?.promised == true })
    }

    @Test("an item whose file resolves still takes its receiver, so the next promise keeps its own")
    func resolvedFileConsumesItsReceiver() async throws {
        let file = try directory("on-disk").appendingPathComponent("first.txt")
        try Data("A".utf8).write(to: file)
        let promise = promiseTypes.map { (type: $0, data: Data()) }
        let pasteboard = FakePasteboard()
        pasteboard.setItems([[(type: .fileURL, data: Data(file.absoluteString.utf8))] + promise, promise])
        let first = FakeFilePromiseReceiver(
            name: "first.txt", fileType: "public.plain-text", contents: .file(Data("A".utf8)))
        let second = FakeFilePromiseReceiver(name: "second.png", fileType: "public.png", contents: .file(pngBytes))

        let source = try await readOffer(pasteboard, promises: [first, second])

        let names = source.items.map { $0.representations.first?.name }
        #expect(names == [Data("first.txt".utf8), Data("second.png".utf8)])
        #expect(source.items.map { $0.representations.first?.promised } == [false, true])
        #expect(first.callIns == 0)
    }

    // MARK: - Drops

    /// What a drop of `pasteboard` offers, its `promises` called in first into a fresh directory.
    private func readDropOffer(
        _ pasteboard: FakePasteboard, promises: [any FilePromiseReceiving] = []
    ) async throws -> ClipboardOfferSource {
        let folder = try directory("drop-\(UUID().uuidString)")
        let called = promises.map { CalledInFilePromise.callIn($0, into: folder) }
        let outcome = await ClipboardPasteboardReader.readDropOffer(from: pasteboard, promises: called, sizeOf: nil)
        guard case .offer(let source, _) = outcome else {
            Issue.record("expected a drop offer, got \(outcome)")
            throw CancellationError()
        }
        return source
    }

    @Test("a drop's promise is called in before its offer is read, and offered under the name it gives then")
    func dropPromiseIsCalledInFirst() async throws {
        let receiver = FakeFilePromiseReceiver(
            name: "IMG_0001.png", fileType: "public.png", contents: .file(pngBytes), named: false)

        let source = try await readDropOffer(promisePasteboard(), promises: [receiver])

        #expect(receiver.callIns == 1)
        let representation = try #require(single(source).first)
        #expect(representation.name == Data("IMG_0001.png".utf8))
        #expect(representation.promised)
        guard case .file(let landed) = try await source.serve(item: 0, representation: 0) else {
            Issue.record("expected the promised file")
            return
        }
        #expect(try Data(contentsOf: landed) == pngBytes)
        #expect(receiver.callIns == 1)
    }

    @Test("a dropped item carrying a promise beside a file on disk offers the promise")
    func dropPrefersThePromise() async throws {
        let derivative = try directory("library").appendingPathComponent("derivative.jpeg")
        try Data("smaller".utf8).write(to: derivative)
        let pasteboard = FakePasteboard()
        pasteboard.setItem(
            [(type: .fileURL, data: Data(derivative.absoluteString.utf8))]
                + promiseTypes.map { (type: $0, data: Data()) })
        let receiver = FakeFilePromiseReceiver(
            name: "IMG_0001.heic", fileType: "public.heic", contents: .file(pngBytes))

        let source = try await readDropOffer(pasteboard, promises: [receiver])

        #expect(source.items.map { $0.representations.map(\.name) } == [[Data("IMG_0001.heic".utf8)]])
    }

    @Test("a drop offers its files and folders, one representation each, and nothing else it carries")
    func dropOffersTreesOnly() async throws {
        let image = try directory("dropped").appendingPathComponent("picture.png")
        try pngBytes.write(to: image)
        let folder = try directory("dropped/Album")
        let pasteboard = FakePasteboard()
        pasteboard.setItems([
            [(type: .string, data: Data("hello".utf8))],
            [(type: .fileURL, data: Data(image.absoluteString.utf8))],
            [(type: .fileURL, data: Data(folder.absoluteString.utf8))],
        ])

        let source = try await readDropOffer(pasteboard)

        #expect(source.items.map { $0.representations.map(\.storage) } == [[.file], [.folder]])
        #expect(
            source.items.map { $0.representations.map(\.name) } == [[Data("picture.png".utf8)], [Data("Album".utf8)]])
    }

    // MARK: - Markers

    @Test("a concealed copy is offered concealed and published with the marker, which reads back concealed")
    func concealedRoundTrips() async throws {
        let pasteboard = FakePasteboard()
        pasteboard.setItem([(type: .string, data: Data("hunter2".utf8)), (type: concealedType, data: Data())])

        let source = try await readOffer(pasteboard)
        #expect(source.concealed)
        #expect(single(source).map(\.type.appleUTI) == [ClipboardContent.utf8TextUTI])

        let published = try publish(source)
        defer { published.registry.releaseAllForTesting() }
        #expect(published.destination.promisedTypesByItem == [[.string, concealedType]])
        let reread = try await readOffer(published.destination)
        #expect(reread.concealed)
        #expect(published.destination.providerInvocations == 0)
    }

    @Test(
        "a transient or auto-generated copy offers nothing, even concealed",
        arguments: [
            (ClipboardSnapshotPolicy.transientMarkerUTI, ClipboardSnapshotPolicy.SkipReason.transientSnapshot),
            (ClipboardSnapshotPolicy.autoGeneratedMarkerUTI, .autoGeneratedSnapshot),
        ])
    func markedMomentaryIsSuppressed(marker: String, reason: ClipboardSnapshotPolicy.SkipReason) async {
        // A password manager's auto-type marks its copy both concealed and transient.
        let pasteboard = FakePasteboard()
        pasteboard.setItem([
            (type: .string, data: Data("hunter2".utf8)), (type: concealedType, data: Data()),
            (type: .init(marker), data: Data()),
        ])

        let outcome = await ClipboardPasteboardReader.readOffer(from: pasteboard, sizeOf: nil)

        guard case .suppressed(let suppressed) = outcome else {
            Issue.record("expected suppression, got \(outcome)")
            return
        }
        #expect(suppressed == reason)
    }

    @Test("a peer's transient marker is never published")
    func peerTransientMarkerIsNotPublished() {
        var item = OfferedItem()
        item.representations = [
            .make(TypeDescriptor(appleUTI: ClipboardContent.utf8TextUTI), .inline, size: 0),
            .make(TypeDescriptor(appleUTI: ClipboardSnapshotPolicy.transientMarkerUTI), .inline, size: 0),
        ]

        let specs = ClipboardPasteboardPublisher.itemSpecs(
            for: [item], concealed: false, puller: FixedPuller(bytes: Data("x".utf8)))

        #expect(specs.map(\.types) == [[ClipboardContent.utf8TextUTI]])
    }

    // MARK: - Smuggled file references

    @Test(
        "no spelling of a file reference a peer offers INLINE is published",
        arguments: [
            "PUBLIC.FILE-URL",
            "dyn.ah62d4rv4gu8y6y4grf0gn5xbrzw1gydcr7u1e3cytf2gn",  // NSFilenamesPboardType
            "Dyn.ah62d4rv4gu8y6y4grf0gn5xbrzw1gydcr7u1e3cytf2gn",
            "DYN.AH62D4RV4GU8Y6Y4GRF0GN5XBRZW1GYDCR7U1E3CYTF2GN",  // encodes nothing
            "dyn.ah62d4rv4gu8yg55wqzkgc65yqzvg82pwqvdg22p0r73fk8puqyuda8b0g25xnr3wg3bu",  // 'furl' flavor
            "dyn.ah62d4rv4gu8yc6durvwwa3xmrvw1gkdusm1044pxqyuha2pxsvw0e55bsmwca7d3sbwu",  // legacy files promise
            "COM.APPLE.PASTEBOARD.PROMISED-FILE-URL",
            "com.apple.pasteboard.promised-suggested-file-name",
            "com.apple.pasteboard.promised-file-name",
            "com.apple.pasteboard.NSFilePromiseID",
            "com.apple.NSFilePromiseItemMetaData",
            "nsfilenamespboardtype",
            "ORG.NSPASTEBOARD.CONCEALEDTYPE",
        ])
    func smuggledFileReferencesAreRefused(uti: String) {
        var item = OfferedItem()
        item.representations = [.make(TypeDescriptor(appleUTI: uti), .inline, size: 0)]
        #expect(!ClipboardPromisePolicy.keeps(item.representations[0]))

        let specs = ClipboardPasteboardPublisher.itemSpecs(
            for: [item], concealed: false, puller: FixedPuller(bytes: Data("file:///etc/hosts".utf8)))

        #expect(specs.isEmpty)
    }

    @Test(
        "a URL flavor is served a web URL but never a file URL",
        arguments: [
            "public.url",
            "Public.URL",
            // Apple URL pasteboard type, as a pasteboard item carries it.
            "dyn.ah62d4rv4gu8yc6durvwwaznwmuuha2pxsvw0e55bsmwca7d3sbwu",
        ])
    func urlFlavorRefusesFileURLs(uti: String) async throws {
        func served(_ bytes: Data) async -> Data? {
            var item = OfferedItem()
            item.representations = [.make(TypeDescriptor(appleUTI: uti), .inline, size: 0)]
            let destination = FakePasteboard()
            let registry = LazyClipboardProviderRegistry()
            defer { registry.releaseAllForTesting() }
            ClipboardPasteboardPublisher(pasteboard: destination, providerRegistry: registry)
                .publish([item], concealed: false, puller: FixedPuller(bytes: bytes))
            return await offCooperativePool { destination.invokeProvider(forType: .init(uti)) }
        }
        func plist(_ strings: [String]) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: strings, format: .xml, options: 0)
        }

        let web = Data("https://example.com/".utf8)
        #expect(await served(web) == web)
        #expect(await served(try plist(["https://example.com/", ""])) != nil)
        for smuggled in [
            Data("file:///etc/hosts".utf8), Data(" FILE:///etc/hosts".utf8), Data("/etc/hosts".utf8),
            try plist(["file:///etc/hosts", ""]), try plist(["hosts", "file:///etc/"]),
        ] {
            #expect(await served(smuggled) == nil, "\(String(decoding: smuggled, as: UTF8.self))")
        }
    }

    // MARK: - Pulls on the paste's thread

    @Test("a fire on the main thread with no event loop to run is refused before any pull starts")
    func mainThreadFireWithoutEventLoopIsRefused() {
        // A wait source that declines stands in for the tracking or modal loop
        // this bundle cannot enter; the app-hosted counterpart proving the
        // event-loop wait serves is `ClipboardItemPullMainThreadTests`.
        let puller = FixedPuller(bytes: Data("x".utf8))
        var item = OfferedItem()
        item.representations = [.make(TypeDescriptor(appleUTI: ClipboardContent.utf8TextUTI), .inline, size: 0)]
        let specs = ClipboardPasteboardPublisher.itemSpecs(
            for: [item], concealed: false, puller: puller, eventLoopWait: { nil })

        #expect(specs.first?.provide(ClipboardContent.utf8TextUTI) == nil)
        #expect(puller.starts.withLock { $0 } == 0)
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
