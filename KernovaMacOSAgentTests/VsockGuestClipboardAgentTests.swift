import Testing
import Foundation
import AppKit
import CryptoKit
import Darwin
import KernovaKit
import KernovaTestSupport
import UniformTypeIdentifiers

// MARK: - Fake Pasteboard

/// In-memory `Pasteboard` substitute for the lazy promise model.
///
/// Mirrors the `NSPasteboardItem`s the agent reads and writes, but the agent
/// never writes resident bytes any more: a host offer registers one *promise*
/// per item (a set of types backed by an `NSPasteboardItemDataProvider`), and
/// the bytes are served on demand only when the OS asks for a type. The fake
/// records the promised items and exposes `invokeProvider` to simulate the OS
/// asking — which drives the agent's blocking lazy pull.
///
/// Two write surfaces:
/// - `writeItems(_:)` — the production protocol method the agent calls on a host
///   offer; records one promise per item (no bytes). A multi-file offer writes
///   several.
/// - `setItem(_:)` / `setItems(_:)` / `setString(_:forType:)` — test-only setup
///   that places resident (type, data) pairs, modelling a *user* copying inside
///   the guest; used to drive the outbound path.
///
/// Thread-safe via NSLock so tests running on DispatchQueue.main don't race the
/// setup thread or a background `invokeProvider`.
final class FakePasteboard: Pasteboard, @unchecked Sendable {
    /// One promised pasteboard item: its types and the provider serving them.
    private struct PromisedItem {
        let types: [NSPasteboard.PasteboardType]
        let provider: NSPasteboardItemDataProvider
    }

    private let lock = NSLock()
    private var storedChangeCount: Int = 0
    /// Resident (type, data) pairs, possibly across several items.
    ///
    /// Only the test-only setup paths populate these (a user copying inside the
    /// guest). The agent's promise writes leave these empty; promised bytes are
    /// served lazily via the per-item provider.
    private var storedRepresentations: [(type: NSPasteboard.PasteboardType, data: Data)] = []
    /// Items the current promise covers — one per pasteboard item the agent
    /// wrote (one inline item plus one per file rep).
    private var promisedItems: [PromisedItem] = []
    private var storedWriteFailureCount: Int = 0

    /// Fires after every `FakePasteboard` mutation.
    ///
    /// `writeItems`/`clearContents`/`setItem`/`setItems` call `notify()`, so a
    /// test awaits the promised-state change instead of polling the `…ForTesting`
    /// accessors on a contended scheduler. See docs/TESTING.md "Async waits in tests".
    let changed = AsyncGate()

    var changeCount: Int {
        lock.withLock { storedChangeCount }
    }

    var firstItemTypes: [NSPasteboard.PasteboardType] {
        lock.withLock {
            if let first = promisedItems.first { return first.types }
            return storedRepresentations.map(\.type)
        }
    }

    var itemFileURLs: [URL] {
        lock.withLock {
            storedRepresentations
                .filter { $0.type == .fileURL }
                .compactMap { String(data: $0.data, encoding: .utf8).flatMap(URL.init(string:)) }
        }
    }

    /// Every promised type across all items, concatenated in item order (a
    /// multi-file offer promises one item per file).
    ///
    /// Empty after a `clearContents` or a resident `setItem`.
    var promisedTypesForTesting: [NSPasteboard.PasteboardType] {
        lock.withLock { promisedItems.flatMap(\.types) }
    }

    /// Number of promised pasteboard items the agent's last write registered.
    var promisedItemCountForTesting: Int {
        lock.withLock { promisedItems.count }
    }

    /// Snapshots the first promised item's provider so a test can invoke it
    /// directly (e.g. after a superseding offer replaced it) without going
    /// through the recorded-provider path `invokeProvider` uses.
    func captureProviderForTesting() -> NSPasteboardItemDataProvider? {
        lock.withLock { promisedItems.first?.provider }
    }

    func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        lock.withLock { storedRepresentations.first(where: { $0.type == type })?.data }
    }

    /// Make the next `n` `writeItems` calls return `false` and skip storage
    /// updates.
    ///
    /// Lets tests model OS-level pasteboard write failures.
    func failNextWrite(times: Int = 1) {
        lock.withLock { storedWriteFailureCount += times }
    }

    @discardableResult
    func clearContents() -> Int {
        // Real NSPasteboard.clearContents() bumps the change count and returns
        // the new value. Mirror that behavior so the fake's echo-suppression
        // delta matches a real pasteboard.
        let newCount = lock.withLock {
            storedRepresentations.removeAll()
            promisedItems.removeAll()
            storedChangeCount += 1
            return storedChangeCount
        }
        changed.notify()
        return newCount
    }

    /// Options passed to the most recent `prepareForNewContents(with:)`; `nil`
    /// until the agent's first promise write.
    var lastPrepareOptionsForTesting: NSPasteboard.ContentsOptions? {
        lock.withLock { storedLastPrepareOptions }
    }

    private var storedLastPrepareOptions: NSPasteboard.ContentsOptions?

    @discardableResult
    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int {
        let newCount = lock.withLock {
            storedRepresentations.removeAll()
            promisedItems.removeAll()
            storedLastPrepareOptions = options
            storedChangeCount += 1
            return storedChangeCount
        }
        changed.notify()
        return newCount
    }

    /// Production protocol method: registers one lazy promise per item.
    ///
    /// Each entry promises its `types`, served by its own `provider` when the OS
    /// asks. Records no bytes.
    @discardableResult
    func writeItems(
        _ items: [(types: [NSPasteboard.PasteboardType], provider: NSPasteboardItemDataProvider)]
    ) -> Bool {
        let didWrite = lock.withLock {
            if storedWriteFailureCount > 0 {
                storedWriteFailureCount -= 1
                return false
            }
            storedRepresentations.removeAll()
            promisedItems = items.map { PromisedItem(types: $0.types, provider: $0.provider) }
            storedChangeCount += 1
            return true
        }
        if didWrite { changed.notify() }
        return didWrite
    }

    /// Simulates the OS asking the first promised item that offers `type`.
    func invokeProvider(forType type: NSPasteboard.PasteboardType) -> Data? {
        invokeProvider(forType: type, itemIndex: nil)
    }

    /// Simulates the OS asking a promised item for a type's bytes.
    ///
    /// Builds a fresh `NSPasteboardItem`, invokes the recorded provider's
    /// `pasteboard(_:item:provideDataForType:)` synchronously, and returns the
    /// data the provider set (or `nil` when it declined). `itemIndex` targets a
    /// specific promised item (needed when several items promise the same type,
    /// e.g. `.fileURL` across multiple files); `nil` uses the first item offering
    /// the type. This call BLOCKS until the agent's lazy pull resolves — call it
    /// OFF the test's main actor so the fake host can respond to the resulting
    /// `ClipboardRequest` concurrently.
    ///
    /// Resolved bytes are cached back into the resident item (mirroring how a
    /// real `NSPasteboardItem` retains provided data) so a subsequent
    /// `data(forType:)` read reflects what a paste would see — without
    /// re-invoking the provider.
    func invokeProvider(forType type: NSPasteboard.PasteboardType, itemIndex: Int?) -> Data? {
        let provider: NSPasteboardItemDataProvider? = lock.withLock {
            if let itemIndex {
                guard promisedItems.indices.contains(itemIndex) else { return nil }
                let item = promisedItems[itemIndex]
                return item.types.contains(type) ? item.provider : nil
            }
            return promisedItems.first { $0.types.contains(type) }?.provider
        }
        guard let provider else { return nil }
        let item = NSPasteboardItem()
        provider.pasteboard(nil, item: item, provideDataForType: type)
        let resolved = item.data(forType: type)
        if let resolved {
            lock.withLock {
                storedRepresentations.removeAll { $0.type == type }
                storedRepresentations.append((type: type, data: resolved))
            }
        }
        return resolved
    }

    // MARK: - Test-only resident setup (a user copying inside the guest)

    /// Places resident (type, data) pairs, modelling a user copying in the guest.
    ///
    /// The agent's outbound poll reads these. Clears any promise. Models one
    /// pasteboard item; `setItems` models several (a multi-file copy).
    @discardableResult
    func setItem(_ representations: [(type: NSPasteboard.PasteboardType, data: Data)]) -> Bool {
        lock.withLock {
            storedRepresentations = representations
            promisedItems.removeAll()
            storedChangeCount += 1
        }
        changed.notify()
        return true
    }

    /// Places several resident pasteboard items, modelling a multi-select copy
    /// in the guest.
    ///
    /// The outbound poll reads each item's `.fileURL` via `itemFileURLs`.
    @discardableResult
    func setItems(_ items: [[(type: NSPasteboard.PasteboardType, data: Data)]]) -> Bool {
        lock.withLock {
            storedRepresentations = items.flatMap { $0 }
            promisedItems.removeAll()
            storedChangeCount += 1
        }
        changed.notify()
        return true
    }

    /// Replaces the resident item with a single text representation —
    /// equivalent to a user copying text inside the guest.
    @discardableResult
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool {
        setItem([(type: type, data: Data(string.utf8))])
    }
}

// MARK: - File Provider publishing double

/// Records the agent's File Provider publish calls and returns a canned URL.
///
/// Lets `handleOffer`'s routing decision be asserted without a real domain.
final class FakeFileProviderPublisher: FileProviderPublishing, @unchecked Sendable {
    struct Published: Equatable {
        let generation: UInt64
        let repIndex: Int
        let filename: String
        let byteCount: UInt64
        let uti: String
    }

    private let lock = NSLock()
    private var publishedStorage: [Published] = []
    private var clearCountStorage = 0
    private var urlToReturnStorage: URL?

    init(urlToReturn: URL?) { self.urlToReturnStorage = urlToReturn }

    /// The URL the next `publishSingleFile` call returns.
    ///
    /// Mutable so a test can model an availability flip: start `nil` (the
    /// domain wasn't `.ready`, so the offer lands on the sync path), then set a
    /// URL before driving the re-publish (#429).
    var urlToReturn: URL? {
        get { lock.withLock { urlToReturnStorage } }
        set { lock.withLock { urlToReturnStorage = newValue } }
    }

    func publishSingleFile(
        generation: UInt64, repIndex: Int, filename: String, byteCount: UInt64, uti: String
    ) -> URL? {
        let url = lock.withLock {
            publishedStorage.append(
                Published(
                    generation: generation, repIndex: repIndex, filename: filename,
                    byteCount: byteCount, uti: uti))
            return urlToReturnStorage
        }
        return url
    }

    func clearOffer() { lock.withLock { clearCountStorage += 1 } }

    var published: [Published] { lock.withLock { publishedStorage } }
    var clearCount: Int { lock.withLock { clearCountStorage } }
}

// MARK: - Test Suite

@Suite("VsockGuestClipboardAgent state machine")
struct VsockGuestClipboardAgentTests {
    // MARK: - Agent factory helpers

