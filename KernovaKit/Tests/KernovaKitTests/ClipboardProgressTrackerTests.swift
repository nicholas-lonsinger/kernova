import Foundation
import Testing

@testable import KernovaKit

/// Unit tests for `ClipboardProgressTracker` — the per-paste aggregation
/// behind the status-item progress readout (#643).
///
/// Every wait is removed rather than made event-driven: the tracker takes its
/// clock and its delay scheduler as injected closures, so a test advances time
/// by assignment and fires the idle terminal by hand. Emissions land
/// synchronously on the calling thread, so assertions read the recorded list
/// directly.
@Suite("ClipboardProgressTracker")
struct ClipboardProgressTrackerTests {
    // MARK: - Harness

    /// Drives a tracker with a controllable clock and scheduler, recording every
    /// emission.
    private final class Harness: @unchecked Sendable {
        private final class State: @unchecked Sendable {
            let lock = NSLock()
            var now: TimeInterval = 0
            var emissions: [ClipboardProgressSnapshot?] = []
            var pending: [@Sendable () -> Void] = []
            var scheduledDelays: [TimeInterval] = []
        }

        let tracker: ClipboardProgressTracker
        private let state: State

        init(revealDelay: TimeInterval = 1, idleLinger: TimeInterval = 2) {
            let state = State()
            self.state = state
            tracker = ClipboardProgressTracker(
                revealDelay: revealDelay, idleLinger: idleLinger,
                now: { state.lock.withLock { state.now } },
                schedule: { delay, work in
                    state.lock.withLock {
                        state.scheduledDelays.append(delay)
                        state.pending.append(work)
                    }
                },
                emit: { snapshot in state.lock.withLock { state.emissions.append(snapshot) } })
        }

        var now: TimeInterval {
            get { state.lock.withLock { state.now } }
            set { state.lock.withLock { state.now = newValue } }
        }

        /// Every emission in order; a `nil` element is a "clear the readout".
        var emissions: [ClipboardProgressSnapshot?] { state.lock.withLock { state.emissions } }

        /// The most recent emission, or `nil` if nothing has been emitted.
        var latest: ClipboardProgressSnapshot? { emissions.last ?? nil }

        /// Whether the most recent emission was a "clear the readout".
        var lastEmissionClears: Bool {
            guard let last = emissions.last else { return false }
            return last == nil
        }

        var scheduledDelays: [TimeInterval] { state.lock.withLock { state.scheduledDelays } }

        /// Runs every scheduled idle terminal, standing in for the linger
        /// elapsing.
        func fireScheduledWork() {
            let work = state.lock.withLock { () -> [@Sendable () -> Void] in
                let pending = state.pending
                state.pending.removeAll()
                return pending
            }
            for item in work { item() }
        }
    }

    // MARK: - Manifest builders

    private static func item(
        _ repIndex: Int, _ filename: String, _ byteCount: UInt64
    ) -> FileProviderManifest.Item {
        FileProviderManifest.Item(
            sessionSalt: 1, generation: 1, repIndex: repIndex, filename: filename,
            byteCount: byteCount, uti: "public.data")
    }

    private static func fileNode(
        _ childSeq: UInt32, _ filename: String, _ byteCount: UInt64
    ) -> FileProviderManifest.FolderRep.Node {
        FileProviderManifest.FolderRep.Node(
            childSeq: childSeq, parentChildSeq: 0, kind: .file, filename: filename,
            relativePath: filename, byteCount: byteCount, uti: "public.data")
    }

    private static func directoryNode(
        _ childSeq: UInt32, _ filename: String
    ) -> FileProviderManifest.FolderRep.Node {
        FileProviderManifest.FolderRep.Node(
            childSeq: childSeq, parentChildSeq: 0, kind: .directory, filename: filename,
            relativePath: filename, byteCount: 0, uti: "public.folder")
    }

    private static func folder(
        _ repIndex: Int, _ filename: String, nodes: [FileProviderManifest.FolderRep.Node]
    ) -> FileProviderManifest.FolderRep {
        FileProviderManifest.FolderRep(
            sessionSalt: 1, generation: 1, repIndex: repIndex, filename: filename,
            uti: "public.folder", nodes: nodes)
    }

