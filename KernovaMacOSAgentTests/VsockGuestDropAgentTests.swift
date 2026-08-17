import CryptoKit
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing
import UniformTypeIdentifiers

/// Unit tests for the guest side of a display drop: pulling each offered file,
/// landing it in Downloads with Finder's own naming, revealing the result, and
/// what it reports when the drop is cancelled or cannot be written.
@Suite("VsockGuestDropAgent")
struct VsockGuestDropAgentTests {
    // MARK: - Harness

    /// The agent under test, the host end of its channel, and the fake Downloads
    /// folder it writes into.
    private final class Harness {
        let agent: VsockGuestDropAgent
        let host: VsockChannel
        let downloads: URL
        let root: URL
        /// Every set of URLs handed to the Finder reveal, in order.
        let revealed = AtomicBox<[URL]>()
        let reporter: ClipboardTransferReporter

        init(freeSpaceProvider: ClipboardFileStaging.FreeSpaceProvider? = nil) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "VsockGuestDropAgentTests-\(UUID().uuidString)",
                    isDirectory: true)
            downloads = root.appendingPathComponent("Downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)

            let (agentFd, hostFd) = try makeRawSocketPair()
            host = VsockChannel(fileDescriptor: hostFd)
            host.start()

            let provided = AtomicInt()
            let client = VsockGuestClient(
                port: KernovaVsockPort.drop, label: "drop-test",
                clock: MonotonicEngineClock(), retryInterval: 0.05
            ) { _, _ in
                provided.increment() == 1 ? .success(agentFd) : .failure(.transient("test: no fd"))
            }
            reporter = ClipboardTransferReporter(dwell: 0)
            let revealed = self.revealed
            agent = VsockGuestDropAgent(
                client: client, reporter: reporter,
                // Zeroed delays so a live transfer's readout is observable.
                progressRevealDelay: 0, progressIdleGap: 0, downloadsDirectory: downloads,
                stagingTempRoot: root.appendingPathComponent("staging", isDirectory: true),
                freeSpaceProvider: freeSpaceProvider,
                revealInFinder: { urls in revealed.set(urls) })
            agent.hostSupportsDrop = { true }
        }

        /// Starts the agent, enables it the way the control agent's capability
        /// hook does, and waits for the channel to land.
        func start() async throws {
            agent.start()
            agent.syncEnablement()
            // RATIONALE: sanctioned no-signal poll (docs/TESTING.md) — the
            // lifecycle read is SUT-internal state with nothing to await on.
            try await waitUntil { agent.liveChannelForTesting != nil }
        }

        func tearDown() {
            agent.stop()
            host.close()
            try? FileManager.default.removeItem(at: root)
        }