    /// Sets up an agent with the given pasteboard and a socket provider that
    /// returns the given fd on first call, transient failure thereafter.
    ///
    /// The short retry interval keeps the pause/resume wake-up snappy — the agent
    /// is now default-paused at construction, and `setEnabled(true)` only
    /// takes effect on the next loop iteration after the current sleep.
    private func makeAgent(
        pasteboard: FakePasteboard, agentFd: Int32,
        freeSpaceProvider: ClipboardFileStaging.FreeSpaceProvider? = nil
    ) -> VsockGuestClipboardAgent {
        let provided = AtomicInt()
        let client = VsockGuestClient(
            port: 49152,
            label: "clipboard-test",
            retryInterval: .milliseconds(50)
        ) { _, _ in
            provided.increment() == 1 ? .success(agentFd) : .failure(.transient("test: no fd"))
        }
        return VsockGuestClipboardAgent(
            pasteboard: pasteboard, client: client, freeSpaceProvider: freeSpaceProvider,
            stagingTempRoot: FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString, isDirectory: true))
    }

    /// Starts the agent, enables it (production agents are default-disabled
    /// until host policy says otherwise), and waits until `liveChannel` is
    /// published on the main queue.
    ///
    /// After this returns, callers driving
    /// `checkClipboardChange()` see a non-nil channel.
    private func startAgentAndWaitForLiveChannel(
        agent: VsockGuestClipboardAgent
    ) async throws {
        agent.start()
        agent.setEnabled(true)
        // RATIONALE: agent connection/lifecycle state (`liveChannelForTesting`,
        // `inboundPromiseGenerationForTesting`, `isEnabledForTesting`) is the
        // system-under-test's own state — not a test double we can fire an
        // AsyncGate from, and the agent isn't @Observable. These reads stay
        // polling per docs/TESTING.md "Async waits in tests" (sanctioned no-signal
        // poll); the pasteboard-write waits, where the async timing flake
        // actually lives, use `pasteboard.changed` instead.
        try await waitUntil { agent.liveChannelForTesting != nil }
    }

    // MARK: - Outbound (agent is the sender)

    @Test("outbound text: a local change is announced as a metadata offer, then streamed on request")
    func outboundTextOfferAndStream() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let text = "hello from guest"
        pasteboard.setString(text, forType: .string)
        await MainActor.run { agent.checkClipboardChange() }

        // The offer is metadata only: one inline text rep, no bytes.
        let offerFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            throw TestFailure("Expected ClipboardOffer, got \(String(describing: offerFrame.payload))")
        }
        #expect(offer.generation >= 1)
        #expect(offer.repInfo.count == 1)
        let info = try #require(offer.repInfo.first)
        #expect(info.uti == ClipboardContent.utf8TextUTI)
        #expect(info.isInline)
        #expect(info.byteCount == UInt64(Data(text.utf8).count))
        #expect(info.filename.isEmpty)

        // Pull rep 0: choose a transferID whose low 16 bits select the rep index.
        let transferID: UInt64 = (offer.generation << 16) | 0
        try hostChannel.send(
            makeRequestFrame(
                generation: offer.generation, transferID: transferID, uti: info.uti))
        // Collect Begin→Chunk(s)→End; the collector sends the go-signal on Begin.
        let transfer = try await collectOutboundTransfer(transferID: transferID, from: hostChannel)
        #expect(transfer.begin.uti == ClipboardContent.utf8TextUTI)
        #expect(transfer.begin.isInline)
        #expect(transfer.bytes == Data(text.utf8))
        #expect(transfer.end.totalBytes == UInt64(Data(text.utf8).count))
        #expect(transfer.end.sha256 == Data(SHA256.hash(data: Data(text.utf8))))
    }

    @Test("outbound copied file: offered by stat (no read), streamed from disk on request")
    func outboundCopiedFileOfferAndStream() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // A non-image file, comfortably larger than the old 100 MiB cap would
        // have been *modeled* by — we keep the real bytes modest for speed and
        // assert the no-cap behavior by the rep simply being offered and
        // streamed in full. A copied file leaves only a file URL on the
        // pasteboard (Finder ⌘C).
        let contents = Data((0..<(300 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
        let url = try writeTempFile(name: "notes.bin", data: contents)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        pasteboard.setItem([
            (type: .fileURL, data: Data(url.absoluteString.utf8))
        ])
        await MainActor.run { agent.checkClipboardChange() }

        let offerFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            throw TestFailure("Expected ClipboardOffer, got \(String(describing: offerFrame.payload))")
        }
        #expect(offer.repInfo.count == 1)
        let info = try #require(offer.repInfo.first)
        // No rejection despite a file far over the old cap conceptually: the
        // offer carries the stat'd size and the real filename.
        #expect(info.byteCount == UInt64(contents.count))
        #expect(info.filename == "notes.bin")
        // A non-image file is file-only (not inlined) per shouldInline's rule.
        #expect(!info.isInline)

        // Request rep 0; the agent streams the file's bytes from disk.
        let transferID: UInt64 = (offer.generation << 16) | 0
        try hostChannel.send(
            makeRequestFrame(
                generation: offer.generation, transferID: transferID, uti: info.uti))

        let transfer = try await collectOutboundTransfer(
            transferID: transferID, from: hostChannel, timeout: .seconds(10))
        #expect(!transfer.begin.isInline)
        #expect(transfer.begin.filename == "notes.bin")
        #expect(transfer.bytes == contents)
        #expect(transfer.end.sha256 == Data(SHA256.hash(data: contents)))
    }

    @Test("a copied image file is offered inline with the image UTI")
    func outboundCopiedImageFileOffersInline() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let png = try makeTestPNG()
        let url = try writeTempFile(name: "picture.png", data: png)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        pasteboard.setItem([
            (type: .fileURL, data: Data(url.absoluteString.utf8))
        ])
        await MainActor.run { agent.checkClipboardChange() }

        let offerFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            throw TestFailure("Expected ClipboardOffer, got \(String(describing: offerFrame.payload))")
        }
        let info = try #require(offer.repInfo.first)
        #expect(info.uti == UTType.png.identifier)
        #expect(info.filename == "picture.png")
        // An image file is inlined (per shouldInline) so a paste yields the image.
        #expect(info.isInline)
        #expect(info.byteCount == UInt64(png.count))

        // The streamed bytes are the file's bytes (read from disk on request).
        let transferID: UInt64 = (offer.generation << 16) | 0
        try hostChannel.send(
            makeRequestFrame(
                generation: offer.generation, transferID: transferID, uti: info.uti))
        let transfer = try await collectOutboundTransfer(transferID: transferID, from: hostChannel)
        #expect(transfer.bytes == png)
    }

    @Test("outbound multiple files: every copied file is offered as its own rep, in order")
    func outboundMultipleFiles() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        let a = try writeTempFile(name: "a.txt", data: Data("aaa".utf8))
        let b = try writeTempFile(name: "b.bin", data: Data([1, 2, 3, 4]))
        defer { try? FileManager.default.removeItem(at: a.deletingLastPathComponent()) }
        defer { try? FileManager.default.removeItem(at: b.deletingLastPathComponent()) }
        // A multi-select Finder ⌘C leaves one file URL per pasteboard item.
        pasteboard.setItems([
            [(type: .fileURL, data: Data(a.absoluteString.utf8))],
            [(type: .fileURL, data: Data(b.absoluteString.utf8))],
        ])
        await MainActor.run { agent.checkClipboardChange() }

        let offer = try await awaitOffer(on: hostChannel)
        #expect(offer.repInfo.count == 2)
        #expect(offer.repInfo.map(\.filename) == ["a.txt", "b.bin"])
        // Both are non-image files → file-only.
        #expect(offer.repInfo.allSatisfy { !$0.isInline })
        #expect(offer.repInfo[1].byteCount == 4)
    }

    @Test("outbound: a staging-root file among several copied files is dropped, the rest offered")
    func outboundDropsStagedFileAmongSeveral() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        // Materialize a file into the agent's staging root via an inbound paste.
        let contents = Data("staged body".utf8)
        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        try hostChannel.send(
            makeOfferFrame(
                generation: 3,
                reps: [
                    RepInfo(
                        uti: txtUTI, byteCount: UInt64(contents.count), filename: "notes.txt",
                        isInline: false)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting.contains(.fileURL) }
        let pull = lazyPull(pasteboard, forType: .fileURL)
        try await driveInboundStream(
            generation: 3, uti: txtUTI, filename: "notes.txt", payload: contents, isInline: false,
            on: hostChannel)
        let staged = try #require(
            (await pull.value).flatMap { String(data: $0, encoding: .utf8) }
                .flatMap(URL.init(string:)))

        // Copy [the staged file, a fresh file]: the staging-root file is dropped
        // per-file; only the fresh file is offered back to the host.
        let fresh = try writeTempFile(name: "fresh.txt", data: Data("fresh".utf8))
        defer { try? FileManager.default.removeItem(at: fresh.deletingLastPathComponent()) }
        pasteboard.setItems([
            [(type: .fileURL, data: Data(staged.absoluteString.utf8))],
            [(type: .fileURL, data: Data(fresh.absoluteString.utf8))],
        ])
        await MainActor.run { agent.checkClipboardChange() }

        let offer = try await awaitOffer(on: hostChannel)
        #expect(offer.repInfo.map(\.filename) == ["fresh.txt"])
    }

    // MARK: - Folders (Phase 2)

    @Test("outbound copied folder: archived, offered as a directory rep, streamed as a valid archive")
    func outboundCopiedFolderOfferAndStream() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        // A copied folder leaves one file URL on the pasteboard (Finder ⌘C).
        let folder = try writeTempFolder(
            name: "Project",
            files: [("README.md", Data("readme".utf8)), ("sub/n.txt", Data("nested".utf8))])
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        pasteboard.setItem([(type: .fileURL, data: Data(folder.absoluteString.utf8))])
        await MainActor.run { agent.checkClipboardChange() }

        // The archive runs off-main; the offer arrives once it lands.
        let offer = try await awaitOffer(on: hostChannel)
        #expect(offer.repInfo.count == 1)
        let info = try #require(offer.repInfo.first)
        #expect(info.isDirectory)
        #expect(info.uti == UTType.folder.identifier)
        #expect(info.filename == "Project")
        #expect(!info.isInline)
        #expect(info.byteCount > 0)

        // Pull the rep: the streamed bytes are an `.aar` that extracts to the tree.
        let transferID: UInt64 = (offer.generation << 16) | 0
        try hostChannel.send(
            makeRequestFrame(generation: offer.generation, transferID: transferID, uti: info.uti))
        let transfer = try await collectOutboundTransfer(
            transferID: transferID, from: hostChannel, timeout: .seconds(10))
        #expect(!transfer.begin.isInline)
        #expect(transfer.begin.filename == "Project")

        let aar = try writeTempFile(name: "got.aar", data: transfer.bytes)
        defer { try? FileManager.default.removeItem(at: aar.deletingLastPathComponent()) }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        try ClipboardDirectoryArchive.extract(archiveAt: aar, to: dest)
        #expect(
            try String(contentsOf: dest.appendingPathComponent("README.md"), encoding: .utf8)
                == "readme")
        #expect(
            try String(contentsOf: dest.appendingPathComponent("sub/n.txt"), encoding: .utf8)
                == "nested")
    }

    @Test("inbound directory offer: promises only .fileURL and extracts into a real folder")
    func inboundDirectoryExtractsToFolder() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        // Build the archive the host would stream for the folder.
        let src = try writeTempFolder(
            name: "Shared",
            files: [("hello.txt", Data("hi".utf8)), ("d/inner.txt", Data("deep".utf8))])
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
        let aarDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: aarDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: aarDir) }
        let aar = aarDir.appendingPathComponent("Shared.aar")
        try ClipboardDirectoryArchive.archive(directoryAt: src, to: aar)
        let aarBytes = try Data(contentsOf: aar)

        // The host offers one directory rep.
        try hostChannel.send(
            makeOfferFrame(
                generation: 7,
                reps: [
                    RepInfo(
                        uti: UTType.folder.identifier, byteCount: UInt64(aarBytes.count),
                        filename: "Shared", isInline: false, isDirectory: true)
                ]))

        // The guest promises exactly one item, offering only `.fileURL`.
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting.contains(.fileURL) }
        #expect(pasteboard.promisedItemCountForTesting == 1)
        #expect(pasteboard.promisedTypesForTesting == [.fileURL])

        // The OS pulls `.fileURL`; the host streams the `.aar`; the guest extracts.
        let pull = lazyPull(pasteboard, forType: .fileURL)
        try await driveInboundStream(
            generation: 7, uti: UTType.folder.identifier, filename: "Shared", payload: aarBytes,
            isInline: false, on: hostChannel)
        let folderURL = try #require(
            (await pull.value).flatMap { String(data: $0, encoding: .utf8) }
                .flatMap(URL.init(string:)))

        var isDir: ObjCBool = false
        #expect(
            FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir)
                && isDir.boolValue)
        #expect(folderURL.lastPathComponent == "Shared")
        #expect(
            try String(contentsOf: folderURL.appendingPathComponent("hello.txt"), encoding: .utf8)
                == "hi")
        #expect(
            try String(contentsOf: folderURL.appendingPathComponent("d/inner.txt"), encoding: .utf8)
                == "deep")
    }

    @Test("an empty/filtered pasteboard sends no offer")
    func filteredTypesProduceNoOffer() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        pasteboard.setItem([
            (type: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"), data: Data([1]))
        ])
        await MainActor.run { agent.checkClipboardChange() }

        try await expectNoOffer(from: hostChannel)
    }

    @Test(
        "outbound suppressed: a transient or auto-generated snapshot is not offered even with content",
        arguments: ["org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"])
    func outboundSuppressedSnapshot(marker: String) async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // A real password/expansion item carries the marker alongside content;
        // the whole snapshot must be suppressed, not just the marker rep.
        pasteboard.setItem([
            (type: NSPasteboard.PasteboardType(marker), data: Data([1])),
            (type: .string, data: Data("noise".utf8)),
        ])
        await MainActor.run { agent.checkClipboardChange() }

        try await expectNoOffer(from: hostChannel)
    }

    @Test("outbound concealed: a password snapshot is offered with isConcealed set")
    func outboundConcealedOffer() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        pasteboard.setItem([
            (type: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"), data: Data([1])),
            (type: .string, data: Data("hunter2".utf8)),
        ])
        await MainActor.run { agent.checkClipboardChange() }

        let frame = try await nextFrame(from: hostChannel)
        guard case .clipboardOffer(let offer) = frame.payload else {
            throw TestFailure("Expected ClipboardOffer, got \(String(describing: frame.payload))")
        }
        #expect(offer.isConcealed)
        // The content still crosses — only the marker rep is dropped, so the
        // password can still be pasted on the host.
        #expect(offer.repInfo.map(\.uti) == [NSPasteboard.PasteboardType.string.rawValue])
    }

    @Test("snapshot offers UTIs in pasteboard order")
    func snapshotOffersUTIsInOrder() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        pasteboard.setItem([
            (type: NSPasteboard.PasteboardType("public.rtf"), data: Data("{rtf}".utf8)),
            (type: .string, data: Data("plain".utf8)),
        ])
        await MainActor.run { agent.checkClipboardChange() }

        let frame = try await nextFrame(from: hostChannel)
        guard case .clipboardOffer(let offer) = frame.payload else {
            throw TestFailure("Expected ClipboardOffer, got \(String(describing: frame.payload))")
        }
        #expect(
            offer.repInfo.map(\.uti) == ["public.rtf", NSPasteboard.PasteboardType.string.rawValue])
        #expect(offer.repInfo.allSatisfy { $0.isInline })
    }

    @Test("outbound: a request the agent can't answer is rejected with an Abort (symmetric to the host)")
    func outboundRejectsDroppedRequestsWithAbort() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        pasteboard.setString("guest payload", forType: .string)
        await MainActor.run { agent.checkClipboardChange() }

        let offerFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            throw TestFailure("Expected ClipboardOffer, got \(String(describing: offerFrame.payload))")
        }
        let info = try #require(offer.repInfo.first)
        let gen = offer.generation

        // Each dropped-request reason must produce a ClipboardStreamAbort so the
        // host's parked pull wakes immediately off-main rather than parking to its
        // 120 s backstop. The control frames are processed in order on the agent's
        // main queue, so each abort arrives before the next request is sent. [#357]

        // 1. Stale generation.
        let staleXID = ((gen &+ 1_000) << 16) | 0
        try hostChannel.send(
            makeRequestFrame(generation: gen &+ 1_000, transferID: staleXID, uti: info.uti))
        let staleAbort = try await nextFrame(from: hostChannel)
        guard case .clipboardStreamAbort(let a1) = staleAbort.payload else {
            throw TestFailure("Expected Abort for stale request, got \(String(describing: staleAbort.payload))")
        }
        #expect(a1.transferID == staleXID)
        #expect(a1.code == "request.stale")

        // 2. Out-of-range rep index (low 16 bits select a rep the offer lacks).
        let rangeXID = (gen << 16) | 5
        try hostChannel.send(makeRequestFrame(generation: gen, transferID: rangeXID, uti: info.uti))
        let rangeAbort = try await nextFrame(from: hostChannel)
        guard case .clipboardStreamAbort(let a2) = rangeAbort.payload else {
            throw TestFailure("Expected Abort for out-of-range request, got \(String(describing: rangeAbort.payload))")
        }
        #expect(a2.transferID == rangeXID)
        #expect(a2.code == "request.range")

        // 3. UTI mismatch.
        let utiXID = (gen << 16) | 0
        try hostChannel.send(
            makeRequestFrame(generation: gen, transferID: utiXID, uti: "public.bogus"))
        let utiAbort = try await nextFrame(from: hostChannel)
        guard case .clipboardStreamAbort(let a3) = utiAbort.payload else {
            throw TestFailure("Expected Abort for uti-mismatch request, got \(String(describing: utiAbort.payload))")
        }
        #expect(a3.transferID == utiXID)
        #expect(a3.code == "request.uti")
    }

    // MARK: - Echo suppression

    @Test("a registered host promise is not re-offered on the next poll (echo suppression)")
    func echoSuppression() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // Host offers text → agent registers a lazy promise (no pull, no request).
        // The post-write changeCount is captured so the poll can't self-trigger.
        try hostChannel.send(makeTextOfferFrame(generation: 1, text: "from host"))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting.contains(.string) }
        try await expectNoRequest(from: hostChannel)

        // A poll right after the promise is registered must not re-offer it.
        await MainActor.run { agent.checkClipboardChange() }
        try await expectNoOffer(from: hostChannel)
    }

    @Test("a file materialized into the staging root is not offered back (staging-path guard)")
    func stagedFileNotReOffered() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // Host offers a non-image file rep; a `.fileURL` paste materializes it
        // under the agent's staging root and resolves to that local file URL.
        let contents = Data("staged file body".utf8)
        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        try hostChannel.send(
            makeOfferFrame(
                generation: 3,
                reps: [
                    RepInfo(
                        uti: txtUTI, byteCount: UInt64(contents.count), filename: "notes.txt",
                        isInline: false)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting.contains(.fileURL) }

        let pull = lazyPull(pasteboard, forType: .fileURL)
        try await driveInboundStream(
            generation: 3, uti: txtUTI, filename: "notes.txt", payload: contents,
            isInline: false, on: hostChannel)
        let urlData = await pull.value
        let staged = try #require(
            urlData.flatMap { String(data: $0, encoding: .utf8) }
                .flatMap(URL.init(string:)))
        #expect(FileManager.default.fileExists(atPath: staged.path))

        // A poll now sees a .fileURL pointing inside the staging root; the
        // staging-path guard must skip it so it isn't offered back to the host.
        await MainActor.run { agent.checkClipboardChange() }
        try await expectNoOffer(from: hostChannel)
    }

    // MARK: - Inbound (agent is the receiver, lazy promise model)

    @Test("inbound text offer registers a promise and pulls nothing until the OS asks")
    func inboundTextOfferRegistersPromise() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // Host announces one inline text rep. The agent registers a lazy promise
        // for the text UTI and pulls NOTHING — no ClipboardRequest is sent.
        try hostChannel.send(makeTextOfferFrame(generation: 42, text: "clipboard payload"))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.string] }
        try await expectNoRequest(from: hostChannel)

        // The promise write is scoped `.currentHostOnly` so the guest's
        // continuity-pasteboard advertiser can't fetch the promised flavors at
        // offer time (#542) — an unscoped write would let the OS pull the full
        // payload with zero user interaction on the sync path.
        #expect(pasteboard.lastPrepareOptionsForTesting == .currentHostOnly)

        // The promise generation is recorded; a poll afterward does not re-offer.
        let promiseGen = DispatchQueue.main.sync { agent.inboundPromiseGenerationForTesting }
        #expect(promiseGen == 42)
        await MainActor.run { agent.checkClipboardChange() }
        try await expectNoOffer(from: hostChannel)
    }

    @Test("inbound text: an OS paste pulls exactly one request and returns the streamed bytes")
    func inboundTextLazyPull() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        try hostChannel.send(makeTextOfferFrame(generation: 42, text: "clipboard payload"))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting.contains(.string) }

        // OS asks for the text type → exactly one ClipboardRequest → host streams
        // → the provider returns the exact bytes. The pull blocks, so run it off
        // the main actor while the host responds concurrently below.
        let payload = Data("clipboard payload".utf8)
        let pull = lazyPull(pasteboard, forType: .string)
        try await driveInboundStream(
            generation: 42, uti: ClipboardContent.utf8TextUTI, filename: "", payload: payload,
            isInline: true, on: hostChannel
        ) { req in
            #expect(req.generation == 42)
            #expect(req.uti == ClipboardContent.utf8TextUTI)
        }
        let provided = await pull.value
        #expect(provided == payload)
    }

    @Test("inbound multi-chunk text (200 KiB) reassembles on a lazy pull")
    func inboundMultiChunkText() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // 200 KiB of deterministic ASCII so it round-trips as a string.
        let big = String(repeating: "abcdefghij", count: 20 * 1024)  // 200_000 chars
        let payload = Data(big.utf8)

        try hostChannel.send(makeTextOfferFrame(generation: 7, text: big))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting.contains(.string) }

        let pull = lazyPull(pasteboard, forType: .string)
        try await driveInboundStream(
            generation: 7, uti: ClipboardContent.utf8TextUTI, filename: "", payload: payload,
            isInline: true, chunkSize: 64 * 1024, on: hostChannel)
        let provided = await pull.value
        #expect(provided == payload)
    }

    @Test("inbound file: a `.fileURL` paste stages the bytes and returns a file URL")
    func inboundFileStagesAndReturnsFileURL() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        let contents = Data("file contents on disk".utf8)
        // A non-image file rep promises only `.fileURL`, never the text UTI.
        try hostChannel.send(
            makeOfferFrame(
                generation: 8,
                reps: [
                    RepInfo(
                        uti: txtUTI, byteCount: UInt64(contents.count), filename: "notes.txt",
                        isInline: false)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.fileURL] }
        #expect(!pasteboard.promisedTypesForTesting.contains(NSPasteboard.PasteboardType(txtUTI)))

        let pull = lazyPull(pasteboard, forType: .fileURL)
        try await driveInboundStream(
            generation: 8, uti: txtUTI, filename: "notes.txt", payload: contents,
            isInline: false, on: hostChannel)
        let urlData = await pull.value
        let staged = try #require(
            urlData.flatMap { String(data: $0, encoding: .utf8) }
                .flatMap(URL.init(string:)))
        #expect(staged.lastPathComponent == "notes.txt")
        #expect(try Data(contentsOf: staged) == contents)
    }

    // MARK: - File Provider relay (async, off-main pull)

    @Test("File Provider relay: fetchStagedFile pulls a file rep off-main and stages it")
    func fileProviderRelayStagesFile() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        let contents = Data("relayed file bytes".utf8)
        try hostChannel.send(
            makeOfferFrame(
                generation: 11,
                reps: [
                    RepInfo(
                        uti: txtUTI, byteCount: UInt64(contents.count), filename: "relay.txt",
                        isInline: false)
                ]))
        // Same registration signal the pasteboard path waits on.
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.fileURL] }

        // The relay entry point blocks on the pull and snapshots state via
        // `DispatchQueue.main.sync`, so it MUST run off the main actor; the host
        // streams the bytes concurrently.
        let pull = Task.detached { agent.fetchStagedFile(generation: 11, repIndex: 0) }
        try await driveInboundStream(
            generation: 11, uti: txtUTI, filename: "relay.txt", payload: contents,
            isInline: false, on: hostChannel)

        let stagedPath = try await pull.value.get()
        let stagedURL = URL(fileURLWithPath: stagedPath)
        #expect(stagedURL.lastPathComponent == "relay.txt")
        #expect(try Data(contentsOf: stagedURL) == contents)
    }

    @Test("File Provider relay: a stale generation resolves to noCurrentOffer with no request")
    func fileProviderRelayStaleGeneration() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        try hostChannel.send(
            makeOfferFrame(
                generation: 11,
                reps: [
                    RepInfo(uti: txtUTI, byteCount: 4, filename: "relay.txt", isInline: false)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.fileURL] }

        // A generation that isn't the current offer is rejected before any pull,
        // so no ClipboardRequest goes out.
        let outcome = await Task.detached {
            agent.fetchStagedFile(generation: 999, repIndex: 0)
        }.value
        guard case .failure(.noCurrentOffer) = outcome else {
            Issue.record("expected .noCurrentOffer, got \(outcome)")
            return
        }
        try await expectNoRequest(from: hostChannel)
    }

    @Test("File Provider relay: a host abort mid-pull resolves to .pullFailed")
    func fileProviderRelayPullFailed() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        try hostChannel.send(
            makeOfferFrame(
                generation: 11,
                reps: [
                    RepInfo(uti: txtUTI, byteCount: 16, filename: "relay.txt", isInline: false)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.fileURL] }

        // The host opens the transfer (Begin) then aborts instead of streaming —
        // the off-main pull wakes with .aborted, so fetchStagedFile reports
        // .pullFailed (which the relay maps to serverUnreachable).
        let pull = Task.detached { agent.fetchStagedFile(generation: 11, repIndex: 0) }
        let req = try await awaitRequest(on: hostChannel)
        try hostChannel.send(
            makeBeginFrame(
                generation: 11, transferID: req.transferID, uti: txtUTI,
                totalBytes: 16, filename: "relay.txt", isInline: false))
        try hostChannel.send(
            makeAbortFrame(transferID: req.transferID, code: "host.abort", message: "no"))
        let outcome = await pull.value
        guard case .failure(.pullFailed) = outcome else {
            Issue.record("expected .pullFailed, got \(outcome)")
            return
        }
    }

    @Test("File Provider relay: a parked pull is woken by teardown, not the backstop timeout")
    func fileProviderRelayTeardownWakeup() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        try hostChannel.send(
            makeOfferFrame(
                generation: 11,
                reps: [
                    RepInfo(uti: txtUTI, byteCount: 16, filename: "relay.txt", isInline: false)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.fileURL] }

        // Park the pull (request sent, awaiting Begin), then drop the connection.
        // serve()'s EOF handler fails the coordinator off-main, so the pull wakes
        // promptly — well under the lazy-pull backstop — rather than hanging.
        let pull = Task.detached { agent.fetchStagedFile(generation: 11, repIndex: 0) }
        _ = try await awaitRequest(on: hostChannel)
        let start = ContinuousClock.now
        hostChannel.close()
        let outcome = await pull.value
        #expect(ContinuousClock.now - start < .seconds(5))
        guard case .failure(.pullFailed) = outcome else {
            Issue.record("expected .pullFailed after teardown, got \(outcome)")
            return
        }
    }

    // MARK: - handleOffer File Provider routing

    /// Builds an agent with a `FakeFileProviderPublisher` wired in.
    ///
    /// The fake is returned alongside so the test can keep its strong reference
    /// (the agent holds it weakly) and assert against it.
    private func makeAgentWithPublisher(
        pasteboard: FakePasteboard, agentFd: Int32, publisherURL: URL?
    ) -> (agent: VsockGuestClipboardAgent, publisher: FakeFileProviderPublisher) {
        let publisher = FakeFileProviderPublisher(urlToReturn: publisherURL)
        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        agent.fileProvider = publisher
        return (agent, publisher)
    }

    @Test("a single file rep is published through the File Provider; its domain URL goes on the pasteboard")
    func fileProviderSingleFileRouting() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let domainURL = URL(fileURLWithPath: "/Users/Shared/KernovaClipboard/report.pdf")
        let (agent, publisher) = makeAgentWithPublisher(
            pasteboard: pasteboard, agentFd: agentFd, publisherURL: domainURL)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        try hostChannel.send(
            makeOfferFrame(
                generation: 21,
                reps: [
                    RepInfo(uti: "com.adobe.pdf", byteCount: 9_000, filename: "report.pdf", isInline: false)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.fileURL] }

        // The single file rep was published through the File Provider.
        #expect(
            publisher.published == [
                .init(generation: 21, repIndex: 0, filename: "report.pdf", byteCount: 9_000, uti: "com.adobe.pdf")
            ])
        // A `.fileURL` paste returns the domain URL immediately — no host stream
        // is needed (the bytes page in lazily via the extension's fetchContents).
        let provided = await lazyPull(pasteboard, forType: .fileURL).value
        #expect(provided == Data(domainURL.absoluteString.utf8))
        try await expectNoRequest(from: hostChannel)
    }

    @Test("a file rep alongside an inline rep: only the file is routed through the File Provider")
    func fileProviderRoutesOnlyTheFileAmongInline() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let domainURL = URL(fileURLWithPath: "/Users/Shared/KernovaClipboard/report.pdf")
        let (agent, publisher) = makeAgentWithPublisher(
            pasteboard: pasteboard, agentFd: agentFd, publisherURL: domainURL)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // An inline text rep (no filename) plus a non-inline file rep.
        try hostChannel.send(
            makeOfferFrame(
                generation: 22,
                reps: [
                    RepInfo(uti: ClipboardContent.utf8TextUTI, byteCount: 5, isInline: true),
                    RepInfo(uti: "com.adobe.pdf", byteCount: 9_000, filename: "report.pdf", isInline: false),
                ]))
        try await waitUntil {
            DispatchQueue.main.sync { agent.inboundPromiseGenerationForTesting } == 22
        }

        // Only the file rep (index 1) is published; the inline rep stays on the
        // synchronous provider path.
        #expect(publisher.published.map(\.repIndex) == [1])
        #expect(publisher.published.first?.filename == "report.pdf")
    }

    @Test("a multi-file offer is not routed through the File Provider (D1a is single-file)")
    func fileProviderMultiFileFallsBack() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let (agent, publisher) = makeAgentWithPublisher(
            pasteboard: pasteboard, agentFd: agentFd,
            publisherURL: URL(fileURLWithPath: "/unused"))
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        try hostChannel.send(
            makeOfferFrame(
                generation: 23,
                reps: [
                    RepInfo(uti: "com.adobe.pdf", byteCount: 10, filename: "a.pdf", isInline: false),
                    RepInfo(uti: "com.adobe.pdf", byteCount: 20, filename: "b.pdf", isInline: false),
                ]))
        try await waitUntil {
            DispatchQueue.main.sync { agent.inboundPromiseGenerationForTesting } == 23
        }

        // Two file reps → the single-file gate declines → nothing published.
        #expect(publisher.published.isEmpty)
    }

    @Test("a superseding offer clears the prior File Provider offer before publishing")
    func fileProviderSupersessionClears() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let domainURL = URL(fileURLWithPath: "/Users/Shared/KernovaClipboard/a.pdf")
        let (agent, publisher) = makeAgentWithPublisher(
            pasteboard: pasteboard, agentFd: agentFd, publisherURL: domainURL)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        try hostChannel.send(
            makeOfferFrame(
                generation: 1,
                reps: [RepInfo(uti: "com.adobe.pdf", byteCount: 10, filename: "a.pdf", isInline: false)]
            ))
        try await waitUntil {
            DispatchQueue.main.sync { agent.inboundPromiseGenerationForTesting } == 1
        }
        let clearsAfterFirst = publisher.clearCount

        // A superseding offer must retract the prior FP offer (clearOffer fires at
        // the top of handleOffer) before publishing the new one.
        try hostChannel.send(
            makeOfferFrame(
                generation: 2,
                reps: [RepInfo(uti: "com.adobe.pdf", byteCount: 20, filename: "b.pdf", isInline: false)]
            ))
        try await waitUntil {
            DispatchQueue.main.sync { agent.inboundPromiseGenerationForTesting } == 2
        }
        #expect(publisher.clearCount > clearsAfterFirst)
        #expect(publisher.published.last?.filename == "b.pdf")
    }

    // MARK: - fileProviderAvailabilityChanged re-publish (#429)

    @Test("availability flip to .ready re-publishes a live single-file offer that missed the File Provider path")
    func availabilityFlipRepublishesLiveSingleFileOffer() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        // Domain not `.ready` yet — publisher declines, so the offer lands on
        // the synchronous provider path.
        let (agent, publisher) = makeAgentWithPublisher(
            pasteboard: pasteboard, agentFd: agentFd, publisherURL: nil)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let contents = Data("report bytes on disk".utf8)
        try hostChannel.send(
            makeOfferFrame(
                generation: 30,
                reps: [
                    RepInfo(
                        uti: "com.adobe.pdf", byteCount: UInt64(contents.count),
                        filename: "report.pdf", isInline: false)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.fileURL] }
        #expect(publisher.published.map(\.repIndex) == [0])

        // A `.fileURL` paste on the sync path pulls the bytes over the host
        // stream (no File Provider domain URL was available at offer time).
        let firstPull = lazyPull(pasteboard, forType: .fileURL)
        try await driveInboundStream(
            generation: 30, uti: "com.adobe.pdf", filename: "report.pdf", payload: contents,
            isInline: false, on: hostChannel)
        _ = await firstPull.value

        // The domain becomes user-enabled; the publisher now returns a URL.
        let domainURL = URL(fileURLWithPath: "/Users/Shared/KernovaClipboard/report.pdf")
        publisher.urlToReturn = domainURL
        DispatchQueue.main.sync { agent.fileProviderAvailabilityChanged(.ready) }
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.fileURL] }

        // Re-published: a `.fileURL` paste now returns the domain URL directly,
        // with no host stream.
        let provided = await lazyPull(pasteboard, forType: .fileURL).value
        #expect(provided == Data(domainURL.absoluteString.utf8))
        try await expectNoRequest(from: hostChannel)
    }

    @Test(
        "provideData refuses a stale sync-path pull for a rep the availability flip re-routed to the File Provider (#510)"
    )
    func provideDataRefusesStalePullAfterAvailabilityFlipReroute() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        // Domain not `.ready` yet — the offer lands on the synchronous provider path.
        let (agent, publisher) = makeAgentWithPublisher(
            pasteboard: pasteboard, agentFd: agentFd, publisherURL: nil)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        try hostChannel.send(
            makeOfferFrame(
                generation: 40,
                reps: [
                    RepInfo(
                        uti: "com.adobe.pdf", byteCount: 9_000, filename: "report.pdf",
                        isInline: false)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.fileURL] }

        // An external process retains a reference to the pre-switch sync-path
        // provider before the domain becomes ready (e.g. a receiver that
        // enumerated types on a slow drag but hasn't fetched this rep yet).
        let staleProvider = pasteboard.captureProviderForTesting()

        // The domain becomes user-enabled; the live offer is re-published
        // through the File Provider (#429), keeping the same generation.
        let domainURL = URL(fileURLWithPath: "/Users/Shared/KernovaClipboard/report.pdf")
        publisher.urlToReturn = domainURL
        DispatchQueue.main.sync { agent.fileProviderAvailabilityChanged(.ready) }
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.fileURL] }

        // The stale, pre-switch provider is invoked for the same rep it always
        // promised. It must be refused -- returning nil and minting no
        // transfer id / starting no host pull -- rather than colliding with a
        // concurrent File Provider fetch for the same (generation, repIndex).
        let item = NSPasteboardItem()
        // RATIONALE: see `newerOfferSupersedesOldPromise` above — the provider
        // must run off-main and is a non-Sendable AppKit type; the
        // continuation joins the closure before `item` is read below.
        nonisolated(unsafe) let provider = staleProvider
        nonisolated(unsafe) let capturedItem = item
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                provider?.pasteboard(nil, item: capturedItem, provideDataForType: .fileURL)
                cont.resume()
            }
        }
        #expect(item.data(forType: .fileURL) == nil)
        try await expectNoRequest(from: hostChannel)
    }

    @Test(
        "provideData still serves a rep from cache to a stale sync-path pull after the availability flip re-routed it"
    )
    func provideDataServesCachedRepToStalePullAfterAvailabilityFlipReroute() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        // Domain not `.ready` yet — the offer lands on the synchronous provider path.
        let (agent, publisher) = makeAgentWithPublisher(
            pasteboard: pasteboard, agentFd: agentFd, publisherURL: nil)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let contents = Data("report bytes on disk".utf8)
        try hostChannel.send(
            makeOfferFrame(
                generation: 42,
                reps: [
                    RepInfo(
                        uti: "com.adobe.pdf", byteCount: UInt64(contents.count),
                        filename: "report.pdf", isInline: false)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.fileURL] }

        // Capture the pre-switch provider, then pull through it so the rep is
        // materialized (cached) on the sync path before the domain flips.
        let staleProvider = pasteboard.captureProviderForTesting()
        let firstPull = lazyPull(pasteboard, forType: .fileURL)
        try await driveInboundStream(
            generation: 42, uti: "com.adobe.pdf", filename: "report.pdf", payload: contents,
            isInline: false, on: hostChannel)
        let firstStaged = try #require(
            (await firstPull.value).flatMap { String(data: $0, encoding: .utf8) }
                .flatMap(URL.init(string:)))

        // The domain becomes user-enabled; the live offer is re-published
        // through the File Provider (#429), keeping the same generation.
        let domainURL = URL(fileURLWithPath: "/Users/Shared/KernovaClipboard/report.pdf")
        publisher.urlToReturn = domainURL
        DispatchQueue.main.sync { agent.fileProviderAvailabilityChanged(.ready) }
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.fileURL] }

        // The stale, pre-switch provider is asked for the SAME rep again. It
        // was already materialized before the flip, so serving it from cache
        // mints no new transfer id and can't collide with a concurrent File
        // Provider fetch — the (#510) guard must not refuse it.
        let item = NSPasteboardItem()
        nonisolated(unsafe) let provider = staleProvider
        nonisolated(unsafe) let capturedItem = item
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                provider?.pasteboard(nil, item: capturedItem, provideDataForType: .fileURL)
                cont.resume()
            }
        }
        let restaged = try #require(
            item.data(forType: .fileURL).flatMap { String(data: $0, encoding: .utf8) }
                .flatMap(URL.init(string:)))
        #expect(restaged == firstStaged)
        try await expectNoRequest(from: hostChannel)
    }

    @Test("availability flip is a no-op when the guest clipboard changed since the offer was written")
    func availabilityFlipNoOpWhenClipboardReplaced() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let (agent, publisher) = makeAgentWithPublisher(
            pasteboard: pasteboard, agentFd: agentFd, publisherURL: nil)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        try hostChannel.send(
            makeOfferFrame(
                generation: 31,
                reps: [
                    RepInfo(uti: "com.adobe.pdf", byteCount: 9_000, filename: "report.pdf", isInline: false)
                ]))
        try await waitUntil {
            DispatchQueue.main.sync { agent.inboundPromiseGenerationForTesting } == 31
        }
        let publishedBeforeFlip = publisher.published.count

        // The user copies something else inside the guest before the domain
        // becomes ready.
        pasteboard.setString("something else", forType: .string)

        publisher.urlToReturn = URL(fileURLWithPath: "/Users/Shared/KernovaClipboard/report.pdf")
        DispatchQueue.main.sync { agent.fileProviderAvailabilityChanged(.ready) }

        // No re-publish — the promise we wrote is no longer on the pasteboard.
        #expect(publisher.published.count == publishedBeforeFlip)
    }

    @Test("availability flip is a no-op when the live offer is already File-Provider-routed")
    func availabilityFlipNoOpWhenAlreadyFileProviderRouted() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let domainURL = URL(fileURLWithPath: "/Users/Shared/KernovaClipboard/report.pdf")
        let (agent, publisher) = makeAgentWithPublisher(
            pasteboard: pasteboard, agentFd: agentFd, publisherURL: domainURL)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        try hostChannel.send(
            makeOfferFrame(
                generation: 32,
                reps: [
                    RepInfo(uti: "com.adobe.pdf", byteCount: 9_000, filename: "report.pdf", isInline: false)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.fileURL] }
        let publishedBeforeFlip = publisher.published.count

        DispatchQueue.main.sync { agent.fileProviderAvailabilityChanged(.ready) }

        // Already FP-routed at offer time — no re-publish.
        #expect(publisher.published.count == publishedBeforeFlip)
    }

    @Test("availability flip does not route a multi-file offer through the File Provider")
    func availabilityFlipNoOpForMultiFileOffer() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let (agent, publisher) = makeAgentWithPublisher(
            pasteboard: pasteboard, agentFd: agentFd, publisherURL: nil)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        try hostChannel.send(
            makeOfferFrame(
                generation: 33,
                reps: [
                    RepInfo(uti: "com.adobe.pdf", byteCount: 10, filename: "a.pdf", isInline: false),
                    RepInfo(uti: "com.adobe.pdf", byteCount: 20, filename: "b.pdf", isInline: false),
                ]))
        try await waitUntil {
            DispatchQueue.main.sync { agent.inboundPromiseGenerationForTesting } == 33
        }

        publisher.urlToReturn = URL(fileURLWithPath: "/unused")
        DispatchQueue.main.sync { agent.fileProviderAvailabilityChanged(.ready) }

        // The single-file gate still declines — nothing published.
        #expect(publisher.published.isEmpty)
    }

    @Test(
        "availability flip other than .ready is a no-op",
        arguments: [
            FileProviderAvailability.inactive, .needsEnabling, .unavailable,
        ])
    func availabilityFlipNonReadyIsNoOp(_ availability: FileProviderAvailability) async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let (agent, publisher) = makeAgentWithPublisher(
            pasteboard: pasteboard, agentFd: agentFd, publisherURL: nil)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        try hostChannel.send(
            makeOfferFrame(
                generation: 34,
                reps: [
                    RepInfo(uti: "com.adobe.pdf", byteCount: 9_000, filename: "report.pdf", isInline: false)
                ]))
        try await waitUntil {
            DispatchQueue.main.sync { agent.inboundPromiseGenerationForTesting } == 34
        }

        publisher.urlToReturn = URL(fileURLWithPath: "/Users/Shared/KernovaClipboard/report.pdf")
        DispatchQueue.main.sync { agent.fileProviderAvailabilityChanged(availability) }

        #expect(publisher.published.count == 1)
    }

    @Test("availability flip is a no-op when there is no live inbound promise")
    func availabilityFlipNoOpWhenNoLivePromise() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, _) = try makeRawSocketPair()

        let (agent, publisher) = makeAgentWithPublisher(
            pasteboard: pasteboard, agentFd: agentFd,
            publisherURL: URL(fileURLWithPath: "/unused"))
        defer { agent.stop() }

        DispatchQueue.main.sync { agent.fileProviderAvailabilityChanged(.ready) }

        #expect(publisher.published.isEmpty)
    }

    @Test("inbound image file: promises both the image UTI and `.fileURL`")
    func inboundImageFilePromisesBoth() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let png = try makeTestPNG()
        let pngType = NSPasteboard.PasteboardType(UTType.png.identifier)
        // An image file rep is inline (per shouldInline) yet bears a filename, so
        // it promises BOTH the image UTI and `.fileURL`.
        try hostChannel.send(
            makeOfferFrame(
                generation: 5,
                reps: [
                    RepInfo(
                        uti: UTType.png.identifier, byteCount: UInt64(png.count), filename: "shot.png",
                        isInline: true)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting.count == 2 }
        #expect(Set(pasteboard.promisedTypesForTesting) == [pngType, .fileURL])

        // Paste the image UTI: the inline bytes are returned verbatim.
        let imgPull = lazyPull(pasteboard, forType: pngType)
        try await driveInboundStream(
            generation: 5, uti: UTType.png.identifier, filename: "shot.png", payload: png,
            isInline: true, on: hostChannel)
        let imageData = await imgPull.value
        #expect(imageData == png)

        // Then paste `.fileURL` for the SAME rep: it is a cache hit — NO second
        // request is sent — and resolves to a staged file with the same bytes.
        let urlPull = lazyPull(pasteboard, forType: .fileURL)
        let urlData = await urlPull.value
        try await expectNoRequest(from: hostChannel)
        let staged = try #require(
            urlData.flatMap { String(data: $0, encoding: .utf8) }
                .flatMap(URL.init(string:)))
        #expect(staged.lastPathComponent == "shot.png")
        #expect(try Data(contentsOf: staged) == png)
    }

    @Test("a repeated .fileURL pull of an inline image file reuses the staged file (no duplicate)")
    func inboundImageFileRepeatedFileURLPullReusesStagedFile() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        let png = try makeTestPNG()
        try hostChannel.send(
            makeOfferFrame(
                generation: 11,
                reps: [
                    RepInfo(
                        uti: UTType.png.identifier, byteCount: UInt64(png.count), filename: "shot.png",
                        isInline: true)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting.count == 2 }

        // First `.fileURL` pull stages the inline bytes to a temp file.
        let pull1 = lazyPull(pasteboard, forType: .fileURL)
        try await driveInboundStream(
            generation: 11, uti: UTType.png.identifier, filename: "shot.png", payload: png,
            isInline: true, on: hostChannel)
        let url1 = try #require(
            (await pull1.value).flatMap { String(data: $0, encoding: .utf8) }
                .flatMap(URL.init(string:)))

        // A second `.fileURL` pull is a cache hit — NO new request, and the SAME
        // staged URL (not a `shot (2).png` duplicate from the staging de-dup).
        let pull2 = lazyPull(pasteboard, forType: .fileURL)
        let url2 = try #require(
            (await pull2.value).flatMap { String(data: $0, encoding: .utf8) }
                .flatMap(URL.init(string:)))
        try await expectNoRequest(from: hostChannel)
        #expect(url1 == url2)
        #expect(url1.lastPathComponent == "shot.png")
    }

    @Test("inbound multiple files: each rep is its own promised item; pulls don't cross-talk")
    func inboundMultipleFilesPromiseAndPull() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        let bodyA = Data("first file body".utf8)
        let bodyB = Data("second file body".utf8)
        // Two non-image file reps in one offer.
        try hostChannel.send(
            makeOfferFrame(
                generation: 9,
                reps: [
                    RepInfo(
                        uti: txtUTI, byteCount: UInt64(bodyA.count), filename: "a.txt",
                        isInline: false),
                    RepInfo(
                        uti: txtUTI, byteCount: UInt64(bodyB.count), filename: "b.txt",
                        isInline: false),
                ]))
        // Two promised items, each promising exactly `.fileURL`.
        try await pasteboard.changed.wait { pasteboard.promisedItemCountForTesting == 2 }
        #expect(pasteboard.promisedTypesForTesting == [.fileURL, .fileURL])

        // Pull item 0's `.fileURL` → a request for rep 0 (transfer_id low bits 0).
        let pull0 = lazyPull(pasteboard, forType: .fileURL, itemIndex: 0)
        try await driveInboundStream(
            generation: 9, uti: txtUTI, filename: "a.txt", payload: bodyA, isInline: false,
            on: hostChannel
        ) { req in
            #expect(req.transferID & 0xFFFF == 0)
        }
        let staged0 = try #require(
            (await pull0.value).flatMap { String(data: $0, encoding: .utf8) }
                .flatMap(URL.init(string:)))
        #expect(staged0.lastPathComponent == "a.txt")
        #expect(try Data(contentsOf: staged0) == bodyA)

        // Pull item 1's `.fileURL` → a distinct request for rep 1 (low bits 1),
        // with no cache cross-talk: the second file's bytes, not the first's.
        let pull1 = lazyPull(pasteboard, forType: .fileURL, itemIndex: 1)
        try await driveInboundStream(
            generation: 9, uti: txtUTI, filename: "b.txt", payload: bodyB, isInline: false,
            on: hostChannel
        ) { req in
            #expect(req.transferID & 0xFFFF == 1)
        }
        let staged1 = try #require(
            (await pull1.value).flatMap { String(data: $0, encoding: .utf8) }
                .flatMap(URL.init(string:)))
        #expect(staged1.lastPathComponent == "b.txt")
        #expect(try Data(contentsOf: staged1) == bodyB)

        // Distinct staged files, each with its own (uncrossed) contents.
        #expect(staged0 != staged1)
    }

    @Test("a second pull for another promised type of the same rep is a cache hit")
    func secondPullSameRepIsCacheHit() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let png = try makeTestPNG()
        let pngType = NSPasteboard.PasteboardType(UTType.png.identifier)
        try hostChannel.send(
            makeOfferFrame(
                generation: 9,
                reps: [
                    RepInfo(
                        uti: UTType.png.identifier, byteCount: UInt64(png.count), filename: "img.png",
                        isInline: true)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting.count == 2 }

        // First pull (`.fileURL`) drives exactly one request + stream.
        let firstPull = lazyPull(pasteboard, forType: .fileURL)
        try await driveInboundStream(
            generation: 9, uti: UTType.png.identifier, filename: "img.png", payload: png,
            isInline: true, on: hostChannel)
        _ = await firstPull.value

        // Second pull (image UTI, same rep) must NOT send another request.
        let secondPull = lazyPull(pasteboard, forType: pngType)
        let imageData = await secondPull.value
        try await expectNoRequest(from: hostChannel)
        #expect(imageData == png)
        #expect(DispatchQueue.main.sync { agent.inboundPromiseGenerationForTesting } == 9)
    }

    @Test("a host abort makes the pulling provider return nil")
    func inboundPullAbortReturnsNil() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        try hostChannel.send(makeTextOfferFrame(generation: 13, text: "never delivered"))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting.contains(.string) }

        // OS pastes the text type; the host opens the transfer (Begin) then
        // aborts it mid-flight instead of streaming the bytes. The receiver
        // tears the registered transfer down and fires the awaiter, so the
        // provider's pull wakes with .aborted and returns nil.
        let payload = Data("never delivered".utf8)
        let pull = lazyPull(pasteboard, forType: .string)
        let req = try await awaitRequest(on: hostChannel)
        #expect(req.generation == 13)
        try hostChannel.send(
            makeBeginFrame(
                generation: 13, transferID: req.transferID, uti: ClipboardContent.utf8TextUTI,
                totalBytes: payload.count, filename: "", isInline: true))
        try hostChannel.send(
            makeAbortFrame(transferID: req.transferID, code: "host.abort", message: "no"))
        let provided = await pull.value
        #expect(provided == nil)
    }

    @Test("a host reject (Abort with no preceding Begin) wakes the pulling provider promptly")
    func inboundPullPreBeginAbortReturnsNil() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        try hostChannel.send(makeTextOfferFrame(generation: 14, text: "dropped"))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting.contains(.string) }

        // OS pastes the text type; the host drops the request WITHOUT ever sending
        // a Begin — exactly what `rejectRequest` does for a stale/out-of-range/UTI-
        // mismatch request. The receiver's handleAbort must wake the awaiter off-
        // main so the blocked provider returns nil immediately rather than parking
        // to the 120 s lazyPullTimeout (the supersession-mid-paste freeze). If the
        // wakeup were broken this test would hang, not just fail an assertion. [#357]
        let pull = lazyPull(pasteboard, forType: .string)
        let req = try await awaitRequest(on: hostChannel)
        #expect(req.generation == 14)
        try hostChannel.send(
            makeAbortFrame(transferID: req.transferID, code: "request.stale", message: "superseded"))
        let provided = await pull.value
        #expect(provided == nil)
    }

    @Test("a newer offer supersedes the old promise; provideData for the old generation returns nil")
    func newerOfferSupersedesOldPromise() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // First offer registers a promise at generation 20.
        try hostChannel.send(makeTextOfferFrame(generation: 20, text: "old"))
        try await waitUntil {
            DispatchQueue.main.sync { agent.inboundPromiseGenerationForTesting } == 20
        }

        // Capture the gen-20 provider, then a newer offer supersedes it.
        let oldProvider = pasteboard.captureProviderForTesting()
        try hostChannel.send(makeTextOfferFrame(generation: 21, text: "new"))
        try await waitUntil {
            DispatchQueue.main.sync { agent.inboundPromiseGenerationForTesting } == 21
        }

        // provideData for the retracted gen-20 provider returns nil (stale
        // generation) and sends NO request — the old promise was dropped.
        let item = NSPasteboardItem()
        // RATIONALE: NSPasteboardItem / the data provider are non-Sendable AppKit
        // types, and the provider must run off-main (it does DispatchQueue.main.sync
        // internally). The continuation joins the closure before `item` is read
        // below, so the hop is race-free.
        nonisolated(unsafe) let provider = oldProvider
        nonisolated(unsafe) let capturedItem = item
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                provider?.pasteboard(nil, item: capturedItem, provideDataForType: .string)
                cont.resume()
            }
        }
        #expect(item.data(forType: .string) == nil)
        try await expectNoRequest(from: hostChannel)
    }

    // MARK: - Receive-side sanitization

    @Test("a `.fileURL` pull never resolves to a sanitized-away (smuggled) rep")
    func inboundFileURLPullSkipsSmuggledRep() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        let png = try makeTestPNG()
        let pngType = NSPasteboard.PasteboardType(UTType.png.identifier)
        // A hostile/buggy offer: a raw `public.file-url` smuggle rep (filename-
        // bearing, so it would be the FIRST file rep) ahead of the legit PNG file
        // rep. `promisedItems` drops the smuggle (it carries no promisable item)
        // and promises `.fileURL` for the PNG; the `.fileURL` pull MUST resolve to
        // the PNG (index 1), not the smuggle (index 0) — each promised item
        // carries its own rep index, gated by the same `isPromisable` check.
        try hostChannel.send(
            makeOfferFrame(
                generation: 7,
                reps: [
                    RepInfo(
                        uti: "public.file-url", byteCount: 32, filename: "smuggled", isInline: true),
                    RepInfo(
                        uti: UTType.png.identifier, byteCount: UInt64(png.count),
                        filename: "shot.png", isInline: true),
                ]))
        // Exactly the PNG's image UTI + `.fileURL` are promised (the smuggle rep
        // adds nothing); `.fileURL`'s rawValue IS "public.file-url", which is the
        // legit file-url promise for the PNG — distinct from the smuggled content
        // rep that shares that UTI. The discriminating check is the request's UTI.
        try await pasteboard.changed.wait { Set(pasteboard.promisedTypesForTesting) == [pngType, .fileURL] }

        let pull = lazyPull(pasteboard, forType: .fileURL)
        try await driveInboundStream(
            generation: 7, uti: UTType.png.identifier, filename: "shot.png", payload: png,
            isInline: true, on: hostChannel
        ) { req in
            // The request must target the legit PNG rep, never the smuggled file-url
            // rep (whose UTI would be "public.file-url" if repIndex skipped the gate).
            #expect(req.uti == UTType.png.identifier)
        }
        let urlData = await pull.value
        let staged = try #require(
            urlData.flatMap { String(data: $0, encoding: .utf8) }.flatMap(URL.init(string:)))
        #expect(staged.lastPathComponent == "shot.png")
        #expect(try Data(contentsOf: staged) == png)
    }

    @Test("an inbound offer never promises a transient-marker or raw file-url rep, only legit content")
    func inboundOfferSanitizesPromisedTypes() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // An offer mixing a legit inline text rep with two identity-skip reps a
        // buggy/malicious host might smuggle: a transient marker and a raw
        // `public.file-url`. The agent must promise ONLY the text type.
        try hostChannel.send(
            makeOfferFrame(
                generation: 17,
                reps: [
                    RepInfo(
                        uti: "org.nspasteboard.TransientType", byteCount: 4, isInline: true),
                    RepInfo(uti: ClipboardContent.utf8TextUTI, byteCount: 8, isInline: true),
                    RepInfo(
                        uti: "public.file-url", byteCount: 32, filename: "smuggled",
                        isInline: true),
                ]))

        // Only the legit text rep is promised; neither skip rep contributes a
        // promised type (the raw file-url never yields a `.fileURL` promise).
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.string] }
        let promised = pasteboard.promisedTypesForTesting
        #expect(promised == [.string])
        #expect(!promised.contains(.fileURL))
        #expect(!promised.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")))
        #expect(!promised.contains(NSPasteboard.PasteboardType("public.file-url")))
        // Pulling is lazy — the offer issues no request.
        try await expectNoRequest(from: hostChannel)
    }

    // MARK: - Disk full

    @Test("disk full: a `.fileURL` pull for an over-budget file rep returns nil without a request")
    func diskFullPullReturnsNil() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        // Simulate a near-full disk: only 1 KiB free.
        let agent = makeAgent(
            pasteboard: pasteboard, agentFd: agentFd, freeSpaceProvider: { _ in 1024 })
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // A 50 MiB file rep registers a `.fileURL` promise (handleOffer pulls
        // nothing). The pull's free-space pre-flight fails, so the provider
        // returns nil and NO request is ever sent.
        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        try hostChannel.send(
            makeOfferFrame(
                generation: 12,
                reps: [
                    RepInfo(
                        uti: txtUTI, byteCount: 50 * 1024 * 1024, filename: "huge.bin",
                        isInline: false)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.fileURL] }

        let pull = lazyPull(pasteboard, forType: .fileURL)
        let provided = await pull.value
        #expect(provided == nil)
        try await expectNoRequest(from: hostChannel)
    }

    @Test("disk full: the guest surfaces the failure to the host as a clipboard.paste error frame")
    func diskFullSurfacesErrorFrame() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        // Only 1 KiB free, so a 50 MiB file rep fails the pre-flight disk guard.
        let agent = makeAgent(
            pasteboard: pasteboard, agentFd: agentFd, freeSpaceProvider: { _ in 1024 })
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        try hostChannel.send(
            makeOfferFrame(
                generation: 13,
                reps: [
                    RepInfo(
                        uti: txtUTI, byteCount: 50 * 1024 * 1024, filename: "huge.bin",
                        isInline: false)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.fileURL] }

        let pull = lazyPull(pasteboard, forType: .fileURL)
        #expect(await pull.value == nil)

        // The guest has no UI, so it tells the host — which surfaces it in the
        // clipboard window — via a `clipboard.*` Error frame (not a request).
        let frame = try await maybeNextFrame(from: hostChannel)
        guard case .error(let error)? = frame?.payload else {
            Issue.record("Expected an Error frame, got \(String(describing: frame?.payload))")
            return
        }
        #expect(error.code == "clipboard.paste.disk.full")
    }

    // MARK: - Deadline-safe size cap (#561)

    @Test(
        "deadline cap: a `.fileURL` pull for an over-cap file rep returns nil without a request")
    func tooLargePullReturnsNilWithoutRequest() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        // Ample disk (default free-space provider) — the size cap must refuse the
        // pull on its own, before the disk-capacity guard is even reached.
        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        let overCap = UInt64(ClipboardStreamTuning.maxDeadlineSafeFileBytes) + 1
        try hostChannel.send(
            makeOfferFrame(
                generation: 21,
                reps: [
                    RepInfo(uti: txtUTI, byteCount: overCap, filename: "huge.bin", isInline: false)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.fileURL] }

        let pull = lazyPull(pasteboard, forType: .fileURL)
        let provided = await pull.value
        #expect(provided == nil)
        try await expectNoRequest(from: hostChannel)
    }

    @Test(
        "deadline cap: an over-cap directory rep is refused too — a folder paste has no File Provider escape hatch yet (D1b), so it rides the same deadline-bound path as a plain file"
    )
    func tooLargeDirectoryPullReturnsNilWithoutRequest() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let overCap = UInt64(ClipboardStreamTuning.maxDeadlineSafeFileBytes) + 1
        try hostChannel.send(
            makeOfferFrame(
                generation: 26,
                reps: [
                    RepInfo(
                        uti: UTType.folder.identifier, byteCount: overCap, filename: "HugeFolder",
                        isInline: false, isDirectory: true)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.fileURL] }

        let pull = lazyPull(pasteboard, forType: .fileURL)
        let provided = await pull.value
        #expect(provided == nil)
        try await expectNoRequest(from: hostChannel)
    }

    @Test(
        "deadline cap: the guest surfaces the failure to the host as a clipboard.paste.too.large error frame"
    )
    func tooLargeSurfacesErrorFrame() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        let overCap = UInt64(ClipboardStreamTuning.maxDeadlineSafeFileBytes) + 1
        try hostChannel.send(
            makeOfferFrame(
                generation: 22,
                reps: [
                    RepInfo(uti: txtUTI, byteCount: overCap, filename: "huge.bin", isInline: false)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.fileURL] }

        let pull = lazyPull(pasteboard, forType: .fileURL)
        #expect(await pull.value == nil)

        let frame = try await maybeNextFrame(from: hostChannel)
        guard case .error(let error)? = frame?.payload else {
            Issue.record("Expected an Error frame, got \(String(describing: frame?.payload))")
            return
        }
        #expect(error.code == "clipboard.paste.too.large")
    }

    @Test("deadline cap: a file rep exactly at the cap is not refused — the pull still proceeds")
    func atCapBoundaryIsNotRefused() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        let atCap = UInt64(ClipboardStreamTuning.maxDeadlineSafeFileBytes)
        try hostChannel.send(
            makeOfferFrame(
                generation: 23,
                reps: [
                    RepInfo(uti: txtUTI, byteCount: atCap, filename: "atcap.bin", isInline: false)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.fileURL] }

        // The cap uses `>`, not `>=` — an exactly-at-cap rep must issue a real
        // request rather than being refused pre-flight. Abort it to resolve the
        // pull without streaming the full 256 MiB in-test.
        let pull = lazyPull(pasteboard, forType: .fileURL)
        let req = try await awaitRequest(on: hostChannel)
        try hostChannel.send(
            makeAbortFrame(transferID: req.transferID, code: "host.abort", message: "test abort"))
        _ = await pull.value
    }

    @Test("deadline cap: an inline over-cap rep is not deadline-capped — the pull still proceeds")
    func inlineOverCapIsNotDeadlineCapped() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // Inline reps (§1: no Kernova-imposed size bound) are exempt from the
        // deadline cap, which only guards non-inline, non-directory file reps —
        // mirroring the host's `isLazyEligibleFile` gate.
        let overCap = UInt64(ClipboardStreamTuning.maxDeadlineSafeFileBytes) + 1
        try hostChannel.send(
            makeOfferFrame(
                generation: 24,
                reps: [
                    RepInfo(uti: ClipboardContent.utf8TextUTI, byteCount: overCap, isInline: true)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.string] }

        let pull = lazyPull(pasteboard, forType: .string)
        let req = try await awaitRequest(on: hostChannel)
        try hostChannel.send(
            makeAbortFrame(transferID: req.transferID, code: "host.abort", message: "test abort"))
        _ = await pull.value
    }

    @Test(
        "deadline cap: the File Provider relay's fetchStagedFile stays uncapped — an over-cap rep still issues a request"
    )
    func fileProviderRelayIsNotDeadlineCapped() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let txtUTI = try #require(UTType(filenameExtension: "txt")).identifier
        let overCap = UInt64(ClipboardStreamTuning.maxDeadlineSafeFileBytes) + 1
        try hostChannel.send(
            makeOfferFrame(
                generation: 25,
                reps: [
                    RepInfo(uti: txtUTI, byteCount: overCap, filename: "relay-huge.bin", isInline: false)
                ]))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting == [.fileURL] }

        // `fetchStagedFile` (the relay entry point, no OS paste deadline) must
        // issue a real request for the same over-cap rep the pasteboard path
        // above refuses — proving `deadlineBound: false` bypasses the cap.
        let pull = Task.detached { agent.fetchStagedFile(generation: 25, repIndex: 0) }
        let req = try await awaitRequest(on: hostChannel)
        try hostChannel.send(
            makeAbortFrame(transferID: req.transferID, code: "host.abort", message: "test abort"))
        let outcome = await pull.value
        guard case .failure(.pullFailed) = outcome else {
            Issue.record("expected .pullFailed after abort, got \(outcome)")
            return
        }
    }

    // MARK: - Request send failure

    @Test("a request-send failure resolves the lazy pull promptly with nil instead of blocking")
    func requestSendFailureResolvesPromptly() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // Register a promise: the offer writes a lazy `.string` promise without
        // pulling anything.
        try hostChannel.send(makeTextOfferFrame(generation: 99, text: "undeliverable"))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting.contains(.string) }

        // Drive the close + provider invocation in a single main-queue block so
        // the read loop's EOF teardown (dispatched to main) can't nil liveChannel
        // between them. `provideData` reads the still-live channel and receiver,
        // sends the request on the now-closed channel — `send` throws `.closed` —
        // and the send-failure handler resolves the pull synchronously via
        // `cancelAwait` + `coordinator.abort`, so `invokeProvider` returns nil on
        // the same thread without ever blocking toward the 120 s backstop.
        let start = ContinuousClock.now
        let provided: Data? = DispatchQueue.main.sync {
            agent.liveChannelForTesting?.close()
            return pasteboard.invokeProvider(forType: .string)
        }
        let elapsed = ContinuousClock.now - start

        #expect(provided == nil)
        // Promptly: well under the lazy-pull backstop. A regression that didn't
        // resolve the pull on send failure would block the full timeout.
        #expect(
            elapsed < .seconds(5),
            """
            Send failure must resolve the pull promptly, not block toward the \
            \(ClipboardStreamTuning.lazyPullTimeout) backstop (took \(elapsed))
            """)
    }

    // MARK: - Reconnect / lifecycle

    @Test("reconnect resets echo-suppression digest so agent re-offers current pasteboard")
    func reconnectResetsEchoSuppression() async throws {
        let pasteboard = FakePasteboard()
        pasteboard.setString("persistent text", forType: .string)

        let (agentFd0, remoteFd0) = try makeRawSocketPair()
        let (agentFd1, remoteFd1) = try makeRawSocketPair()
        let host0 = VsockChannel(fileDescriptor: remoteFd0)
        let host1 = VsockChannel(fileDescriptor: remoteFd1)
        host0.start()
        host1.start()
        defer { host0.close(); host1.close() }

        let fdBox = FdBox(fds: [agentFd0, agentFd1])
        let provideCount = AtomicInt()

        let client = VsockGuestClient(
            port: 49152,
            label: "clipboard-reconnect-test",
            retryInterval: .milliseconds(50)
        ) { _, _ in
            let n = provideCount.increment()
            guard let fd = fdBox.fd(at: n - 1) else {
                return .failure(.transient("test: no fd at index \(n - 1)"))
            }
            return .success(fd)
        }

        let agent = VsockGuestClipboardAgent(pasteboard: pasteboard, client: client)
        defer { agent.stop() }

        agent.start()
        agent.setEnabled(true)  // production agents are default-disabled until host policy enables them

        // First connection: wait for liveChannel to be published.
        try await waitUntil { agent.liveChannelForTesting != nil }

        // Trigger a poll — agent should offer "persistent text"
        await MainActor.run { agent.checkClipboardChange() }

        let offer1Frame = try await nextFrame(from: host0)
        guard case .clipboardOffer(let offer1) = offer1Frame.payload else {
            throw TestFailure("Expected ClipboardOffer on first connection")
        }
        #expect(offer1.generation >= 1)

        // Close first connection to force reconnect
        host0.close()
        try await waitUntil { agent.liveChannelForTesting == nil }

        // Wait for second connection
        try await waitUntil(timeout: .seconds(2)) { agent.liveChannelForTesting != nil }

        // After reconnect, lastSeenDigest is cleared — next poll should re-offer
        await MainActor.run { agent.checkClipboardChange() }

        let offer2Frame = try await nextFrame(from: host1)
        guard case .clipboardOffer(let offer2) = offer2Frame.payload else {
            throw TestFailure("Expected ClipboardOffer after reconnect")
        }
        #expect(offer2.generation > offer1.generation)
    }

    // MARK: - Teardown identity (Guard #1)

    // The serve() teardown re-checks `liveChannel === channel` before tearing the
    // connection down, so a stale connection's teardown can't clobber a live one.
    // The reconnect loop serves connections strictly sequentially today, so the
    // stale branch never fires in production — these are predicate unit tests of
    // the extracted `teardownIfCurrent`, not a fabricated two-connection race.

    @Test("teardownIfCurrent ignores a stale channel — the live connection and its inbound promise survive")
    func staleChannelDoesNotTearDownLiveConnection() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // Register an inbound promise on the live connection, so a wrongful
        // teardown would be observable as a nil'd generation as well as a nil
        // channel (teardownConnectionState clears both).
        try hostChannel.send(makeTextOfferFrame(generation: 77, text: "live payload"))
        try await waitUntil {
            DispatchQueue.main.sync { agent.inboundPromiseGenerationForTesting } == 77
        }

        // Capture the live channel's identity — only its reference matters here.
        let liveChannel = try #require(DispatchQueue.main.sync { agent.liveChannelForTesting })

        // A throwaway channel that was never served; teardownIfCurrent must reject
        // it by identity, leaving the live connection untouched.
        let (staleFdA, staleFdB) = try makeRawSocketPair()
        let staleChannel = VsockChannel(fileDescriptor: staleFdA)
        let staleOther = VsockChannel(fileDescriptor: staleFdB)
        defer { staleChannel.close(); staleOther.close() }

        await MainActor.run { agent.teardownIfCurrentForTesting(staleChannel) }

        // Both the live channel and its promise are intact — a failed identity
        // check would have nil'd both via teardownConnectionState.
        #expect(DispatchQueue.main.sync { agent.liveChannelForTesting } === liveChannel)
        #expect(DispatchQueue.main.sync { agent.inboundPromiseGenerationForTesting } == 77)
    }

    @Test("teardownIfCurrent tears down when handed the live channel")
    func liveChannelTearsDownConnection() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        let liveChannel = try #require(DispatchQueue.main.sync { agent.liveChannelForTesting })

        // Handed the live channel, the positive branch fires and tears it down.
        await MainActor.run { agent.teardownIfCurrentForTesting(liveChannel) }

        #expect(DispatchQueue.main.sync { agent.liveChannelForTesting } == nil)
    }

    @Test("serve publishes liveChannel synchronously so the read loop can process inbound frames immediately")
    func servePublishesLiveChannelBeforeReadLoop() async throws {
        let pasteboard = FakePasteboard()

        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        // serve() enters `await MainActor.run { liveChannel = channel }` as its
        // first step on a fresh connection — before the for-await read loop.
        // The main queue must process that block BEFORE the read loop starts,
        // otherwise an inbound frame that lands while the publish is pending
        // would be dispatched against a nil liveChannel.
        //
        // After waitUntil sees liveChannel non-nil, sending an inbound offer
        // and observing the registered promise proves the read loop is running
        // and the publish committed before it.
        let provideCount = AtomicInt()
        let client = VsockGuestClient(
            port: 49152,
            label: "clipboard-sync-publish-test",
            retryInterval: .milliseconds(50)
        ) { _, _ in
            provideCount.increment() == 1 ? .success(agentFd) : .failure(.transient("test: no more fds"))
        }

        let agent = VsockGuestClipboardAgent(pasteboard: pasteboard, client: client)
        defer { agent.stop() }
        agent.start()
        agent.setEnabled(true)  // production agents are default-disabled until host policy enables them

        // Wait until publish settles. Under the current code (await MainActor.run),
        // this happens before the read loop starts.
        try await waitUntil { agent.liveChannelForTesting != nil }

        // Snapshot on the main queue: liveChannel must be non-nil.
        // A regression back to DispatchQueue.main.async would leave a window where
        // liveChannel is still nil here, because the async dispatch may not have
        // run before the read loop already processed frames.
        let liveChannelSet = DispatchQueue.main.sync { agent.liveChannelForTesting != nil }
        #expect(
            liveChannelSet,
            "liveChannel was nil on main queue after publish — publish was not synchronous with serve()'s progression")

        // Send an offer and verify the agent registers a promise for it,
        // confirming the read loop is running and liveChannel was already set
        // when the frame arrived. The lazy offer pulls nothing, so the read
        // loop's only observable effect is the promise landing on the pasteboard.
        try hostChannel.send(makeTextOfferFrame(generation: 1, text: "ping"))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting.contains(.string) }
        let promiseGen = DispatchQueue.main.sync { agent.inboundPromiseGenerationForTesting }
        #expect(promiseGen == 1)
        try await expectNoRequest(from: hostChannel)
    }

    @Test("a failed pasteboard promise write clears the inbound promise generation")
    func offerWriteFailureClearsPromiseGeneration() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        // The lazy handleOffer registers a promise by writing one pasteboard
        // item; force that write to fail. The agent must drop the promise so
        // the inbound generation stays nil — a partial write can't leave a
        // dangling promise behind.
        pasteboard.failNextWrite()
        try hostChannel.send(makeTextOfferFrame(generation: 42, text: "lost"))

        // The write attempt bumps the changeCount via clearContents; wait for
        // that observable side effect, then confirm no promise was retained.
        try await pasteboard.changed.wait { pasteboard.changeCount > 0 }
        try await expectNoRequest(from: hostChannel)
        let promiseGen = DispatchQueue.main.sync { agent.inboundPromiseGenerationForTesting }
        #expect(promiseGen == nil)
        #expect(pasteboard.promisedTypesForTesting.isEmpty)
    }

    @Test("data-send failure to a dead peer is handled and liveChannel is cleared")
    func dataSendFailureIsHandledGracefully() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()

        // SO_NOSIGPIPE so a write to a peer-closed socket returns EPIPE rather
        // than delivering SIGPIPE to the test process.
        var noSigpipe: Int32 = 1
        _ = setsockopt(agentFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        try await startAgentAndWaitForLiveChannel(agent: agent)

        pasteboard.setString("guest data", forType: .string)
        await MainActor.run { agent.checkClipboardChange() }

        let offerFrame = try await nextFrame(from: hostChannel)
        guard case .clipboardOffer(let offer) = offerFrame.payload else {
            throw TestFailure("Expected ClipboardOffer, got \(String(describing: offerFrame.payload))")
        }

        // Queue a request in the kernel buffer, then close the host end so the
        // agent's stream reply (Begin/...) arrives at a dead peer.
        let transferID: UInt64 = (offer.generation << 16) | 0
        try hostChannel.send(
            makeRequestFrame(
                generation: offer.generation, transferID: transferID,
                uti: ClipboardContent.utf8TextUTI))
        try hostChannel.send(makeAckFrame(transferID: transferID))
        hostChannel.close()

        // The agent reads the request, tries to stream, fails (peer gone), and
        // must not crash; liveChannel is cleared once the receive loop observes EOF.
        try await waitUntil(timeout: .seconds(2)) { agent.liveChannelForTesting == nil }
        #expect(agent.liveChannelForTesting == nil, "liveChannel should be nil after peer EOF")
    }

    // MARK: - Policy enforcement

    @Test("Default-disabled: setEnabled(false) is the construction state")
    func defaultDisabledAtConstruction() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, _) = try makeRawSocketPair()
        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        // Sanity: read enabled flag via the test seam from the main queue.
        let isEnabled = DispatchQueue.main.sync { agent.isEnabledForTesting }
        #expect(isEnabled == false)
    }

    @Test("setEnabled(true) brings up the connection; setEnabled(false) tears it down")
    func setEnabledTogglesLiveChannel() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }

        agent.start()

        // Without setEnabled(true), no connection should come up.
        try await Task.sleep(for: .milliseconds(150))
        let stillNil = DispatchQueue.main.sync { agent.liveChannelForTesting }
        #expect(stillNil == nil)

        // Enable: connection comes up.
        agent.setEnabled(true)
        try await waitUntil { agent.liveChannelForTesting != nil }

        // Disable: liveChannel is cleared.
        agent.setEnabled(false)
        try await waitUntil { agent.liveChannelForTesting == nil }
    }

    // MARK: - Lazy inbound drivers (act as the host sender)

    /// Kicks off a lazy paste off the test's main actor.
    ///
    /// The agent's `provideData` callback BLOCKS the calling thread until the
    /// streamed bytes (or a file URL) land, so it must run off the test's main
    /// actor. Returns a `Task` whose `.value` is the bytes the provider produced
    /// (the inline bytes for a UTI type, a `file://` URL string for `.fileURL`,
    /// or `nil` on abort/timeout/disk-full).
    ///
    /// The caller streams the response on the host channel concurrently — e.g.
    /// via `driveInboundStream` — before awaiting `.value`.
    // MARK: - UI activity seam

    @Test("outbound offer sets clipboard activity to .offeredToHost")
    func outboundOfferSetsActivity() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        let initial = await MainActor.run { agent.clipboardActivity }
        #expect(initial == .enabled)

        pasteboard.setString("hello", forType: .string)
        await MainActor.run { agent.checkClipboardChange() }
        _ = try await awaitOffer(on: hostChannel)  // ensure the offer was sent

        let after = await MainActor.run { agent.clipboardActivity }
        #expect(after == .offeredToHost)
    }

    @Test("a delivered inbound paste sets clipboard activity to .receivedFromHost")
    func inboundPullSetsActivity() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        try hostChannel.send(makeTextOfferFrame(generation: 1, text: "payload"))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting.contains(.string) }

        let payload = Data("payload".utf8)
        let pull = lazyPull(pasteboard, forType: .string)
        try await driveInboundStream(
            generation: 1, uti: ClipboardContent.utf8TextUTI, filename: "", payload: payload,
            isInline: true, on: hostChannel)
        _ = await pull.value

        let after = await MainActor.run { agent.clipboardActivity }
        #expect(after == .receivedFromHost)
    }

    @Test("an inbound host offer sets clipboard activity to .offeredFromHost")
    func inboundOfferSetsActivity() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        // Registering the promise (and setting the activity) happen together in
        // handleOffer; once the promise is observable the activity is set too.
        try hostChannel.send(makeTextOfferFrame(generation: 1, text: "payload"))
        try await pasteboard.changed.wait { pasteboard.promisedTypesForTesting.contains(.string) }

        let after = await MainActor.run { agent.clipboardActivity }
        #expect(after == .offeredFromHost)
    }

    @Test("a host request for the guest's clipboard sets activity to .sentToHost")
    func outboundRequestSetsActivity() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)

        pasteboard.setString("hello from guest", forType: .string)
        await MainActor.run { agent.checkClipboardChange() }
        let offer = try await awaitOffer(on: hostChannel)
        let info = try #require(offer.repInfo.first)

        let transferID: UInt64 = (offer.generation << 16) | 0
        try hostChannel.send(
            makeRequestFrame(generation: offer.generation, transferID: transferID, uti: info.uti))
        // Once the streamed transfer is collected, handleRequest has run on main
        // (Begin can't precede startTransfer), so the activity is set.
        _ = try await collectOutboundTransfer(transferID: transferID, from: hostChannel)

        let after = await MainActor.run { agent.clipboardActivity }
        #expect(after == .sentToHost)
    }

    @Test("setEnabled(false) sets activity to .disabled; re-enabling resets to .enabled")
    func setEnabledTogglesActivity() async throws {
        let pasteboard = FakePasteboard()
        let (agentFd, remoteFd) = try makeRawSocketPair()
        let hostChannel = VsockChannel(fileDescriptor: remoteFd)
        hostChannel.start()
        defer { hostChannel.close() }

        let agent = makeAgent(pasteboard: pasteboard, agentFd: agentFd)
        defer { agent.stop() }
        try await startAgentAndWaitForLiveChannel(agent: agent)  // leaves it enabled
        #expect(await MainActor.run { agent.clipboardActivity } == .enabled)

        agent.setEnabled(false)
        try await waitUntil { DispatchQueue.main.sync { agent.isEnabledForTesting } == false }
        #expect(await MainActor.run { agent.clipboardActivity } == .disabled)

        agent.setEnabled(true)
        try await waitUntil { DispatchQueue.main.sync { agent.isEnabledForTesting } == true }
        #expect(await MainActor.run { agent.clipboardActivity } == .enabled)
    }

    private func lazyPull(
        _ pasteboard: FakePasteboard, forType type: NSPasteboard.PasteboardType,
        itemIndex: Int? = nil
    ) -> Task<Data?, Never> {
        Task.detached {
            await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(
                        returning: pasteboard.invokeProvider(forType: type, itemIndex: itemIndex))
                }
            }
        }
    }

    /// Reads frames until a `ClipboardRequest` arrives, draining `ack` frames a
    /// prior inbound stream left queued (so two sequential pulls on one channel
    /// don't trip over the first stream's acks).
    private func awaitRequest(on channel: VsockChannel) async throws -> Kernova_V1_ClipboardRequest {
        while true {
            let frame = try await nextFrame(from: channel)
            switch frame.payload {
            case .clipboardRequest(let req):
                return req
            case .clipboardStreamAck:
                continue
            default:
                throw TestFailure(
                    "Expected ClipboardRequest, got \(String(describing: frame.payload))")
            }
        }
    }

    /// Reads frames until a `ClipboardOffer` arrives, draining `ack` frames a
    /// prior inbound stream left queued.
    private func awaitOffer(on channel: VsockChannel) async throws -> Kernova_V1_ClipboardOffer {
        while true {
            let frame = try await nextFrame(from: channel)
            switch frame.payload {
            case .clipboardOffer(let offer):
                return offer
            case .clipboardStreamAck:
                continue
            default:
                throw TestFailure(
                    "Expected ClipboardOffer, got \(String(describing: frame.payload))")
            }
        }
    }

    /// Responds to the agent's lazy pull by streaming the requested rep.
    ///
    /// Awaits the `ClipboardRequest` (running `validate` against it), then
    /// streams `Begin`/`Chunk`(s)/`End` for the request's transfer. The agent's
    /// `ClipboardStreamReceiver` acks each chunk automatically, so we just push
    /// frames and let it reassemble.
    private func driveInboundStream(
        generation: UInt64, uti: String, filename: String, payload: Data, isInline: Bool,
        chunkSize: Int = 64 * 1024, on channel: VsockChannel,
        validate: (Kernova_V1_ClipboardRequest) -> Void = { _ in }
    ) async throws {
        let req = try await awaitRequest(on: channel)
        validate(req)
        try channel.send(
            makeBeginFrame(
                generation: generation, transferID: req.transferID, uti: uti,
                totalBytes: payload.count, filename: filename, isInline: isInline))
        var offset = 0
        while offset < payload.count {
            let end = min(offset + chunkSize, payload.count)
            let slice = payload.subdata(in: offset..<end)
            try channel.send(makeChunkFrame(transferID: req.transferID, offset: offset, data: slice))
            offset = end
        }
        try channel.send(makeEndFrame(transferID: req.transferID, payload: payload))
    }

    // MARK: - Negative-wait helpers

    /// Asserts no `ClipboardOffer` arrives on `channel` within a short window.
    private func expectNoOffer(from channel: VsockChannel) async throws {
        if let frame = try await maybeNextFrame(from: channel), case .clipboardOffer = frame.payload {
            throw TestFailure("Unexpected ClipboardOffer; echo/skip suppression failed")
        }
    }

    /// Asserts no `ClipboardRequest` arrives on `channel` within a short window.
    private func expectNoRequest(from channel: VsockChannel) async throws {
        if let frame = try await maybeNextFrame(from: channel),
            case .clipboardRequest = frame.payload
        {
            throw TestFailure("Unexpected ClipboardRequest")
        }
    }

    /// Reads one frame if one arrives within a short window, else returns nil.
    ///
    /// NOTE: This is a bounded negative wait. There's no event to await for "no
    /// frame will ever arrive," so a small sleep is the pragmatic backstop — the
    /// agent's reaction (if any) runs on the main queue and would have been
    /// dispatched before this window elapses.
    private func maybeNextFrame(
        from channel: VsockChannel, window: Duration = .milliseconds(200)
    ) async throws -> Frame? {
        let receiver = Task<Frame?, Never> {
            var iterator = channel.incoming.makeAsyncIterator()
            return try? await iterator.next()
        }
        try await Task.sleep(for: window)
        receiver.cancel()
        return await receiver.value
    }

    // MARK: - Image / temp-file helpers

    private func makeTestPNG() throws -> Data {
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    private func writeTempFolder(name: String, files: [(String, Data)]) throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("KernovaAgentFolder-\(UUID().uuidString)", isDirectory: true)
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (path, data) in files {
            let fileURL = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL)
        }
        return folder
    }

    private func writeTempFile(name: String, data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KernovaAgentClip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}

// MARK: - Thread-safe fd array

/// Sendable wrapper for an array of file descriptors used in socket provider closures.
final class FdBox: @unchecked Sendable {
    private let fds: [Int32]  // Immutable post-init; lock not needed.

    init(fds: [Int32]) {
        self.fds = fds
    }

    func fd(at index: Int) -> Int32? {
        guard index >= 0 && index < fds.count else { return nil }
        return fds[index]
    }
}