    private static func manifest(
        generation: UInt64 = 1, items: [FileProviderManifest.Item] = [],
        folders: [FileProviderManifest.FolderRep] = []
    ) -> FileProviderManifest {
        FileProviderManifest(generation: generation, items: items, folders: folders)
    }

    // MARK: - Denominators

    @Test("a flat multi-file offer's denominators come from the published manifest")
    func flatOfferDenominators() throws {
        let harness = Harness()
        harness.tracker.offerPublished(
            Self.manifest(items: [
                Self.item(0, "a.bin", 1_000), Self.item(1, "b.bin", 3_000),
            ]),
            peerName: "macOS TEST")

        harness.tracker.pullBegan(generation: 1, repIndex: 0, childSeq: nil)
        harness.now = 2
        harness.tracker.pullProgressed(
            generation: 1, repIndex: 0, childSeq: nil, bytesTransferred: 500)

        let snapshot = try #require(harness.latest)
        #expect(snapshot.peerName == "macOS TEST")
        #expect(snapshot.fileCount == 2)
        #expect(snapshot.totalBytes == 4_000)
        #expect(snapshot.bytesTransferred == 500)
        #expect(snapshot.currentItemName == "a.bin")
    }

    @Test("a folder's file nodes count individually, alongside the flat files")
    func folderOfferDenominators() throws {
        let harness = Harness()
        harness.tracker.offerPublished(
            Self.manifest(
                items: [Self.item(0, "loose.bin", 100)],
                folders: [
                    Self.folder(
                        1, "Photos",
                        nodes: [
                            Self.fileNode(1, "one.jpg", 200),
                            Self.directoryNode(2, "nested"),
                            Self.fileNode(3, "two.jpg", 300),
                        ])
                ]),
            peerName: "macOS TEST")

        harness.tracker.pullBegan(generation: 1, repIndex: 1, childSeq: 1)
        harness.now = 2
        harness.tracker.pullProgressed(
            generation: 1, repIndex: 1, childSeq: 1, bytesTransferred: 200)

        let snapshot = try #require(harness.latest)
        // Three files (the loose one plus the folder's two file nodes) — the
        // subdirectory is not a file and contributes nothing.
        #expect(snapshot.fileCount == 3)
        #expect(snapshot.totalBytes == 600)
    }

    // MARK: - Reveal gate

    @Test("a paste that finishes inside the reveal delay never emits anything")
    func fastPasteNeverReveals() {
        let harness = Harness(revealDelay: 1)
        harness.tracker.offerPublished(
            Self.manifest(items: [Self.item(0, "a.bin", 1_000)]), peerName: "VM")

        harness.tracker.pullBegan(generation: 1, repIndex: 0, childSeq: nil)
        harness.now = 0.4
        harness.tracker.pullProgressed(
            generation: 1, repIndex: 0, childSeq: nil, bytesTransferred: 1_000)
        harness.tracker.pullEnded(generation: 1, repIndex: 0, childSeq: nil, succeeded: true)
        harness.fireScheduledWork()

        #expect(harness.emissions.isEmpty)
    }

    @Test("the readout reveals on the first event past the reveal delay")
    func revealsAfterDelay() {
        let harness = Harness(revealDelay: 1)
        harness.tracker.offerPublished(
            Self.manifest(items: [Self.item(0, "a.bin", 1_000)]), peerName: "VM")

        harness.tracker.pullBegan(generation: 1, repIndex: 0, childSeq: nil)
        harness.now = 0.9
        harness.tracker.pullProgressed(
            generation: 1, repIndex: 0, childSeq: nil, bytesTransferred: 100)
        #expect(harness.emissions.isEmpty)

        harness.now = 1.1
        harness.tracker.pullProgressed(
            generation: 1, repIndex: 0, childSeq: nil, bytesTransferred: 200)
        #expect(harness.emissions.count == 1)
        #expect(harness.latest?.bytesTransferred == 200)
    }

    // MARK: - Session shape

