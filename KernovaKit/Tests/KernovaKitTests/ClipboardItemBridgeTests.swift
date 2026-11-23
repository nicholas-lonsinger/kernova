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
    private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

    /// Serves a destination's pulls from the source's offer, landing a file or
    /// folder as a receiver does: under the offer's name, in a landing folder.
    private final class OfferPuller: ClipboardItemPulling {
        let source: ClipboardOfferSource
        let items: [OfferedItem]
        let landing: URL
        /// Where a serve that never ends fails the test.
        private let waits = OffTaskWaits()

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
            let (source, waits) = (self.source, waits)
            Task { @MainActor in
                var served: ClipboardServedRepresentation?
                await waits.run {
                    do {
                        served = try await source.served(item: item, representation: representation)
                    } catch is ClipboardServeError {}
                }
                completion(served)
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
        func paste(_ type: NSPasteboard.PasteboardType, item: Int = 0) async throws -> Data? {
            let destination = self.destination
            return try await offCooperativePool { destination.invokeProvider(forType: type, itemIndex: item) }
        }

        /// The file a paste of item `item`'s `public.file-url` lands.
        func pasteFile(item: Int = 0) async throws -> URL? {
            guard let data = try await paste(.fileURL, item: item) else { return nil }
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
            from: pasteboard, publisher: .elsewhere(), promises: promises,
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

    private func publish(
        _ source: ClipboardOfferSource, pasteCeiling: Int = .max,
        expecting outcome: ClipboardOfferPublishOutcome = .written
    ) throws -> Published {
        let landing = try directory("landing-\(UUID().uuidString)")
        let destination = FakePasteboard()
        let registry = LazyClipboardProviderRegistry()
        let publisher = ClipboardPasteboardPublisher(pasteboard: destination, providerRegistry: registry)
        #expect(
            publisher.publish(
                source.items, concealed: source.concealed, pasteCeiling: pasteCeiling,
                puller: OfferPuller(source: source, landing: landing),
                serving: Data(repeating: 1, count: 16)) == outcome)
        return Published(destination: destination, registry: registry, landing: landing)
    }

    private func single(_ source: ClipboardOfferSource) -> [Representation] {
        #expect(source.items.count == 1)
        return source.items.first?.representations ?? []
    }

    // MARK: - Text and images

    @Test("a pull after the pasteboard moved on is refused unavailable")
    func pullAfterTheCopyIsReplacedIsUnavailable() async throws {
        let pasteboard = FakePasteboard()
        pasteboard.setString("first", forType: .string)
        let source = try await readOffer(pasteboard)

        pasteboard.setString("second", forType: .string)

        await #expect(throws: ClipboardServeError.unavailable) {
            try await source.served(item: 0, representation: 0)
        }
        #expect(pasteboard.residentReads.isEmpty)
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
        let landed = try #require(try await published.pasteFile())
        #expect(landed.lastPathComponent == "photo.png")
        #expect(try Data(contentsOf: landed) == pngBytes)

        guard case .file(let again) = try await source.served(item: 0, representation: 0) else {
            Issue.record("expected the promised file")
            return
        }
        #expect(try Data(contentsOf: again) == pngBytes)
        #expect(receiver.callIns == 1)
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

    @Test("a drop's promise naming several files offers one item per name, each served once its own file lands")
    func dropPromiseOffersEachFile() async throws {
        let receiver = FakeFilePromiseReceiver(
            files: [("a.png", .file(pngBytes)), ("b.png", .file(Data("b".utf8)))], fileType: "public.png",
            named: false, deferred: true)

        let source = try await readDropOffer(promisePasteboard(), promises: [receiver])

        #expect(source.items.map { $0.representations.map(\.name) } == [[Data("a.png".utf8)], [Data("b.png".utf8)]])
        // The source reports its second file first: it lands on that file's item, not the first one owed.
        receiver.deliver(1)
        guard case .file(let second) = try await source.served(item: 1, representation: 0) else {
            Issue.record("expected the second file")
            return
        }
        #expect(try Data(contentsOf: second) == Data("b".utf8))
        receiver.deliver(0)
        guard case .file(let first) = try await source.served(item: 0, representation: 0) else {
            Issue.record("expected the first file")
            return
        }
        #expect(try Data(contentsOf: first) == pngBytes)
        #expect(receiver.callIns == 1)
    }

    // MARK: - Markers

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

        let outcome = await ClipboardPasteboardReader.readOffer(from: pasteboard, publisher: .elsewhere(), sizeOf: nil)

        guard case .suppressed(let suppressed) = outcome else {
            Issue.record("expected suppression, got \(outcome)")
            return
        }
        #expect(suppressed == reason)
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
            // Data the system resolves to a file, and Carbon's file flavors.
            "com.apple.alias-record",
            "dyn.ah62d4rv4gu80g55rf3u1a6dqqy1gc5dmqf3w46xfqr11e3a",
            "CorePasteboardFlavorType 0x616c6973",  // 'alis'
            "dyn.ah62d4rv4gu8yg55wqzkgc65yqzvg82pwqvdg22p0r73fk8puqyuda8b0ge5ggrv3g63u",
            "com.apple.bookmark",
            "dyn.ah62d4rv4gu80g55rf3u1a6dqqy1ge55trr00c6xp",
            "com.apple.alias-file",
            "dyn.ah62d4rv4gu80g55rf3u1a6dqqy1gc5dmqf3w43xmrvwu",
            "CorePasteboardFlavorType 0x66737320",  // 'fss '
            "dyn.ah62d4rv4gu8yg55wqzkgc65yqzvg82pwqvdg22p0r73fk8puqyuda8b0g25xgr3xgk2a",
            "dyn.ah62d4rv4gk80q65xea",  // 'fss ' OSType
            "CorePasteboardFlavorType 0x66737266",  // 'fsrf'
            "dyn.ah62d4rv4gu8yg55wqzkgc65yqzvg82pwqvdg22p0r73fk8puqyuda8b0g25xgr3wg25a",
            "dyn.ah62d4rv4gk80q65wq2",  // 'fsrf' OSType
            "NeXT filename pasteboard type",
            "dyn.ah62d4rv4gu8y63n2nuugq4pqqz1gc5pfeb2gc65yqzvg82pwquuhk8puqy",
            "NSFilenamePboardType",
            "dyn.ah62d4rv4gu8y6y4grf0gn5xbrzwza2xtqf3gkzd3sbwu",
            "com.apple.finder.node",
            "dyn.ah62d4rv4gu80g55rf3u1a6dqqy1gq4psqvw1epxsr7wgn",
            "com.apple.finder.noderef",
            "dyn.ah62d4rv4gu80g55rf3u1a6dqqy1gq4psqvw1epxsr7wgn6xfq2",
        ])
    func smuggledFileReferencesAreRefused(uti: String) {
        #expect(ClipboardSnapshotPolicy.shouldSkipBeforeReading(uti: uti))
        var item = OfferedItem()
        item.representations = [.make(TypeDescriptor(appleUTI: uti), .inline, size: 0)]
        #expect(!ClipboardPromisePolicy.keeps(item.representations[0]))

        let specs = ClipboardPasteboardPublisher.itemSpecs(
            for: [item], concealed: false, puller: FixedPuller(bytes: Data("file:///etc/hosts".utf8)))

        #expect(specs.isEmpty)
    }

    /// The bytes a destination pasteboard is served for `uti` when a peer
    /// offers `bytes` under it.
    private func served(_ bytes: Data, as uti: String) async throws -> Data? {
        var item = OfferedItem()
        item.representations = [.make(TypeDescriptor(appleUTI: uti), .inline, size: 0)]
        let destination = FakePasteboard()
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        _ = ClipboardPasteboardPublisher(pasteboard: destination, providerRegistry: registry)
            .publish(
                [item], concealed: false, pasteCeiling: .max, puller: FixedPuller(bytes: bytes),
                serving: Data(repeating: 1, count: 16)
            )
        return try await offCooperativePool { destination.invokeProvider(forType: .init(uti)) }
    }

    @Test(
        "RTFD is admitted only while no file wrapper in it is a symbolic link",
        arguments: [
            "com.apple.flat-rtfd",
            "COM.APPLE.FLAT-RTFD",
            "com.apple.rtfd",
            "NeXT RTFD pasteboard type",
            "dyn.ah62d4rv4gu80g55rf3u1a6dqqy1gq5dbsu01e7dgqu",  // com.apple.flat-rtfd, as a legacy name
            "dyn.ah62d4rv4gk8zezcgku",  // 'RTFD' OSType
            "dyn.ah62d4rv4gu8yg55wqzkgc65yqzvg82pwqvdg22p0r73fk8puqyuda8b1gk5xkrv0g24a",  // 'rtfd' flavor
        ])
    func rtfdRefusesSymbolicLinks(uti: String) throws {
        let hostFile = try directory("host").appendingPathComponent("secret.png")
        try pngBytes.write(to: hostFile)

        #expect(ClipboardSnapshotPolicy.admits(try flatRTFD(attachment: pngBytes), servedAs: uti))
        #expect(ClipboardSnapshotPolicy.admits(try flatRTFD(attachment: pngBytes, depth: 2), servedAs: uti))
        for depth in [0, 2] {
            let linked = try flatRTFD(linkingTo: hostFile, depth: depth)
            #expect(!ClipboardSnapshotPolicy.admits(linked, servedAs: uti), "a link at depth \(depth)")
        }
        #expect(!ClipboardSnapshotPolicy.admits(Data("{\\rtf1 not a wrapper}".utf8), servedAs: uti))
    }

    @Test(
        "a titled URL list is admitted web URLs but never a file URL",
        arguments: [
            "WebURLsWithTitlesPboardType",
            "weburlswithtitlespboardtype",
            "dyn.ah62d4rv4gu8zs3pcnzme2641rf4guzdmsv0gn64uqm10c6xenv61a3k",
        ])
    func titledURLsRefuseFileURLs(uti: String) throws {
        func plist(_ urls: [String], _ titles: [String]) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: [urls, titles], format: .xml, options: 0)
        }

        #expect(ClipboardSnapshotPolicy.admits(try plist(["https://example.com/"], ["Example Domain"]), servedAs: uti))
        #expect(!ClipboardSnapshotPolicy.admits(try plist(["file:///etc/hosts"], ["Hosts"]), servedAs: uti))
        let mixed = try plist(["https://example.com/", "/etc/hosts"], ["Example", "Hosts"])
        #expect(!ClipboardSnapshotPolicy.admits(mixed, servedAs: uti))
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
        func served(_ bytes: Data) async throws -> Data? { try await self.served(bytes, as: uti) }
        func plist(_ strings: [String]) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: strings, format: .xml, options: 0)
        }

        let web = Data("https://example.com/".utf8)
        #expect(try await served(web) == web)
        #expect(try await served(try plist(["https://example.com/", ""])) != nil)
        for smuggled in [
            Data("file:///etc/hosts".utf8), Data(" FILE:///etc/hosts".utf8), Data("/etc/hosts".utf8),
            try plist(["file:///etc/hosts", ""]), try plist(["hosts", "file:///etc/"]),
        ] {
            #expect(try await served(smuggled) == nil, "\(String(decoding: smuggled, as: UTF8.self))")
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
        item.representations = [
            .make(TypeDescriptor(appleUTI: NSPasteboard.PasteboardType.string.rawValue), .inline, size: 0)
        ]
        let specs = ClipboardPasteboardPublisher.itemSpecs(
            for: [item], concealed: false, puller: puller, eventLoopWait: { nil })

        #expect(specs.first?.provide(NSPasteboard.PasteboardType.string.rawValue) == nil)
        #expect(puller.starts.withLock { $0 } == 0)
    }
}
