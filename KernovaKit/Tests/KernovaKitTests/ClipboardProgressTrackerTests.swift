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

    // MARK: - Reveal gate

    @Test("an operation that finishes inside the reveal delay never emits anything")
    func fastOperationNeverReveals() {
        let harness = Harness(revealDelay: 1)
        let session = harness.tracker.openSession(
            direction: .inbound, peerName: "VM",
            units: [ClipboardProgressTracker.PlannedUnit(id: 0, expectedBytes: 1_000, name: "a.bin")])

        harness.tracker.unitBegan(session: session, id: 0)
        harness.now = 0.4
        harness.tracker.unitProgressed(session: session, id: 0, bytesTransferred: 1_000)
        harness.tracker.unitEnded(session: session, id: 0, succeeded: true)
        harness.fireScheduledWork()

        #expect(harness.emissions.isEmpty)
    }

    @Test("the readout reveals on the first event past the reveal delay")
    func revealsAfterDelay() {
        let harness = Harness(revealDelay: 1)
        let session = harness.tracker.openSession(
            direction: .inbound, peerName: "VM",
            units: [ClipboardProgressTracker.PlannedUnit(id: 0, expectedBytes: 1_000, name: "a.bin")])

        harness.tracker.unitBegan(session: session, id: 0)
        harness.now = 0.9
        harness.tracker.unitProgressed(session: session, id: 0, bytesTransferred: 100)
        #expect(harness.emissions.isEmpty)

        harness.now = 1.1
        harness.tracker.unitProgressed(session: session, id: 0, bytesTransferred: 200)
        #expect(harness.emissions.count == 1)
        #expect(harness.latest?.bytesTransferred == 200)
    }

    // MARK: - Terminals

    @Test("the readout clears once the idle linger elapses with nothing in flight")
    func idleLingerClearsTheReadout() {
        let harness = Harness(idleLinger: 2)
        let session = harness.tracker.openSession(
            direction: .inbound, peerName: "VM",
            units: [ClipboardProgressTracker.PlannedUnit(id: 0, expectedBytes: 1_000, name: "a.bin")])

        harness.tracker.unitBegan(session: session, id: 0)
        harness.now = 2
        harness.tracker.unitEnded(session: session, id: 0, succeeded: true)
        #expect(harness.scheduledDelays == [2])
        #expect(harness.latest != nil)

        harness.fireScheduledWork()
        #expect(harness.lastEmissionClears)
        #expect(harness.emissions.count >= 2)
    }

    @Test("a partial operation clears below 100%")
    func partialOperationClears() throws {
        let harness = Harness()
        let session = harness.tracker.openSession(
            direction: .inbound, peerName: "VM",
            units: [
                ClipboardProgressTracker.PlannedUnit(id: 0, expectedBytes: 1_000, name: "a.bin"),
                ClipboardProgressTracker.PlannedUnit(id: 1, expectedBytes: 1_000, name: "b.bin"),
            ])

        harness.tracker.unitBegan(session: session, id: 0)
        harness.now = 2
        harness.tracker.unitEnded(session: session, id: 0, succeeded: true)
        let beforeClear = try #require(harness.latest)
        #expect(beforeClear.fractionComplete == 0.5)

        harness.fireScheduledWork()
        #expect(harness.lastEmissionClears)
    }

    @Test("a failed transfer keeps its bytes but never counts its item complete")
    func failedTransferDoesNotCompleteItsItem() throws {
        let harness = Harness()
        let session = harness.tracker.openSession(
            direction: .inbound, peerName: "VM",
            units: [ClipboardProgressTracker.PlannedUnit(id: 0, expectedBytes: 1_000, name: "a.bin")])

        harness.tracker.unitBegan(session: session, id: 0)
        harness.now = 2
        harness.tracker.unitProgressed(session: session, id: 0, bytesTransferred: 400)
        harness.tracker.unitEnded(session: session, id: 0, succeeded: false)

        let snapshot = try #require(harness.latest)
        #expect(snapshot.filesCompleted == 0)
        #expect(snapshot.bytesTransferred == 400)
    }

    @Test("a chunk callback landing after its transfer's terminal cannot strand the readout")
    func lateProgressAfterTerminalStillClears() {
        let harness = Harness()
        let session = harness.tracker.openSession(
            direction: .inbound, peerName: "VM",
            units: [ClipboardProgressTracker.PlannedUnit(id: 0, expectedBytes: 1_000, name: "a.bin")])

        harness.tracker.unitBegan(session: session, id: 0)
        harness.now = 2
        harness.tracker.unitProgressed(session: session, id: 0, bytesTransferred: 400)
        harness.tracker.unitEnded(session: session, id: 0, succeeded: false)
        // Chunk callbacks fire on the receiver's lane, so one can be delivered
        // after the transfer it belongs to has already finished. It must not put
        // the operation back "in flight" — the readout would then never clear
        // (CLIPBOARD.md §13).
        harness.tracker.unitProgressed(session: session, id: 0, bytesTransferred: 500)

        harness.fireScheduledWork()
        #expect(harness.lastEmissionClears)
    }

    // MARK: - Monotonicity and throttling

    @Test("a retry that restarts its own byte count never regresses the aggregate")
    func retryDoesNotRegress() {
        let harness = Harness()
        let session = harness.tracker.openSession(
            direction: .inbound, peerName: "VM",
            units: [ClipboardProgressTracker.PlannedUnit(id: 0, expectedBytes: 1_000, name: "a.bin")])

        harness.tracker.unitBegan(session: session, id: 0)
        harness.now = 2
        harness.tracker.unitProgressed(session: session, id: 0, bytesTransferred: 800)
        #expect(harness.latest?.bytesTransferred == 800)

        harness.tracker.unitEnded(session: session, id: 0, succeeded: false)
        harness.tracker.unitBegan(session: session, id: 0)
        harness.now = 3
        harness.tracker.unitProgressed(session: session, id: 0, bytesTransferred: 50)

        #expect(harness.latest?.bytesTransferred == 800)
    }

    @Test("a completed transfer is credited its full expected byte count")
    func completionCreditsFullSize() {
        let harness = Harness()
        let session = harness.tracker.openSession(
            direction: .inbound, peerName: "VM",
            units: [ClipboardProgressTracker.PlannedUnit(id: 0, expectedBytes: 1_000, name: "a.bin")])

        harness.tracker.unitBegan(session: session, id: 0)
        harness.now = 2
        // The throttle can suppress the final chunks; the terminal must still
        // read as 100%.
        harness.tracker.unitProgressed(session: session, id: 0, bytesTransferred: 10)
        harness.tracker.unitEnded(session: session, id: 0, succeeded: true)

        #expect(harness.latest?.bytesTransferred == 1_000)
        #expect(harness.latest?.fractionComplete == 1)
    }

    // The suite's one wall-clock-dependent assertion:
    // the throttle admits on the byte quantum OR ~100 ms elapsed, and
    // `FetchProgressCoalescer` reads its own clock, so proving suppression needs
    // the two records to land inside that window. They are adjacent synchronous
    // statements — no awaits, actor hops, or I/O. The quantum itself is covered
    // deterministically by `FetchProgressThrottleTests`, which passes
    // `elapsedSinceLastPush` explicitly; this is kept because it is the only
    // test proving the *tracker* consults the throttle at all.
    @Test("sub-1% updates are coalesced away; a completion lands via its credited bytes")
    func throttleSuppressesTinyUpdatesButNotItemCompletion() {
        let harness = Harness()
        let session = harness.tracker.openSession(
            direction: .inbound, peerName: "VM",
            units: [
                ClipboardProgressTracker.PlannedUnit(id: 0, expectedBytes: 100_000, name: "a.bin"),
                ClipboardProgressTracker.PlannedUnit(id: 1, expectedBytes: 100_000, name: "b.bin"),
            ])

        harness.tracker.unitBegan(session: session, id: 0)
        harness.now = 2
        harness.tracker.unitProgressed(session: session, id: 0, bytesTransferred: 50_000)
        let afterReveal = harness.emissions.count
        #expect(afterReveal == 1)

        // Well under 1% of the 200 KB total, and no wall-clock passes in a test,
        // so the shared throttle drops it.
        harness.tracker.unitProgressed(session: session, id: 0, bytesTransferred: 50_100)
        #expect(harness.emissions.count == afterReveal)

        // Completion credits the transfer's full expected size, so the resulting
        // byte delta (~25% of the total here) clears the quantum on its own —
        // no special bypass, which a folder completing thousands of small files
        // in quick succession would otherwise exploit into an emission flood.
        harness.tracker.unitEnded(session: session, id: 0, succeeded: true)
        #expect(harness.emissions.count == afterReveal + 1)
        #expect(harness.latest?.filesCompleted == 1)
    }

    // MARK: - Current file name

    @Test("the name follows the most recently begun transfer, reverting when it finishes first")
    func nameRevertsWhenTheNewestConcurrentTransferFinishes() {
        let harness = Harness()
        let session = harness.tracker.openSession(
            direction: .inbound, peerName: "VM",
            units: [
                ClipboardProgressTracker.PlannedUnit(
                    id: 0, expectedBytes: 100_000, name: "loose.bin"),
                ClipboardProgressTracker.PlannedUnit(id: 1, expectedBytes: 100_000, name: "Photos"),
            ])

        harness.tracker.unitBegan(session: session, id: 0)
        harness.tracker.unitBegan(session: session, id: 1)
        harness.now = 2
        harness.tracker.unitProgressed(session: session, id: 0, bytesTransferred: 10_000)
        #expect(harness.latest?.currentItemName == "Photos")

        // The newer transfer finishes while the older streams on: the name falls
        // back to what is still in flight instead of sticking to a done item.
        harness.now = 3
        harness.tracker.unitEnded(session: session, id: 1, succeeded: true)
        #expect(harness.latest?.currentItemName == "loose.bin")
    }

    // MARK: - Sessions

    @Test("a session aggregates its transfers into one readout")
    func sessionAggregates() throws {
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
        #expect(!snapshot.isPasteSession)
    }

    @Test("two sessions reusing the same transfer id keep separate accounting")
    func sessionsWithCollidingUnitIDsStayIndependent() throws {
        // Every session numbers its own transfers from zero, and inbound and
        // outbound run concurrently — so anything keyed on the id alone would
        // merge unrelated work.
        let harness = Harness()
        let inbound = harness.tracker.openSession(direction: .inbound, peerName: "VM")
        harness.tracker.unitBegan(
            session: inbound, id: 0, expectedBytes: 10_000, name: "receiving.bin")

        let outbound = harness.tracker.openSession(direction: .outbound, peerName: "VM")
        harness.tracker.unitBegan(
            session: outbound, id: 0, expectedBytes: 1_000, name: "sending.bin")

        harness.now = 2
        harness.tracker.unitProgressed(session: outbound, id: 0, bytesTransferred: 900)
        harness.tracker.unitProgressed(session: inbound, id: 0, bytesTransferred: 100)

        // The inbound transfer has far more left to move, so it is what shows —
        // and its numbers are its own, untouched by the outbound session's.
        let snapshot = try #require(harness.latest)
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

    @Test("a session the linger already ended reports itself dead so its token isn't reused")
    func endedSessionIsNotLive() {
        // The waves can be minutes apart — far longer than the linger — and the
        // callers that cache a token across them (`outboundSessionToken` on both
        // sides of the link) have no other way to tell that the session they
        // opened is gone. Without the check every event of the second wave is
        // dropped, which is the whole outbound readout for a paste.
        let harness = Harness()
        let session = harness.tracker.openSession(direction: .outbound, peerName: "VM")
        harness.tracker.unitBegan(session: session, id: 0, expectedBytes: 1_000, name: "a.bin")
        harness.now = 2
        harness.tracker.unitEnded(session: session, id: 0, succeeded: true)
        #expect(harness.tracker.isSessionLive(session))

        harness.fireScheduledWork()
        #expect(!harness.tracker.isSessionLive(session))

        // And the token really is inert, so reusing it would measure nothing.
        let emissionsBefore = harness.emissions.count
        harness.tracker.unitBegan(session: session, id: 1, expectedBytes: 5_000, name: "b.bin")
        harness.now = 5
        harness.tracker.unitProgressed(session: session, id: 1, bytesTransferred: 2_500)
        #expect(harness.emissions.count == emissionsBefore)
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

    @Test("a disowned transfer leaves the denominator, so the session can still finish")
    func discardedUnitLeavesTheDenominator() throws {
        // Two materialization loops can walk one offer at once; whichever reaches a
        // rep second coalesces onto the other's pull, and that rep's bytes are
        // reported to the session that owns it. The coalescing session has to give
        // the unit back or it never reaches 100% (#656).
        let harness = Harness()
        let session = harness.tracker.openSession(
            direction: .inbound, peerName: "VM",
            units: [
                ClipboardProgressTracker.PlannedUnit(id: 0, expectedBytes: 1_000, name: "mine.bin"),
                ClipboardProgressTracker.PlannedUnit(id: 1, expectedBytes: 9_000, name: "theirs.bin"),
            ])
        harness.tracker.unitBegan(session: session, id: 0)
        harness.now = 2
        harness.tracker.unitProgressed(session: session, id: 0, bytesTransferred: 400)
        #expect(harness.latest?.totalBytes == 10_000)

        harness.tracker.discardUnit(session: session, id: 1)
        let afterDiscard = try #require(harness.latest)
        #expect(afterDiscard.fileCount == 1)
        #expect(afterDiscard.totalBytes == 1_000)
        #expect(afterDiscard.bytesTransferred == 400)

        // And what this session does own still completes the readout.
        harness.tracker.unitEnded(session: session, id: 0, succeeded: true)
        let finished = try #require(harness.latest)
        #expect(finished.fractionComplete == 1)
        #expect(finished.filesCompleted == 1)
    }

    @Test("disowning a transfer never reveals a session that has shown nothing")
    func discardingDoesNotReveal() {
        // A loop that coalesces on every rep it declared moves nothing of its own.
        // Revealing it would put an empty readout on screen — and, with no bytes
        // remaining, it would rank last anyway.
        let harness = Harness()
        let session = harness.tracker.openSession(
            direction: .inbound, peerName: "VM",
            units: [
                ClipboardProgressTracker.PlannedUnit(id: 0, expectedBytes: 1_000),
                ClipboardProgressTracker.PlannedUnit(id: 1, expectedBytes: 9_000),
            ])
        harness.now = 5  // well past the reveal delay
        harness.tracker.discardUnit(session: session, id: 0)
        harness.tracker.discardUnit(session: session, id: 1)
        #expect(harness.emissions.isEmpty)

        harness.tracker.closeSession(session)
        #expect(harness.emissions.isEmpty)
    }

    @Test("the readout follows the session moving bytes, not one waiting on a transfer it disowned")
    func discardedUnitDoesNotOutrankRealProgress() throws {
        // The projection ranks by bytes *remaining*, so a session stalled on a unit
        // it doesn't own outranks the one actually transferring — the symptom #656
        // is filed for.
        let harness = Harness()
        let owner = harness.tracker.openSession(
            direction: .inbound, peerName: "VM",
            units: [
                ClipboardProgressTracker.PlannedUnit(id: 0, expectedBytes: 100_000, name: "big.bin")
            ])
        harness.tracker.unitBegan(session: owner, id: 0)

        // The second loop declared the same rep plus one of its own, then found the
        // first loop already pulling it.
        let coalescing = harness.tracker.openSession(
            direction: .inbound, peerName: "VM",
            units: [
                ClipboardProgressTracker.PlannedUnit(id: 0, expectedBytes: 100_000, name: "big.bin"),
                ClipboardProgressTracker.PlannedUnit(id: 1, expectedBytes: 2_000, name: "own.bin"),
            ])
        harness.tracker.discardUnit(session: coalescing, id: 0)
        harness.tracker.unitBegan(session: coalescing, id: 1)

        harness.now = 2
        harness.tracker.unitProgressed(session: owner, id: 0, bytesTransferred: 10_000)
        harness.tracker.unitProgressed(session: coalescing, id: 1, bytesTransferred: 1_000)

        let snapshot = try #require(harness.latest)
        #expect(snapshot.currentItemName == "big.bin")
        #expect(snapshot.totalBytes == 100_000)
        #expect(snapshot.bytesTransferred == 10_000)
    }

    // MARK: - Paste sessions

    @Test("a paste session's readout carries the flag through to the auto-opener")
    func pasteSessionReadoutInterrupts() throws {
        // The one live producer: the host serving a guest's paste. The flag has to
        // survive the projection, since the auto-opener sees nothing else.
        let harness = Harness(revealDelay: 1)
        let session = harness.tracker.openSession(
            direction: .outbound, peerName: "VM", isPaste: true,
            units: [
                ClipboardProgressTracker.PlannedUnit(id: 0, expectedBytes: 100_000, name: "a.bin")
            ])
        harness.tracker.unitBegan(session: session, id: 0)
        harness.now = 5
        harness.tracker.unitProgressed(session: session, id: 0, bytesTransferred: 1_000)

        let snapshot = try #require(harness.latest)
        #expect(snapshot.isPasteSession)
        #expect(
            ClipboardProgressFormat.headline(
                direction: snapshot.direction, peerName: snapshot.peerName,
                isPaste: snapshot.isPasteSession) == "Pasting into “VM”…")

        var opener = ClipboardProgressMenuAutoOpener()
        #expect(opener.readoutChanged(snapshot, menuIsOpen: false, canOpen: true) == .open)
    }

    @Test("a bigger non-paste operation outranking a paste takes the flag off the readout")
    func nonPasteWinnerSuppressesTheFlag() throws {
        // The flag belongs to whichever session is projected, not to any live one:
        // a preview fetch with more left to move owns the readout, and the
        // auto-opener must not interrupt over a readout that isn't the paste's.
        let harness = Harness()
        let paste = harness.tracker.openSession(
            direction: .outbound, peerName: "VM", isPaste: true)
        harness.tracker.unitBegan(session: paste, id: 0, expectedBytes: 1_000, name: "small.bin")

        let preview = harness.tracker.openSession(direction: .inbound, peerName: "VM")
        harness.tracker.unitBegan(session: preview, id: 0, expectedBytes: 500_000, name: "big.bin")
        harness.now = 2
        harness.tracker.unitProgressed(session: preview, id: 0, bytesTransferred: 1_000)

        let snapshot = try #require(harness.latest)
        #expect(snapshot.currentItemName == "big.bin")
        #expect(!snapshot.isPasteSession)
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