    @Test("a sequential multi-file paste reads as one session, counting files as they land")
    func sequentialFilesAggregate() throws {
        let harness = Harness()
        harness.tracker.offerPublished(
            Self.manifest(items: [
                Self.item(0, "a.bin", 1_000), Self.item(1, "b.bin", 1_000),
            ]),
            peerName: "VM")

        harness.tracker.pullBegan(generation: 1, repIndex: 0, childSeq: nil)
        harness.now = 2
        harness.tracker.pullEnded(generation: 1, repIndex: 0, childSeq: nil, succeeded: true)
        let afterFirst = try #require(harness.latest)
        #expect(afterFirst.filesCompleted == 1)
        #expect(afterFirst.bytesTransferred == 1_000)

        // The gap between two of Finder's sequential fetches must not end the
        // session — the pull that follows supersedes the scheduled terminal.
        harness.tracker.pullBegan(generation: 1, repIndex: 1, childSeq: nil)
        harness.fireScheduledWork()
        #expect(!harness.lastEmissionClears)

        harness.now = 4
        harness.tracker.pullEnded(generation: 1, repIndex: 1, childSeq: nil, succeeded: true)
        let afterSecond = try #require(harness.latest)
        #expect(afterSecond.filesCompleted == 2)
        #expect(afterSecond.bytesTransferred == 2_000)
    }

    @Test("a folder's concurrent children aggregate into one bar")
    func concurrentChildrenAggregate() throws {
        let harness = Harness()
        harness.tracker.offerPublished(
            Self.manifest(folders: [
                Self.folder(
                    0, "Photos",
                    nodes: [
                        Self.fileNode(1, "one.jpg", 1_000), Self.fileNode(2, "two.jpg", 1_000),
                    ])
            ]),
            peerName: "VM")

        harness.tracker.pullBegan(generation: 1, repIndex: 0, childSeq: 1)
        harness.tracker.pullBegan(generation: 1, repIndex: 0, childSeq: 2)
        harness.now = 2
        harness.tracker.pullProgressed(
            generation: 1, repIndex: 0, childSeq: 1, bytesTransferred: 400)
        harness.tracker.pullProgressed(
            generation: 1, repIndex: 0, childSeq: 2, bytesTransferred: 600)

        let snapshot = try #require(harness.latest)
        #expect(snapshot.bytesTransferred == 1_000)
        #expect(snapshot.totalBytes == 2_000)
        // Each child is its own file in the counter; none is done yet.
        #expect(snapshot.fileCount == 2)
        #expect(snapshot.filesCompleted == 0)
    }

    @Test("a folder's children advance the counter one by one")
    func folderCompletesOnLastChild() {
        let harness = Harness()
        harness.tracker.offerPublished(
            Self.manifest(folders: [
                Self.folder(
                    0, "Photos",
                    nodes: [
                        Self.fileNode(1, "one.jpg", 1_000), Self.fileNode(2, "two.jpg", 1_000),
                    ])
            ]),
            peerName: "VM")

        harness.tracker.pullBegan(generation: 1, repIndex: 0, childSeq: 1)
        harness.now = 2
        harness.tracker.pullEnded(generation: 1, repIndex: 0, childSeq: 1, succeeded: true)
        #expect(harness.latest?.filesCompleted == 1)

        harness.tracker.pullBegan(generation: 1, repIndex: 0, childSeq: 2)
        harness.now = 3
        harness.tracker.pullEnded(generation: 1, repIndex: 0, childSeq: 2, succeeded: true)
        #expect(harness.latest?.filesCompleted == 2)
    }

    @Test("a folder with no file nodes adds nothing to the counter")
    func emptyFolderCountsComplete() throws {
        let harness = Harness()
        harness.tracker.offerPublished(
            Self.manifest(
                items: [Self.item(0, "a.bin", 1_000)],
                folders: [Self.folder(1, "Empty", nodes: [Self.directoryNode(1, "sub")])]),
            peerName: "VM")

        harness.tracker.pullBegan(generation: 1, repIndex: 0, childSeq: nil)
        harness.now = 2
        harness.tracker.pullEnded(generation: 1, repIndex: 0, childSeq: nil, succeeded: true)

        let snapshot = try #require(harness.latest)
        // The empty folder has no file to pull, so it contributes no unit at
        // all — the counter can't stall waiting on something that will never
        // stream.
        #expect(snapshot.fileCount == 1)
        #expect(snapshot.filesCompleted == 1)
    }

    // MARK: - Terminals

