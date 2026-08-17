import Foundation
import KernovaTestSupport

@testable import KernovaKit

// Harnesses for the `ClipboardEndpoint` suites: `EndpointPair` runs both ends of
// one channel through real endpoints, `RawPeerHarness` runs one real endpoint
// against a bare channel a test writes frames onto and reads them back from.

// MARK: - One end

/// One real endpoint with everything a test reads it through.
@MainActor
final class EndpointSide {
    let endpoint: ClipboardEndpoint
    let recorder = EndpointRecorder()
    let reports = ClipboardTransferReports()
    let staging: ClipboardFileStaging?
    let clock: TestEngineClock
    let channel: VsockChannel
    /// The ceiling `maxPasteBytes` reads, so a test can move it mid-connection.
    let pasteLimit: Box<Int>
    private let stagingRoot: URL?

    init(
        channel: VsockChannel,
        role: ClipboardEndpoint.Role,
        kind: ClipboardEndpoint.Kind,
        label: String,
        peerName: String,
        receives: Bool,
        pasteLimit: Int,
        freeSpaceProvider: ClipboardFileStaging.FreeSpaceProvider?,
        lazyPullTimeout: TimeInterval,
        firstGeneration: UInt64
    ) {
        self.channel = channel
        self.pasteLimit = Box(pasteLimit)
        let clock = TestEngineClock()
        self.clock = clock
        if receives {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("endpoint-\(UUID().uuidString)", isDirectory: true)
            stagingRoot = root
            staging = ClipboardFileStaging(
                label: label, tempRoot: root, freeSpaceProvider: freeSpaceProvider)
        } else {
            stagingRoot = nil
            staging = nil
        }
        let limit = self.pasteLimit
        var configuration = ClipboardEndpoint.Configuration(
            role: role, kind: kind, label: label, peerName: peerName,
            maxPasteBytes: { limit.value }, staging: staging)
        configuration.lazyPullTimeout = lazyPullTimeout
        configuration.progressRevealDelay = 0
        configuration.progressIdleGap = 0
        configuration.clock = clock
        configuration.firstGeneration = firstGeneration
        endpoint = ClipboardEndpoint(
            channel: channel, configuration: configuration, reporter: reports.reporter)
        endpoint.delegate = recorder
    }

    func start() {
        endpoint.start()
    }

    func tearDown() {
        endpoint.stop()
        channel.close()
        staging?.sweep()
        if let stagingRoot { try? FileManager.default.removeItem(at: stagingRoot) }
    }

    /// Fires a blocking `.fileURL` serve off the test's main actor, as the
    /// pasteboard's provider callback does.
    func serveFileURLOffMain(generation: UInt64, repIndex: Int) async -> URL? {
        let endpoint = self.endpoint
        return await offCooperativePool {
            endpoint.serveFileURL(generation: generation, repIndex: repIndex)
        }
    }

    /// Fires a blocking inline serve off the test's main actor.
    func serveDataOffMain(generation: UInt64, repIndex: Int, uti: String) async -> Data? {
        let endpoint = self.endpoint
        return await offCooperativePool {
            endpoint.serveData(generation: generation, repIndex: repIndex, uti: uti)
        }
    }

    /// Starts a blocking `.fileURL` serve without awaiting it, so a test can
    /// drive the wire while it is parked.
    func startFileURLServe(generation: UInt64, repIndex: Int) -> Task<URL?, Never> {
        let endpoint = self.endpoint
        return Task {
            await offCooperativePool {
                endpoint.serveFileURL(generation: generation, repIndex: repIndex)
            }
        }
    }

    /// Starts a blocking inline serve without awaiting it.
    func startDataServe(generation: UInt64, repIndex: Int, uti: String) -> Task<Data?, Never> {
        let endpoint = self.endpoint
        return Task {
            await offCooperativePool {
                endpoint.serveData(generation: generation, repIndex: repIndex, uti: uti)
            }
        }
    }

    /// Starts a blocking caller-owned pull without awaiting it.
    func startPull(
        generation: UInt64, repIndex: Int, operation: ClipboardTransferOperation
    ) -> Task<LazyPullOutcome, Never> {
        let endpoint = self.endpoint
        return Task {
            await offCooperativePool {
                endpoint.pull(generation: generation, repIndex: repIndex, operation: operation)
            }
        }
    }

    /// A readout of this side's own, for the callers that own one.
    func makeOperation(
        gesture: ClipboardTransferGesture, direction: ClipboardProgressSnapshot.Direction,
        onCancelRequested: (@Sendable () -> Void)? = nil
    ) -> ClipboardTransferOperation {
        ClipboardTransferOperation(
            gesture: gesture, direction: direction, peerName: "peer", revealDelay: 0, idleGap: 0,
            onCancelRequested: onCancelRequested, reporter: reports.reporter)
    }
}

// MARK: - Both ends

/// A host endpoint and a guest endpoint of one kind, over a real socketpair.
@MainActor
final class EndpointPair {
    let host: EndpointSide
    let guest: EndpointSide