        /// Names of the entries in the fake Downloads folder, sorted.
        var downloadNames: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) ?? []).sorted()
        }

        func downloadContents(_ name: String) -> Data? {
            try? Data(contentsOf: downloads.appendingPathComponent(name))
        }
    }

    // MARK: - Frame factories

    /// One dropped file's metadata, as the host would offer it.
    private func fileRep(_ name: String, bytes: Data) -> RepInfo {
        RepInfo(
            uti: UTType(filenameExtension: (name as NSString).pathExtension)?.identifier
                ?? UTType.data.identifier,
            byteCount: UInt64(bytes.count), filename: name, isInline: false)
    }

    /// The id the guest mints for representation `index` of `generation`.
    private func transferID(generation: UInt64, repIndex: Int) -> UInt64 {
        ClipboardTransferID.make(generation: generation, repIndex: repIndex, hostMinted: false)
    }

    /// Reads frames until the agent's request for `transferID` arrives, then
    /// streams `payload` back to it as the archive a drop crosses as.
    ///
    /// `payload` is the dropped file's own bytes, wrapped here in the one-entry
    /// archive the host's sender would encode; pass `payloadIsArchived` when it
    /// is already the archive — a folder's tree.
    ///
    /// Returns the request it answered, so a caller can assert on request
    /// ordering.
    @discardableResult
    private func serveRequest(
        on channel: VsockChannel, generation: UInt64, repIndex: Int, payload: Data,
        payloadIsArchived: Bool = false
    ) async throws -> Kernova_V1_ClipboardRequest {
        let expected = transferID(generation: generation, repIndex: repIndex)
        let wire =
            payloadIsArchived
            ? payload
            : try clipboardArchiveBytes(of: .blob(payload, name: "data"))
        while true {
            let frame = try await nextFrame(from: channel)
            guard case .clipboardRequest(let request) = frame.payload,
                request.transferID == expected
            else { continue }
            try channel.send(
                makeBeginFrame(
                    generation: generation, transferID: expected, uti: request.uti,
                    // An archive's wire size isn't known until its last byte.
                    totalBytes: 0, filename: "", isInline: false, isArchive: true))
            try channel.send(makeChunkFrame(transferID: expected, offset: 0, data: wire))
            try channel.send(makeEndFrame(transferID: expected, payload: wire))
            return request
        }
    }

    /// Reads frames until a `DropComplete` arrives.
    private func awaitCompletion(
        on channel: VsockChannel
    ) async throws -> Kernova_V1_DropComplete {
        while true {
            let frame = try await nextFrame(from: channel)
            if case .dropComplete(let complete) = frame.payload { return complete }
        }
    }

    // MARK: - Happy path

    @Test("every offered file is requested in order and lands in Downloads")
    func landsEveryDroppedFile() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        try await harness.start()

        let first = Data("first file".utf8)
        let second = Data(repeating: 0x7F, count: 4_096)
        try harness.host.send(
            makeDropOfferFrame(
                generation: 1,
                reps: [fileRep("notes.txt", bytes: first), fileRep("blob.bin", bytes: second)]))

        try await serveRequest(on: harness.host, generation: 1, repIndex: 0, payload: first)
        try await serveRequest(on: harness.host, generation: 1, repIndex: 1, payload: second)
        let complete = try await awaitCompletion(on: harness.host)

        #expect(complete.generation == 1)
        #expect(complete.outcome == .completed)
        #expect(harness.downloadNames == ["blob.bin", "notes.txt"])
        #expect(harness.downloadContents("notes.txt") == first)
        #expect(harness.downloadContents("blob.bin") == second)
    }

    @Test("a dropped folder lands in Downloads as a tree under its own name")
    func landsADroppedFolder() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        try await harness.start()

        let source = harness.root.appendingPathComponent("source/Photos", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("sub", isDirectory: true),
            withIntermediateDirectories: true)
        try Data("one".utf8).write(to: source.appendingPathComponent("one.txt"))
        try Data("deep".utf8).write(to: source.appendingPathComponent("sub/deep.txt"))
        let tree = try clipboardArchiveBytes(ofDirectoryAt: source)

        // The folder's own name rides the offer, not the archive: its entries are
        // relative to it, so the guest is what recreates the folder itself.
        try harness.host.send(
            makeDropOfferFrame(
                generation: 1,
                reps: [
                    RepInfo(
                        uti: ClipboardArchive.directoryUTI, byteCount: 7, filename: "Photos",
                        isInline: false, isDirectory: true)
                ]))
        try await serveRequest(
            on: harness.host, generation: 1, repIndex: 0, payload: tree, payloadIsArchived: true)
        let complete = try await awaitCompletion(on: harness.host)

        #expect(complete.outcome == .completed)
        #expect(harness.downloadNames == ["Photos"])
        let landed = harness.downloads.appendingPathComponent("Photos", isDirectory: true)
        #expect(try Data(contentsOf: landed.appendingPathComponent("one.txt")) == Data("one".utf8))
        #expect(
            try Data(contentsOf: landed.appendingPathComponent("sub/deep.txt"))
                == Data("deep".utf8))
    }

    @Test("a completed drop reveals exactly the files it landed")
    func revealsTheLandedFiles() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        try await harness.start()

        let payload = Data("reveal me".utf8)
        try harness.host.send(
            makeDropOfferFrame(generation: 1, reps: [fileRep("shown.txt", bytes: payload)]))
        try await serveRequest(on: harness.host, generation: 1, repIndex: 0, payload: payload)
        _ = try await awaitCompletion(on: harness.host)

        try await harness.revealed.changed.wait { harness.revealed.value != nil }
        #expect(harness.revealed.value?.map(\.lastPathComponent) == ["shown.txt"])
    }

    @Test("a name already taken in Downloads counts up the way Finder does")
    func uniquesAgainstAnExistingName() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        try Data("existing".utf8).write(
            to: harness.downloads.appendingPathComponent("report.pdf"))
        try await harness.start()

        let payload = Data("arriving".utf8)
        try harness.host.send(
            makeDropOfferFrame(generation: 1, reps: [fileRep("report.pdf", bytes: payload)]))
        try await serveRequest(on: harness.host, generation: 1, repIndex: 0, payload: payload)
        _ = try await awaitCompletion(on: harness.host)

        #expect(harness.downloadNames == ["report 2.pdf", "report.pdf"])
        // The file that was already there is untouched.
        #expect(harness.downloadContents("report.pdf") == Data("existing".utf8))
        #expect(harness.downloadContents("report 2.pdf") == payload)
    }

    // MARK: - Cancelling

    @Test("a release keeps what already landed and stops the rest")
    func releaseKeepsCompletedFiles() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        try await harness.start()

        let landed = Data("already here".utf8)
        let never = Data(repeating: 0x11, count: 64)
        try harness.host.send(
            makeDropOfferFrame(
                generation: 1,
                reps: [fileRep("kept.txt", bytes: landed), fileRep("dropped.bin", bytes: never)]))
        try await serveRequest(on: harness.host, generation: 1, repIndex: 0, payload: landed)

        // The second file's request arrives, and is answered with a release
        // instead of bytes.
        while true {
            let frame = try await nextFrame(from: harness.host)
            if case .clipboardRequest(let request) = frame.payload,
                request.transferID == transferID(generation: 1, repIndex: 1)
            {
                break
            }
        }
        try harness.host.send(makeDropReleaseFrame(generation: 1))
        let complete = try await awaitCompletion(on: harness.host)

        #expect(complete.outcome == .cancelled)
        // Finder's own cancel keeps what it already copied, and so does this.
        #expect(harness.downloadNames == ["kept.txt"])
        #expect(harness.downloadContents("kept.txt") == landed)
        // Nothing is revealed for a drop the user called off.
        #expect(harness.revealed.value == nil)
    }

    @Test("a cancel on this guest's readout aborts the transfer and reports it")
    func guestCancelAbortsAndReports() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        try await harness.start()

        let payload = Data(repeating: 0x22, count: 128)
        try harness.host.send(
            makeDropOfferFrame(generation: 1, reps: [fileRep("pending.bin", bytes: payload)]))
        // Wait for the request, then cancel without ever answering it — the
        // worker is parked on the pull, which is where a cancel has to reach it.
        while true {
            let frame = try await nextFrame(from: harness.host)
            if case .clipboardRequest = frame.payload { break }
        }
        let reporter = harness.reporter
        await MainActor.run { reporter.cancelRunning() }

        var sawAbort = false
        var complete: Kernova_V1_DropComplete?
        while complete == nil {
            let frame = try await nextFrame(from: harness.host)
            switch frame.payload {
            case .clipboardStreamAbort(let abort):
                #expect(abort.code == ClipboardStreamAbortCode.userCancelled.rawValue)
                sawAbort = true
            case .dropComplete(let value):
                complete = value
            default:
                continue
            }
        }
        #expect(sawAbort)
        #expect(complete?.outcome == .cancelled)
        #expect(harness.downloadNames.isEmpty)
    }

    @Test("a retiring abort mid-transfer cancels the job rather than failing it")
    func retiringAbortCancelsTheJob() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        try await harness.start()

        // Every terminal the drop's readout publishes, since the zero dwell
        // retires the live report as soon as it stands.
        let finishes = AtomicBox<[ClipboardTransferFinish]>()
        let reporter = harness.reporter
        await MainActor.run {
            reporter.onReportChanged = { report in
                guard case .finished(let finish) = report else { return }
                finishes.set((finishes.value ?? []) + [finish])
            }
        }

        try harness.host.send(
            makeDropOfferFrame(
                generation: 1,
                reps: [fileRep("pending.bin", bytes: Data(repeating: 0x33, count: 128))]))

        // The shape a channel closing under the job delivers: the session cancels
        // every awaiter before its end reaches the job loop, so the abort lands
        // while the job's own offer is still standing. Driven as a frame here so
        // the completion stays observable.
        while true {
            let frame = try await nextFrame(from: harness.host)
            if case .clipboardRequest(let request) = frame.payload {
                try harness.host.send(
                    makeAbortFrame(
                        transferID: request.transferID,
                        code: ClipboardStreamAbortCode.cancelled.rawValue,
                        message: "Transfer superseded or channel closed"))
                break
            }
        }

        let complete = try await awaitCompletion(on: harness.host)
        #expect(complete.outcome == .cancelled)
        #expect(complete.code.isEmpty)

        try await finishes.changed.wait { finishes.value?.isEmpty == false }
        let finish = try #require(finishes.value?.last)
        #expect(finish.gesture == .drop)
        guard case .cancelled = finish.outcome else {
            Issue.record("Expected a cancelled drop, got \(finish.outcome)")
            return
        }
        #expect(harness.downloadNames.isEmpty)
        #expect(harness.revealed.value == nil)
    }

    // MARK: - Failures

    @Test("a Downloads folder that cannot be written fails the drop with a code")
    func unwritableDownloadsFailsTheDrop() async throws {
        let harness = try Harness()
        defer {
            // Restore write permission so the temp tree can be removed.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: harness.downloads.path)
            harness.tearDown()
        }
        try await harness.start()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: harness.downloads.path)

        let payload = Data("nowhere to go".utf8)
        try harness.host.send(
            makeDropOfferFrame(generation: 1, reps: [fileRep("blocked.txt", bytes: payload)]))
        try await serveRequest(on: harness.host, generation: 1, repIndex: 0, payload: payload)
        let complete = try await awaitCompletion(on: harness.host)

        #expect(complete.outcome == .failed)
        #expect(complete.code == ClipboardErrorCode.dropDownloadsDenied.rawValue)
        #expect(harness.revealed.value == nil)
    }

    @Test("a volume with no room refuses the file before requesting a byte")
    func refusesWhenTheVolumeIsFull() async throws {
        let harness = try Harness(freeSpaceProvider: { _ in 0 })
        defer { harness.tearDown() }
        try await harness.start()

        try harness.host.send(
            makeDropOfferFrame(
                generation: 1, reps: [fileRep("huge.bin", bytes: Data(repeating: 0, count: 1_024))]))
        let complete = try await awaitCompletion(on: harness.host)

        #expect(complete.outcome == .failed)
        #expect(complete.code == ClipboardErrorCode.dropDiskFull.rawValue)
        #expect(harness.downloadNames.isEmpty)
    }

    // MARK: - Enablement

    @Test("the client stays paused until the host advertises the capability")
    func staysPausedWithoutTheCapability() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.agent.hostSupportsDrop = { false }

        harness.agent.start()
        harness.agent.syncEnablement()
        // A host with no drop listener is never redialled, so no channel lands.
        // Several retry intervals' worth of silence is the assertion.
        try await MonotonicEngineClock().sleep(for: 0.2)
        #expect(harness.agent.liveChannelForTesting == nil)

        // The capability arriving is what starts the client.
        harness.agent.hostSupportsDrop = { true }
        harness.agent.syncEnablement()
        try await waitUntil { harness.agent.liveChannelForTesting != nil }
    }
}