    @Test("the readout clears once the idle linger elapses with nothing in flight")
    func idleLingerClearsTheReadout() {
        let harness = Harness(idleLinger: 2)
        harness.tracker.offerPublished(
            Self.manifest(items: [Self.item(0, "a.bin", 1_000)]), peerName: "VM")

        harness.tracker.pullBegan(generation: 1, repIndex: 0, childSeq: nil)
        harness.now = 2
        harness.tracker.pullEnded(generation: 1, repIndex: 0, childSeq: nil, succeeded: true)
        #expect(harness.scheduledDelays == [2])
        #expect(harness.latest != nil)

        harness.fireScheduledWork()
        #expect(harness.lastEmissionClears)
        #expect(harness.emissions.count >= 2)
    }

    @Test("a partial materialization clears below 100%")
    func partialMaterializationClears() throws {
        let harness = Harness()
        harness.tracker.offerPublished(
            Self.manifest(items: [
                Self.item(0, "a.bin", 1_000), Self.item(1, "b.bin", 1_000),
            ]),
            peerName: "VM")

        harness.tracker.pullBegan(generation: 1, repIndex: 0, childSeq: nil)
        harness.now = 2
        harness.tracker.pullEnded(generation: 1, repIndex: 0, childSeq: nil, succeeded: true)
        let beforeClear = try #require(harness.latest)
        #expect(beforeClear.fractionComplete == 0.5)

        harness.fireScheduledWork()
        #expect(harness.lastEmissionClears)
    }

    @Test("a failed pull keeps its bytes but never counts its item complete")
    func failedPullDoesNotCompleteItsItem() throws {
        let harness = Harness()
        harness.tracker.offerPublished(
            Self.manifest(items: [Self.item(0, "a.bin", 1_000)]), peerName: "VM")

        harness.tracker.pullBegan(generation: 1, repIndex: 0, childSeq: nil)
        harness.now = 2
        harness.tracker.pullProgressed(
            generation: 1, repIndex: 0, childSeq: nil, bytesTransferred: 400)
        harness.tracker.pullEnded(generation: 1, repIndex: 0, childSeq: nil, succeeded: false)

        let snapshot = try #require(harness.latest)
        #expect(snapshot.filesCompleted == 0)
        #expect(snapshot.bytesTransferred == 400)
    }

    @Test("a chunk callback landing after its pull's terminal cannot strand the readout")
    func lateProgressAfterTerminalStillClears() {
        let harness = Harness()
        harness.tracker.offerPublished(
            Self.manifest(items: [Self.item(0, "a.bin", 1_000)]), peerName: "VM")

        harness.tracker.pullBegan(generation: 1, repIndex: 0, childSeq: nil)
        harness.now = 2
        harness.tracker.pullProgressed(
            generation: 1, repIndex: 0, childSeq: nil, bytesTransferred: 400)
        harness.tracker.pullEnded(generation: 1, repIndex: 0, childSeq: nil, succeeded: false)
        // Chunk callbacks fire on the receiver's lane, so one can be delivered
        // after the pull it belongs to has already replied. It must not put the
        // paste back "in flight" — the readout would then never clear (§13).
        harness.tracker.pullProgressed(
            generation: 1, repIndex: 0, childSeq: nil, bytesTransferred: 500)

        harness.fireScheduledWork()
        #expect(harness.lastEmissionClears)
    }

    @Test("clearing the offer clears a visible readout immediately")
    func offerClearedClearsTheReadout() {
        let harness = Harness()
        harness.tracker.offerPublished(
            Self.manifest(items: [Self.item(0, "a.bin", 1_000)]), peerName: "VM")

        harness.tracker.pullBegan(generation: 1, repIndex: 0, childSeq: nil)
        harness.now = 2
        harness.tracker.pullProgressed(
            generation: 1, repIndex: 0, childSeq: nil, bytesTransferred: 100)
        #expect(harness.latest != nil)

        harness.tracker.offerCleared()
        #expect(harness.lastEmissionClears)
    }

    @Test("clearing an offer that never revealed emits nothing")
    func clearWithoutRevealEmitsNothing() {
        let harness = Harness()
        harness.tracker.offerPublished(
            Self.manifest(items: [Self.item(0, "a.bin", 1_000)]), peerName: "VM")
        harness.tracker.pullBegan(generation: 1, repIndex: 0, childSeq: nil)

        harness.tracker.offerCleared()
        #expect(harness.emissions.isEmpty)
    }