    init(
        kind: ClipboardEndpoint.Kind = .clipboard,
        hostPasteLimit: Int = ClipboardPasteLimit.defaultBytes,
        guestPasteLimit: Int = ClipboardPasteLimit.defaultBytes,
        hostFreeSpace: ClipboardFileStaging.FreeSpaceProvider? = nil,
        guestFreeSpace: ClipboardFileStaging.FreeSpaceProvider? = nil,
        lazyPullTimeout: TimeInterval = ClipboardStreamTuning.lazyPullTimeout,
        hostFirstGeneration: UInt64 = 1,
        guestFirstGeneration: UInt64 = 1,
        autoStart: Bool = true
    ) throws {
        let (a, b) = try makeStartedChannelPair()
        host = EndpointSide(
            channel: a, role: .host, kind: kind, label: "host", peerName: "Guest",
            receives: kind == .clipboard, pasteLimit: hostPasteLimit,
            freeSpaceProvider: hostFreeSpace, lazyPullTimeout: lazyPullTimeout,
            firstGeneration: hostFirstGeneration)
        guest = EndpointSide(
            channel: b, role: .guest, kind: kind, label: "guest", peerName: "Mac",
            receives: true, pasteLimit: guestPasteLimit, freeSpaceProvider: guestFreeSpace,
            lazyPullTimeout: lazyPullTimeout, firstGeneration: guestFirstGeneration)
        guard autoStart else { return }
        host.start()
        guest.start()
    }

    func tearDown() {
        host.tearDown()
        guest.tearDown()
    }
}

// MARK: - One end and a bare peer

/// One real endpoint against a bare channel, for the tests that inject frames or
/// prove which ones went out.
@MainActor
final class RawPeerHarness {
    let side: EndpointSide
    /// The peer's end of the wire — a test writes frames onto it directly.
    let peer: VsockChannel
    let recorder: FrameRecorder

    init(
        role: ClipboardEndpoint.Role = .host,
        kind: ClipboardEndpoint.Kind = .clipboard,
        receives: Bool = true,
        pasteLimit: Int = ClipboardPasteLimit.defaultBytes,
        freeSpaceProvider: ClipboardFileStaging.FreeSpaceProvider? = nil,
        lazyPullTimeout: TimeInterval = ClipboardStreamTuning.lazyPullTimeout,
        firstGeneration: UInt64 = 1,
        autoStart: Bool = true
    ) throws {
        let (localFd, peerFd) = try makeRawSocketPair()
        let local = VsockChannel(fileDescriptor: localFd)
        peer = VsockChannel(fileDescriptor: peerFd)
        local.start()
        peer.start()
        side = EndpointSide(
            channel: local, role: role, kind: kind,
            label: role == .host ? "host" : "guest",
            peerName: role == .host ? "Guest" : "Mac", receives: receives,
            pasteLimit: pasteLimit, freeSpaceProvider: freeSpaceProvider,
            lazyPullTimeout: lazyPullTimeout, firstGeneration: firstGeneration)
        recorder = FrameRecorder(channel: peer)
        if autoStart { side.start() }
    }

    var endpoint: ClipboardEndpoint { side.endpoint }

    func send(_ frame: Frame) throws {
        try peer.send(frame)
    }

    func tearDown() {
        recorder.cancel()
        side.tearDown()
        peer.close()
    }

    /// The transfer id the endpoint mints for `(generation, repIndex)` — what a
    /// peer standing in for the streaming side answers.
    func transferID(generation: UInt64, repIndex: Int) -> UInt64 {
        ClipboardTransferID.make(
            generation: generation, repIndex: repIndex, hostMinted: side.endpoint.role == .host)
    }

    /// The transfer id a peer *requesting* from this endpoint would mint.
    func peerTransferID(generation: UInt64, repIndex: Int) -> UInt64 {
        ClipboardTransferID.make(
            generation: generation, repIndex: repIndex, hostMinted: side.endpoint.role != .host)
    }

    /// Waits for the request the endpoint sends for `(generation, repIndex)`.
    @discardableResult
    func waitForRequest(generation: UInt64, repIndex: Int) async throws
        -> Kernova_V1_ClipboardRequest
    {
        let id = transferID(generation: generation, repIndex: repIndex)
        try await recorder.waitForFrames { self.recorder.requests.contains { $0.transferID == id } }
        guard let request = recorder.requests.first(where: { $0.transferID == id }) else {
            throw TestFailure("Request for transfer \(id) vanished")
        }
        return request
    }

    /// Answers a pull with a whole inline payload.
    func streamInline(
        generation: UInt64, repIndex: Int, uti: String, payload: Data, filename: String = ""
    ) throws {
        let id = transferID(generation: generation, repIndex: repIndex)
        try send(
            makeBeginFrame(
                generation: generation, transferID: id, uti: uti, totalBytes: payload.count,
                filename: filename, isInline: true))
        try send(makeChunkFrame(transferID: id, offset: 0, data: payload))
        try send(makeEndFrame(transferID: id, payload: payload))
    }
}

// MARK: - Content fixtures

/// A file of `bytes` under a fresh temporary directory, as a producer-side
/// representation.
@MainActor
func makeFileRepresentation(
    named name: String, bytes: Data, uti: String = "public.data"
) throws -> (representation: ClipboardContent.Representation, url: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("endpoint-source-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try bytes.write(to: url)
    return (
        ClipboardContent.Representation(
            uti: uti, fileURL: url, byteCount: bytes.count, filename: name),
        url
    )
}

/// A folder holding `files`, as a producer-side directory representation.
@MainActor
func makeDirectoryRepresentation(
    named name: String, files: [String: Data]
) throws -> (representation: ClipboardContent.Representation, url: URL) {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("endpoint-source-\(UUID().uuidString)", isDirectory: true)
    let directory = parent.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var total = 0
    for (file, bytes) in files {
        try bytes.write(to: directory.appendingPathComponent(file))
        total += bytes.count
    }
    return (
        ClipboardContent.Representation(
            directorySourceURL: directory, estimatedByteCount: total, filename: name),
        directory
    )
}

/// The file at `url` a served `.fileURL` names.
func contents(ofServed url: URL?) throws -> Data {
    guard let url else { throw TestFailure("No file URL was served") }
    return try Data(contentsOf: url)
}