    @Test("a new offer supersedes a live session and clears its readout")
    func newOfferSupersedes() {
        let harness = Harness()
        harness.tracker.offerPublished(
            Self.manifest(items: [Self.item(0, "a.bin", 1_000)]), peerName: "VM")
        harness.tracker.pullBegan(generation: 1, repIndex: 0, childSeq: nil)
        harness.now = 2
        harness.tracker.pullProgressed(
            generation: 1, repIndex: 0, childSeq: nil, bytesTransferred: 100)
        #expect(harness.latest != nil)

        harness.tracker.offerPublished(
            Self.manifest(generation: 2, items: [Self.item(0, "c.bin", 500)]),
            peerName: "VM")
        #expect(harness.lastEmissionClears)
    }

    // MARK: - Stale and unknown events

    @Test("events for a superseded generation are ignored")
    func staleGenerationIgnored() {
        let harness = Harness()
        harness.tracker.offerPublished(
            Self.manifest(generation: 2, items: [Self.item(0, "a.bin", 1_000)]),
            peerName: "VM")

        harness.tracker.pullBegan(generation: 1, repIndex: 0, childSeq: nil)
        harness.now = 5
        harness.tracker.pullProgressed(
            generation: 1, repIndex: 0, childSeq: nil, bytesTransferred: 900)

        #expect(harness.emissions.isEmpty)
    }

    @Test("events for a rep the offer never published are ignored")
    func unknownRepIgnored() {
        let harness = Harness()
        harness.tracker.offerPublished(
            Self.manifest(items: [Self.item(0, "a.bin", 1_000)]), peerName: "VM")

        harness.tracker.pullBegan(generation: 1, repIndex: 9, childSeq: nil)
        harness.now = 5
        harness.tracker.pullProgressed(
            generation: 1, repIndex: 9, childSeq: nil, bytesTransferred: 900)

        #expect(harness.emissions.isEmpty)
    }

    @Test("pull events arriving with no published offer are ignored")
    func noOfferIgnored() {
        let harness = Harness()
        harness.tracker.pullBegan(generation: 1, repIndex: 0, childSeq: nil)
        harness.now = 5
        harness.tracker.pullProgressed(
            generation: 1, repIndex: 0, childSeq: nil, bytesTransferred: 900)

        #expect(harness.emissions.isEmpty)
    }

    // MARK: - Monotonicity and throttling

    @Test("a retry that restarts its own byte count never regresses the aggregate")
    func retryDoesNotRegress() {
        let harness = Harness()
        harness.tracker.offerPublished(
            Self.manifest(items: [Self.item(0, "a.bin", 1_000)]), peerName: "VM")

        harness.tracker.pullBegan(generation: 1, repIndex: 0, childSeq: nil)
        harness.now = 2
        harness.tracker.pullProgressed(
            generation: 1, repIndex: 0, childSeq: nil, bytesTransferred: 800)
        #expect(harness.latest?.bytesTransferred == 800)

        harness.tracker.pullEnded(generation: 1, repIndex: 0, childSeq: nil, succeeded: false)
        harness.tracker.pullBegan(generation: 1, repIndex: 0, childSeq: nil)
        harness.now = 3
        harness.tracker.pullProgressed(
            generation: 1, repIndex: 0, childSeq: nil, bytesTransferred: 50)

        #expect(harness.latest?.bytesTransferred == 800)
    }

    @Test("a completed pull is credited its full manifest byte count")
    func completionCreditsFullSize() {
        let harness = Harness()
        harness.tracker.offerPublished(
            Self.manifest(items: [Self.item(0, "a.bin", 1_000)]), peerName: "VM")

        harness.tracker.pullBegan(generation: 1, repIndex: 0, childSeq: nil)
        harness.now = 2
        // The throttle can suppress the final chunks; the terminal must still
        // read as 100%.
        harness.tracker.pullProgressed(
            generation: 1, repIndex: 0, childSeq: nil, bytesTransferred: 10)
        harness.tracker.pullEnded(generation: 1, repIndex: 0, childSeq: nil, succeeded: true)

        #expect(harness.latest?.bytesTransferred == 1_000)
        #expect(harness.latest?.fractionComplete == 1)
    }

    // The suite's one wall-clock-dependent assertion, and the same trade-off
    // `ClipboardTransferProgressTrackerTests.subQuantumChunkSuppressed` already
    // documents: the throttle admits on the byte quantum OR ~100 ms elapsed, and
    // `FetchProgressCoalescer` reads its own clock, so proving suppression needs
    // the two records to land inside that window. They are adjacent synchronous
    // statements — no awaits, actor hops, or I/O. The quantum itself is covered
    // deterministically by `FetchProgressThrottleTests`, which passes
    // `elapsedSinceLastPush` explicitly; this is kept because it is the only
    // test proving the *tracker* consults the throttle at all.
    @Test("sub-1% updates are coalesced away; a completion lands via its credited bytes")
    func throttleSuppressesTinyUpdatesButNotItemCompletion() {
        let harness = Harness()
        harness.tracker.offerPublished(
            Self.manifest(items: [
                Self.item(0, "a.bin", 100_000), Self.item(1, "b.bin", 100_000),
            ]),
            peerName: "VM")

        harness.tracker.pullBegan(generation: 1, repIndex: 0, childSeq: nil)
        harness.now = 2
        harness.tracker.pullProgressed(
            generation: 1, repIndex: 0, childSeq: nil, bytesTransferred: 50_000)
        let afterReveal = harness.emissions.count
        #expect(afterReveal == 1)

        // Well under 1% of the 200 KB total, and no wall-clock passes in a test,
        // so the shared throttle drops it.
        harness.tracker.pullProgressed(
            generation: 1, repIndex: 0, childSeq: nil, bytesTransferred: 50_100)
        #expect(harness.emissions.count == afterReveal)

        // Completion credits the file's full manifest size, so the resulting
        // byte delta (~25% of the total here) clears the quantum on its own —
        // no special bypass, which a folder completing thousands of small files
        // in quick succession would otherwise exploit into an emission flood.
        harness.tracker.pullEnded(generation: 1, repIndex: 0, childSeq: nil, succeeded: true)
        #expect(harness.emissions.count == afterReveal + 1)
        #expect(harness.latest?.filesCompleted == 1)
    }

    // MARK: - Current file name

    @Test("a folder's children all stream under the folder's own name")
    func folderChildrenDisplayTheFolderName() {
        let harness = Harness()
        harness.tracker.offerPublished(
            Self.manifest(folders: [
                Self.folder(
                    0, "Photos",
                    nodes: [
                        Self.fileNode(1, "one.jpg", 1_000), Self.fileNode(2, "two.jpg", 1_000),
                    ])
            ]),
            peerName: "VM")

        // Whether the children run sequentially or overlap, the display name is
        // the folder's — concurrent children would otherwise flicker through
        // sibling filenames while the counter and percent already carry the
        // motion.
        harness.tracker.pullBegan(generation: 1, repIndex: 0, childSeq: 1)
        harness.now = 2
        harness.tracker.pullEnded(generation: 1, repIndex: 0, childSeq: 1, succeeded: true)
        #expect(harness.latest?.currentItemName == "Photos")

        harness.tracker.pullBegan(generation: 1, repIndex: 0, childSeq: 2)
        harness.now = 3
        harness.tracker.pullEnded(generation: 1, repIndex: 0, childSeq: 2, succeeded: true)
        #expect(harness.latest?.currentItemName == "Photos")
    }

    @Test("the name follows the most recently begun pull, reverting when it finishes first")
    func nameRevertsWhenTheNewestConcurrentPullFinishes() {
        let harness = Harness()
        harness.tracker.offerPublished(
            Self.manifest(
                items: [Self.item(0, "loose.bin", 100_000)],
                folders: [
                    Self.folder(1, "Photos", nodes: [Self.fileNode(1, "one.jpg", 100_000)])
                ]),
            peerName: "VM")

        harness.tracker.pullBegan(generation: 1, repIndex: 0, childSeq: nil)
        harness.tracker.pullBegan(generation: 1, repIndex: 1, childSeq: 1)
        harness.now = 2
        harness.tracker.pullProgressed(
            generation: 1, repIndex: 0, childSeq: nil, bytesTransferred: 10_000)
        #expect(harness.latest?.currentItemName == "Photos")

        // The newer pull finishes while the older streams on: the name falls
        // back to what is still in flight instead of sticking to a done item.
        harness.now = 3
        harness.tracker.pullEnded(generation: 1, repIndex: 1, childSeq: 1, succeeded: true)
        #expect(harness.latest?.currentItemName == "loose.bin")
    }

    // MARK: - Ad-hoc sessions

    @Test("an ad-hoc session aggregates its transfers into one readout")
    func adHocSessionAggregates() throws {
        let harness = Harness()
        let session = harness.tracker.openSession(
            direction: .inbound, peerName: "VM",
            units: [
                ClipboardProgressTracker.PlannedUnit(id: 0, expectedBytes: 1_000, name: "a.bin"),
                ClipboardProgressTracker.PlannedUnit(id: 1, expectedBytes: 3_000, name: "b.bin"),
            ])

        harness.tracker.unitBegan(session: session, id: 0)
        harness.now = 2
        harness.tracker.unitProgressed(session: session, id: 0, bytesTransferred: 500)

        let snapshot = try #require(harness.latest)
        #expect(snapshot.direction == .inbound)
        #expect(snapshot.peerName == "VM")
        #expect(snapshot.fileCount == 2)
        #expect(snapshot.totalBytes == 4_000)
        #expect(snapshot.bytesTransferred == 500)
        #expect(snapshot.currentItemName == "a.bin")
        // Only a File Provider paste may interrupt with a dropdown.
        #expect(!snapshot.isPasteSession)
    }

    @Test("an ad-hoc session's transfers are addressed independently of any generation")
    func adHocSessionsDoNotCollideWithTheManifest() throws {
        // Inbound and outbound generations are independent counters that both
        // start at 1, and a preview fetch shares the paste manifest's generation
        // exactly — so anything keyed by generation would merge unrelated work.
        let harness = Harness()
        harness.tracker.offerPublished(
            Self.manifest(items: [Self.item(0, "paste.bin", 10_000)]), peerName: "VM")
        harness.tracker.pullBegan(generation: 1, repIndex: 0, childSeq: nil)

        let outbound = harness.tracker.openSession(direction: .outbound, peerName: "VM")
        harness.tracker.unitBegan(
            session: outbound, id: 0, expectedBytes: 1_000, name: "sending.bin")

        harness.now = 2
        harness.tracker.unitProgressed(session: outbound, id: 0, bytesTransferred: 900)
        harness.tracker.pullProgressed(
            generation: 1, repIndex: 0, childSeq: nil, bytesTransferred: 100)

        // The paste has far more left to move, so it is what shows — and its
        // numbers are its own, untouched by the outbound session's.
        let snapshot = try #require(harness.latest)
        #expect(snapshot.isPasteSession)
        #expect(snapshot.direction == .inbound)
        #expect(snapshot.totalBytes == 10_000)
        #expect(snapshot.bytesTransferred == 100)
    }

    @Test("the readout follows whichever live session has the most left to move")
    func projectionPicksTheMostSignificantSession() throws {
        let harness = Harness()
        let small = harness.tracker.openSession(direction: .inbound, peerName: "VM")
        harness.tracker.unitBegan(session: small, id: 0, expectedBytes: 1_000, name: "small.bin")
        harness.now = 2
        harness.tracker.unitProgressed(session: small, id: 0, bytesTransferred: 900)
        #expect(harness.latest?.currentItemName == "small.bin")

        let large = harness.tracker.openSession(direction: .outbound, peerName: "VM")
        harness.tracker.unitBegan(
            session: large, id: 0, expectedBytes: 1_000_000, name: "large.bin")
        harness.now = 3
        harness.tracker.unitProgressed(session: large, id: 0, bytesTransferred: 10)

        let snapshot = try #require(harness.latest)
        #expect(snapshot.currentItemName == "large.bin")
        #expect(snapshot.direction == .outbound)
    }

    @Test("a transfer's wire total replaces what the operation advertised")
    func wireTotalOverridesTheAdvertisedEstimate() throws {
        // A directory rep advertises a stat-walk estimate and then streams a
        // compressed archive; with the estimate held fixed the bar would peg early
        // or never reach the end.
        let harness = Harness()
        let session = harness.tracker.openSession(
            direction: .outbound, peerName: "VM",
            units: [
                ClipboardProgressTracker.PlannedUnit(
                    id: 0, expectedBytes: 10_000, name: "Photos")
            ])
        harness.tracker.unitBegan(session: session, id: 0)
        harness.now = 2
        harness.tracker.unitProgressed(
            session: session, id: 0, bytesTransferred: 2_000, totalBytes: 4_000)

        let snapshot = try #require(harness.latest)
        #expect(snapshot.totalBytes == 4_000)
        #expect(snapshot.fractionComplete == 0.5)
    }

    @Test("an outbound session grows as the peer asks for more, across separate waves")
    func outboundSessionGrowsOnDemand() throws {
        // The peer pulls what it wants, when it wants — preview reps at offer
        // time, the file rep at paste. Declaring the whole offer up front would
        // cap a partial pull at a fixed fraction forever.
        let harness = Harness()
        let session = harness.tracker.openSession(direction: .outbound, peerName: "VM")
        harness.tracker.unitBegan(session: session, id: 0, expectedBytes: 1_000, name: "a.bin")
        harness.now = 2
        harness.tracker.unitEnded(session: session, id: 0, succeeded: true)
        #expect(harness.latest?.fileCount == 1)
        #expect(harness.latest?.fractionComplete == 1)

        // A second request arrives inside the linger, so the readout bridges the
        // gap rather than ending and restarting.
        harness.tracker.unitBegan(session: session, id: 1, expectedBytes: 3_000, name: "b.bin")
        harness.now = 3
        harness.tracker.unitProgressed(session: session, id: 1, bytesTransferred: 1_000)

        let snapshot = try #require(harness.latest)
        #expect(snapshot.fileCount == 2)
        #expect(snapshot.totalBytes == 4_000)
        #expect(snapshot.bytesTransferred == 2_000)

        harness.fireScheduledWork()
        #expect(!harness.lastEmissionClears)
    }

    @Test("progress or a terminal for a session that never began is ignored")
    func eventsWithoutABeganAreIgnored() {
        // A chunk can land after its session closed. Minting a session for it
        // would arm no idle terminal, so the readout it revealed would never
        // clear.
        let harness = Harness()
        let session = harness.tracker.openSession(direction: .inbound, peerName: "VM")
        harness.now = 2
        harness.tracker.unitProgressed(session: session, id: 7, bytesTransferred: 500)
        harness.tracker.unitEnded(session: session, id: 7, succeeded: true)
        #expect(harness.emissions.isEmpty)

        harness.tracker.closeSession(session, immediately: true)
        // A closed session's late chunk finds nothing to attach to.
        harness.tracker.unitProgressed(session: session, id: 0, bytesTransferred: 500)
        #expect(harness.emissions.isEmpty)
    }

    @Test("closing a revealed session leaves its final state up for the linger")
    func closingARevealedSessionHonorsTheDwell() throws {
        let harness = Harness()
        let session = harness.tracker.openSession(
            direction: .inbound, peerName: "VM",
            units: [ClipboardProgressTracker.PlannedUnit(id: 0, expectedBytes: 1_000)])
        harness.tracker.unitBegan(session: session, id: 0)
        harness.now = 2
        harness.tracker.unitEnded(session: session, id: 0, succeeded: true)
        harness.tracker.closeSession(session)

        // The finished readout is still on screen, reading 100%.
        let snapshot = try #require(harness.latest)
        #expect(snapshot.fractionComplete == 1)

        harness.fireScheduledWork()
        #expect(harness.lastEmissionClears)
    }

    @Test("closing a session immediately clears it, dwell or not")
    func closingImmediatelySkipsTheDwell() {
        let harness = Harness()
        let session = harness.tracker.openSession(
            direction: .inbound, peerName: "VM",
            units: [ClipboardProgressTracker.PlannedUnit(id: 0, expectedBytes: 1_000)])
        harness.tracker.unitBegan(session: session, id: 0)
        harness.now = 2
        harness.tracker.unitProgressed(session: session, id: 0, bytesTransferred: 500)
        #expect(harness.latest != nil)

        // A supersession or teardown: what the readout was measuring is gone, so
        // holding it on screen for a beat would be a lie.
        harness.tracker.closeSession(session, immediately: true)
        #expect(harness.lastEmissionClears)
    }

    @Test("closing a session that never revealed emits nothing")
    func closingAnUnrevealedSessionIsSilent() {
        let harness = Harness()
        let session = harness.tracker.openSession(
            direction: .inbound, peerName: "VM",
            units: [ClipboardProgressTracker.PlannedUnit(id: 0, expectedBytes: 1_000)])
        harness.tracker.unitBegan(session: session, id: 0)
        harness.now = 0.4
        harness.tracker.unitEnded(session: session, id: 0, succeeded: true)
        harness.tracker.closeSession(session)
        harness.fireScheduledWork()

        #expect(harness.emissions.isEmpty)
    }
}
